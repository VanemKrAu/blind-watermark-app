"""Re-export the WAM embedder with the LEGACY torch exporter (dynamo=False).

The first embedder (0.85MB, external data) and the int8 extractor were both
legacy-exporter graphs; the self-contained replacement was exported by torch
2.13's dynamo exporter, whose graph ABORTS inside sess.run on Android
(SIGABRT at embed:run, Xiaomi 14 / Android 16). Re-exporting with the legacy
exporter restores the graph family that the pipeline was validated with.
"""
import os
import sys

import numpy as np
import onnx
import onnxruntime as ort
import torch

sys.path.insert(0, r"E:\WorkSpace\.local\wam\watermark-anything")
sys.path.insert(0, r"E:\WorkSpace\.local\wam\watermark-anything\notebooks")

from inference_utils import load_model_from_checkpoint  # noqa: E402

CKPT = r"E:\WorkSpace\.local\wam\watermark-anything\checkpoints\wam_mit.pth"
PARAMS = r"E:\WorkSpace\.local\wam\watermark-anything\checkpoints\params.json"
OUT = r"E:\WorkSpace\.local\wam\onnx"
os.makedirs(OUT, exist_ok=True)

torch.set_num_threads(os.cpu_count() or 4)
wam = load_model_from_checkpoint(PARAMS, CKPT).eval()
embedder = wam.embedder

x = torch.rand(1, 3, 256, 256)
msg = (torch.rand(1, 32) > 0.5).float()
raw_path = os.path.join(OUT, "wam_embedder_legacy_raw.onnx")
final_path = os.path.join(OUT, "wam_embedder.onnx")

with torch.no_grad():
    torch.onnx.export(
        embedder,
        (x, msg),
        raw_path,
        input_names=["img", "msg"],
        output_names=["imgs_w"],
        opset_version=17,
        dynamic_axes=None,
        dynamo=False,
    )
print("legacy export done:", os.path.getsize(raw_path) / 1e6, "MB")

model = onnx.load(raw_path)
onnx.save_model(model, final_path, save_as_external_data=False)
print("self-contained:", os.path.getsize(final_path) / 1e6, "MB")

# Verify: standalone session + roundtrip with the packaged int8 extractor.
sess = ort.InferenceSession(final_path, providers=["CPUExecutionProvider"])
out = sess.run(
    None,
    {"img": x.numpy().astype(np.float32), "msg": msg.numpy().astype(np.float32)},
)
print("embedder output:", out[0].shape, out[0].dtype)

ext = ort.InferenceSession(
    r"E:\WorkSpace\blind-watermark-app\example\assets\onnx\wam_extractor_int8.onnx",
    providers=["CPUExecutionProvider"],
)
preds = ext.run(None, {"img": out[0].astype(np.float32)})[0]
hw = 256 * 256
mask = 1.0 / (1.0 + np.exp(-preds[0, 0])) > 0.5
bits = []
for k in range(1, 33):
    sel = mask
    bits.append(1 if (int(sel.sum()) > 0 and preds[0, k][sel].mean() > 0) else 0)
msgbits = (msg.numpy()[0] > 0.5).astype(int).tolist()
diffs = sum(1 for a, b in zip(bits, msgbits) if a != b)
print(f"roundtrip bit errors: {diffs}/32")
print("DONE")
