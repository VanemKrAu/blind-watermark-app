"""Export WAM embedder + extractor to ONNX, then int8-quantize the extractor."""
import sys
import os

import torch

sys.path.insert(0, r"E:\WorkSpace\.local\wam\watermark-anything")
sys.path.insert(0, r"E:\WorkSpace\.local\wam\watermark-anything\notebooks")

from inference_utils import load_model_from_checkpoint

CKPT = r"E:\WorkSpace\.local\wam\watermark-anything\checkpoints\wam_mit.pth"
PARAMS = r"E:\WorkSpace\.local\wam\watermark-anything\checkpoints\params.json"
OUT = r"E:\WorkSpace\.local\wam\onnx"
os.makedirs(OUT, exist_ok=True)

torch.set_num_threads(os.cpu_count() or 4)
wam = load_model_from_checkpoint(PARAMS, CKPT).eval()

# ---- embedder: input [1,3,256,256] float + [1,32] float msg -> [1,3,256,256]
embedder = wam.embedder
x = torch.rand(1, 3, 256, 256)
msg = torch.rand(1, 32)
emb_path = os.path.join(OUT, "wam_embedder.onnx")
with torch.no_grad():
    torch.onnx.export(
        embedder,
        (x, msg),
        emb_path,
        input_names=["img", "msg"],
        output_names=["imgs_w"],
        opset_version=17,
        dynamic_axes=None,
    )
print("embedder exported:", os.path.getsize(emb_path) / 1e6, "MB")

# ---- extractor: input [1,3,256,256] -> [1,33,256,256]
extractor = wam.detector
x2 = torch.rand(1, 3, 256, 256)
ext_path = os.path.join(OUT, "wam_extractor.onnx")
with torch.no_grad():
    torch.onnx.export(
        extractor,
        (x2,),
        ext_path,
        input_names=["img"],
        output_names=["preds"],
        opset_version=17,
    )
print("extractor exported:", os.path.getsize(ext_path) / 1e6, "MB")

# ---- quick ORT inference timing (CPU, fp32) ----
import onnxruntime as ort
import numpy as np
import time

sess = ort.InferenceSession(ext_path, providers=["CPUExecutionProvider"])
inp = np.random.rand(1, 3, 256, 256).astype(np.float32)
t0 = time.time()
for _ in range(3):
    out = sess.run(None, {"img": inp})
print("extractor fp32 CPU: %.2fs / run" % ((time.time() - t0) / 3))
print("extractor output:", out[0].shape)

sess_e = ort.InferenceSession(emb_path, providers=["CPUExecutionProvider"])
t0 = time.time()
for _ in range(3):
    out_e = sess_e.run(None, {"img": inp, "msg": np.random.rand(1, 32).astype(np.float32)})
print("embedder fp32 CPU: %.2fs / run" % ((time.time() - t0) / 3))
print("embedder output:", out_e[0].shape)

