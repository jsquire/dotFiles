import contextlib
import sys
import types


torch = types.ModuleType("torch")
torch.bfloat16 = object()
torch.inference_mode = contextlib.nullcontext
torch.cuda = types.SimpleNamespace(OutOfMemoryError=type("OutOfMemoryError", (Exception,), {}))
sys.modules.setdefault("torch", torch)

diffusers = types.ModuleType("diffusers")


class QwenImage21Pipeline:
    @classmethod
    def from_pretrained(cls, *args, **kwargs):
        raise AssertionError("model loading is not allowed in unit tests")


diffusers.QwenImage21Pipeline = QwenImage21Pipeline
sys.modules.setdefault("diffusers", diffusers)

uvicorn = types.ModuleType("uvicorn")
uvicorn.run = lambda *args, **kwargs: None
sys.modules.setdefault("uvicorn", uvicorn)
