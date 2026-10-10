import asyncio
import base64
import importlib.util
import io
import unittest
from pathlib import Path

from fastapi import HTTPException, UploadFile
from PIL import Image

server_path = Path(__file__).resolve().parents[1] / "windows" / "qwen-imagegen-server.py"
spec = importlib.util.spec_from_file_location("qwen_imagegen", server_path)
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class FakePipeline:
    def __call__(self, **kwargs):
        return type("Result", (), {"images": [Image.new("RGB", (kwargs["width"], kwargs["height"]))]})()


class ImageTests(unittest.TestCase):
    def setUp(self):
        server.pipeline = FakePipeline()

    def tearDown(self):
        server.pipeline = None

    def test_generate_shape(self):
        result = asyncio.run(server.generate(server.ImageRequest(prompt="a cat")))
        image = Image.open(io.BytesIO(base64.b64decode(result["data"][0]["b64_json"])))
        self.assertEqual(image.size, (1024, 1024))
        self.assertEqual(result["data"][0]["revised_prompt"], "a cat")

    def test_rejects_wrong_model_and_unsupported_size(self):
        for request in (
            server.ImageRequest(prompt="cat", model="hidream-o1"),
            server.ImageRequest(prompt="cat", size="2049x1024"),
        ):
            with self.subTest(request=request):
                with self.assertRaises(HTTPException) as caught:
                    asyncio.run(server.generate(request))
                self.assertEqual(caught.exception.status_code, 400)

    def test_edits_and_rejects_invalid_input(self):
        source = io.BytesIO()
        Image.new("RGB", (64, 64)).save(source, format="PNG")
        source.seek(0)
        upload = UploadFile(filename="source.png", file=source)
        result = asyncio.run(server.edit(prompt="make it blue", image=upload, size="1024x1024"))
        self.assertEqual(result["data"][0]["revised_prompt"], "make it blue")
        invalid = UploadFile(filename="invalid.png", file=io.BytesIO(b"not an image"))
        with self.assertRaises(HTTPException) as caught:
            asyncio.run(server.edit(prompt="make it blue", image=invalid, size="1024x1024"))
        self.assertEqual(caught.exception.status_code, 400)


if __name__ == "__main__":
    unittest.main()
