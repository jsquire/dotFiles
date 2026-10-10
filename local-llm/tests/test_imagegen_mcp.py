import asyncio
import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx

os.environ["IMAGEGEN_URL"] = "http://127.0.0.1:8002"
os.environ["IMAGEGEN_BACKEND"] = "qwen-image-2.1"
server_path = Path(__file__).resolve().parents[1] / "mcp" / "imagegen-mcp-server.py"
spec = importlib.util.spec_from_file_location("imagegen_mcp", server_path)
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class Response:
    status_code = 200

    @staticmethod
    def json():
        return {"model": "HiDream-O1-Image-Dev"}


class ImageMcpTests(unittest.TestCase):
    def test_qwen_timeout_and_edit_registration(self):
        self.assertEqual(server.REQUEST_TIMEOUT_SECONDS, 300)
        self.assertTrue(callable(server.edit_image))

    def test_default_profile_has_no_edit_tool(self):
        with patch.dict(os.environ, {"IMAGEGEN_URL": "http://127.0.0.1:8001", "IMAGEGEN_BACKEND": "hidream-o1"}):
            other_spec = importlib.util.spec_from_file_location("hidream_imagegen_mcp", server_path)
            other = importlib.util.module_from_spec(other_spec)
            other_spec.loader.exec_module(other)
        self.assertFalse(hasattr(other, "edit_image"))
        self.assertEqual(other.REQUEST_TIMEOUT_SECONDS, 180)

    def test_refuses_to_load_alongside_hidream(self):
        client = AsyncMock()
        client.get.side_effect = [httpx.ConnectError("offline"), Response()]
        manager = AsyncMock()
        manager.__aenter__.return_value = client
        with patch.object(server.httpx, "AsyncClient", return_value=manager):
            with self.assertRaisesRegex(RuntimeError, "HiDream-O1-Image-Dev is already running"):
                asyncio.run(server._start_server())
        self.assertIsNone(server._server_process)


if __name__ == "__main__":
    unittest.main()
