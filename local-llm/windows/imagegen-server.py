"""
Image Generation Server — OpenAI-compatible API using FLUX.1-schnell via diffusers.

Provides POST /v1/images/generations matching the OpenAI Images API format.

Modes:
  --quality hq    (default) Full bf16 — best quality, ~34GB VRAM, uses CPU offload (~2.5 min/image)
  --quality fast  NF4 quantized — near-identical quality, ~9GB VRAM, all on GPU (~5-20s/image)

Model downloads on first use (~24GB for hq, ~24GB for fast — same base, quantized at load time).

Start: python imagegen-server.py [--quality fast] [--port 8001] [--host 127.0.0.1]
"""

import argparse
import base64
import io
import logging
import time
from contextlib import asynccontextmanager

import torch
from diffusers import FluxPipeline
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
import uvicorn

logger = logging.getLogger("imagegen")

pipe = None
quality_mode = "fast"

MODEL_ID = "black-forest-labs/FLUX.1-schnell"


class ImageRequest(BaseModel):
    prompt: str
    model: str = "flux-schnell"
    n: int = Field(default=1, ge=1, le=4)
    size: str = "1024x1024"
    response_format: str = "b64_json"
    num_inference_steps: int = Field(default=4, ge=1, le=50)


def parse_size(size_str: str) -> tuple[int, int]:
    """Parse 'WIDTHxHEIGHT' string, constrained to multiples of 8."""
    try:
        w, h = size_str.lower().split("x")
        w, h = int(w), int(h)
    except (ValueError, AttributeError):
        raise HTTPException(400, f"Invalid size format: {size_str}. Use WIDTHxHEIGHT (e.g., 1024x1024)")
    if w < 256 or h < 256 or w > 2048 or h > 2048:
        raise HTTPException(400, f"Size must be between 256 and 2048. Got {w}x{h}")
    # Round to nearest multiple of 8 (required by FLUX VAE)
    w = (w // 8) * 8
    h = (h // 8) * 8
    return w, h


def load_pipeline():
    global pipe
    if pipe is not None:
        return

    if quality_mode == "hq":
        logger.info("Loading FLUX.1-schnell in HQ mode (bf16, CPU offload)...")
        pipe = FluxPipeline.from_pretrained(MODEL_ID, torch_dtype=torch.bfloat16)
        pipe.enable_model_cpu_offload()
        logger.info("HQ pipeline loaded. ~34GB model with CPU offload (~2.5 min/image).")
    else:
        logger.info("Loading FLUX.1-schnell in FAST mode (NF4 quantized)...")
        from diffusers import BitsAndBytesConfig as DiffusersBNBConfig
        from diffusers import FluxTransformer2DModel
        from transformers import BitsAndBytesConfig as TransformersBNBConfig
        from transformers import T5EncoderModel

        nf4_config = DiffusersBNBConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_compute_dtype=torch.bfloat16,
            bnb_4bit_use_double_quant=True,
        )
        transformer = FluxTransformer2DModel.from_pretrained(
            MODEL_ID, subfolder="transformer",
            quantization_config=nf4_config, torch_dtype=torch.bfloat16,
        )
        text_encoder_2 = T5EncoderModel.from_pretrained(
            MODEL_ID, subfolder="text_encoder_2",
            quantization_config=TransformersBNBConfig(
                load_in_4bit=True, bnb_4bit_quant_type="nf4",
                bnb_4bit_compute_dtype=torch.bfloat16,
            ),
            torch_dtype=torch.bfloat16,
        )
        pipe = FluxPipeline.from_pretrained(
            MODEL_ID, transformer=transformer, text_encoder_2=text_encoder_2,
            torch_dtype=torch.bfloat16,
        )
        pipe.to("cuda")
        logger.info("FAST pipeline loaded on GPU (~9GB VRAM, ~5-20s/image).")


@asynccontextmanager
async def lifespan(app: FastAPI):
    load_pipeline()
    yield


app = FastAPI(title="Image Generation Server", lifespan=lifespan)


@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [
            {
                "id": "flux-schnell",
                "object": "model",
                "created": 1700000000,
                "owned_by": "black-forest-labs",
            }
        ],
    }


@app.post("/v1/images/generations")
async def generate_image(request: ImageRequest):
    if pipe is None:
        raise HTTPException(503, "Pipeline not loaded yet")

    width, height = parse_size(request.size)
    logger.info(f"Generating {request.n} image(s): {width}x{height}, steps={request.num_inference_steps}")
    start = time.time()

    try:
        results = pipe(
            prompt=[request.prompt] * request.n,
            width=width,
            height=height,
            num_inference_steps=request.num_inference_steps,
            guidance_scale=0.0,  # FLUX.1-schnell is guidance-free
        )
    except torch.cuda.OutOfMemoryError:
        raise HTTPException(507, "GPU out of memory. Close other GPU applications or reduce image size.")
    except Exception as e:
        logger.error(f"Generation failed: {e}")
        raise HTTPException(500, f"Generation failed: {e}")

    elapsed = time.time() - start
    logger.info(f"Generated {request.n} image(s) in {elapsed:.1f}s")

    data = []
    for img in results.images:
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        b64 = base64.b64encode(buf.getvalue()).decode("utf-8")
        data.append({"b64_json": b64, "revised_prompt": request.prompt})

    return JSONResponse(
        {
            "created": int(time.time()),
            "data": data,
        }
    )


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "model": "FLUX.1-schnell",
        "quality": quality_mode,
        "pipeline_loaded": pipe is not None,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Image Generation Server")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8001, help="Port (default: 8001)")
    parser.add_argument("--quality", choices=["fast", "hq"], default="fast",
                        help="fast: NF4 quantized ~9GB VRAM, ~5-20s/image (default). "
                             "hq: full bf16 with CPU offload, best quality, ~2.5 min/image.")
    args = parser.parse_args()

    quality_mode = args.quality
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    logger.info(f"Starting image generation server on {args.host}:{args.port} [quality={quality_mode}]")
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")
