import asyncio
import base64
import importlib.util
import io
import unittest
from pathlib import Path

from fastapi import HTTPException, UploadFile
from PIL import Image

import stub_qwen_runtime  # noqa: F401


server_path = Path(__file__).resolve().parents[1] / "windows" / "qwen-imagegen-server.py"
spec = importlib.util.spec_from_file_location("qwen_image_server", server_path)
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class Result:
    def __init__(self):
        self.images = [Image.new("RGBA", (256, 256), (255, 0, 0, 0))]


class Pipeline:
    def __init__(self):
        self.calls = []

    def __call__(self, **kwargs):
        self.calls.append(kwargs)
        return Result()


class QwenImageServerTests(unittest.TestCase):
    def setUp(self):
        self.pipeline = Pipeline()
        server.pipeline = self.pipeline

    def tearDown(self):
        server.pipeline = None

    def test_pins_turbo_model_and_schedule(self):
        expected_sigmas = (
            1.0,
            0.978453,
            0.95418,
            0.926626,
            0.89508,
            0.845148,
            0.704534,
            0.414568,
        )
        self.assertEqual(server.MODEL_ID, "Qwen/Qwen-Image-2.1-Turbo")
        self.assertEqual(server.MODEL_REVISION, "d65dbc9a7e8f6b5479e33dee6030eaab2a906509")
        self.assertEqual(server.TURBO_SIGMAS, expected_sigmas)

    def test_rejects_base_model_identifier(self):
        with self.assertRaises(HTTPException):
            server.check_request("qwen-image-2.1", "b64_json")

    def test_generation_uses_turbo_schedule(self):
        request = server.ImageRequest(prompt="test", size="256x256")
        response = asyncio.run(server.generate(request))

        self.assertEqual(self.pipeline.calls[0]["sigmas"], (
            1.0, 0.978453, 0.95418, 0.926626, 0.89508, 0.845148, 0.704534, 0.414568,
        ))
        self.assertNotIn("num_inference_steps", self.pipeline.calls[0])
        self.assertGreater(len(base64.b64decode(response["data"][0]["b64_json"])), 0)

    def test_edit_uses_turbo_schedule(self):
        source = io.BytesIO()
        Image.new("RGB", (256, 256), "white").save(source, format="PNG")
        upload = UploadFile(filename="source.png", file=io.BytesIO(source.getvalue()))

        response = asyncio.run(server.edit("replace the background", upload, "256x256"))

        self.assertEqual(self.pipeline.calls[0]["sigmas"], (
            1.0, 0.978453, 0.95418, 0.926626, 0.89508, 0.845148, 0.704534, 0.414568,
        ))
        self.assertNotIn("num_inference_steps", self.pipeline.calls[0])
        self.assertGreater(len(base64.b64decode(response["data"][0]["b64_json"])), 0)

    def test_health_identifies_turbo(self):
        response = asyncio.run(server.health())

        self.assertEqual(response["model"], "Qwen-Image-2.1-Turbo")
        self.assertEqual(response["quality"], "8-step Turbo")
        self.assertTrue(response["model_loaded"])


if __name__ == "__main__":
    unittest.main()
