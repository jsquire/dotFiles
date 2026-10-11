"""Experimental Windows-local Qwen-Image-2.1-Turbo image API."""

import argparse
import base64
import io
import logging
import time
from contextlib import asynccontextmanager

import torch
import uvicorn
from diffusers import QwenImage21Pipeline
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel, Field

MODEL_ID = "Qwen/Qwen-Image-2.1-Turbo"
MODEL_REVISION = "d65dbc9a7e8f6b5479e33dee6030eaab2a906509"
TURBO_SIGMAS = (
    1.0,
    0.978453,
    0.95418,
    0.926626,
    0.89508,
    0.845148,
    0.704534,
    0.414568,
)
logger = logging.getLogger("qwen-imagegen")
pipeline = None


class ImageRequest(BaseModel):
    prompt: str = Field(min_length=1)
    model: str = "qwen-image-2.1-turbo"
    n: int = Field(default=1, ge=1, le=1)
    size: str = "1024x1024"
    response_format: str = "b64_json"


def dimensions(size: str) -> tuple[int, int]:
    try:
        width, height = (int(value) for value in size.lower().split("x"))
    except (AttributeError, ValueError):
        raise HTTPException(400, "Size must be WIDTHxHEIGHT") from None
    if not (256 <= width <= 2048 and 256 <= height <= 2048 and width % 32 == 0 and height % 32 == 0):
        raise HTTPException(400, "Dimensions must be multiples of 32 between 256 and 2048")
    return width, height


def encode(image: Image.Image, prompt: str) -> dict:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return {"created": int(time.time()), "data": [
        {"b64_json": base64.b64encode(buffer.getvalue()).decode("ascii"), "revised_prompt": prompt}
    ]}


def check_request(model: str, response_format: str) -> None:
    if model != "qwen-image-2.1-turbo" or response_format != "b64_json":
        raise HTTPException(400, "Only model qwen-image-2.1-turbo and b64_json are supported")
    if pipeline is None:
        raise HTTPException(503, "Model not loaded")


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pipeline
    logger.info("Loading %s with CPU offload", MODEL_ID)
    pipeline = QwenImage21Pipeline.from_pretrained(
        MODEL_ID, revision=MODEL_REVISION, local_files_only=True, dtype=torch.bfloat16
    )
    pipeline.enable_model_cpu_offload()
    yield
    pipeline = None


app = FastAPI(title="Qwen Image Experimental", lifespan=lifespan)


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "model": "Qwen-Image-2.1-Turbo",
        "quality": "8-step Turbo",
        "model_loaded": pipeline is not None,
    }


@app.post("/v1/images/generations")
async def generate(request: ImageRequest):
    check_request(request.model, request.response_format)
    width, height = dimensions(request.size)
    try:
        with torch.inference_mode():
            image = pipeline(
                prompt=request.prompt, width=width, height=height,
                sigmas=TURBO_SIGMAS, true_cfg_scale=1.0,
            ).images[0]
        return encode(image, request.prompt)
    except torch.cuda.OutOfMemoryError:
        raise HTTPException(507, "GPU out of memory. Reduce resolution or close other GPU applications.") from None


@app.post("/v1/images/edits")
async def edit(
    prompt: str = Form(min_length=1), image: UploadFile = File(),
    size: str = Form(default="1024x1024"),
):
    check_request("qwen-image-2.1-turbo", "b64_json")
    width, height = dimensions(size)
    content = await image.read(20 * 1024 * 1024 + 1)
    if len(content) > 20 * 1024 * 1024:
        raise HTTPException(413, "Input image exceeds 20 MiB")
    try:
        source = Image.open(io.BytesIO(content))
        source.load()
        source = source.convert("RGB")
    except (UnidentifiedImageError, OSError):
        raise HTTPException(400, "Input must be a valid image") from None
    try:
        with torch.inference_mode():
            result = pipeline(
                prompt=prompt, image=source, width=width, height=height,
                sigmas=TURBO_SIGMAS, true_cfg_scale=1.0,
            ).images[0]
        return encode(result, prompt)
    except torch.cuda.OutOfMemoryError:
        raise HTTPException(507, "GPU out of memory. Reduce resolution or close other GPU applications.") from None


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8002)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)
    uvicorn.run(app, host="127.0.0.1", port=args.port)
