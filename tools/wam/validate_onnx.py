"""Validate ONNX extractor vs PyTorch, measure speed, then int8 quantize."""
import sys
import os
import time

import numpy as np
import torch

sys.path.insert(0, r"E:\WorkSpace\.local\wam\watermark-anything")
sys.path.insert(0, r"E:\WorkSpace\.local\wam\watermark-anything\notebooks")

from inference_utils import load_model_from_checkpoint, msg2str
from watermark_anything.data.transforms import default_transform, unnormalize_img
from watermark_anything.data.metrics import msg_predict_inference

import onnxruntime as ort

CKPT = r"E:\WorkSpace\.local\wam\watermark-anything\checkpoints\wam_mit.pth"
PARAMS = r"E:\WorkSpace\.local\wam\watermark-anything\checkpoints\params.json"
ONNX_DIR = r"E:\WorkSpace\.local\wam\onnx"
EMB_ONNX = os.path.join(ONNX_DIR, "wam_embedder.onnx")
EXT_ONNX = os.path.join(ONNX_DIR, "wam_extractor.onnx")

torch.set_num_threads(os.cpu_count() or 4)
wam = load_model_from_checkpoint(PARAMS, CKPT).eval()

MSG = [True] + [False] * 10 + [True] * 5 + [False] * 6 + [True] * 10
MSG_STR = msg2str(MSG)

# build a watermarked image via PyTorch
import cv2
h, w = 512, 512
yy, xx = np.mgrid[0:h, 0:w]
img = np.zeros((h, w, 3), np.uint8)
img[..., 0] = (xx * 255 / w).astype(np.uint8)
img[..., 1] = (yy * 255 / h).astype(np.uint8)
img[..., 2] = ((xx + yy) * 255 / (w + h)).astype(np.uint8)
rng = np.random.default_rng(7)
img = cv2.addWeighted(img, 0.8, rng.integers(0, 70, (h, w, 3), np.uint8), 0.2, 0)
img_pil = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
from PIL import Image

with torch.no_grad():
    img_t = default_transform(img_pil).unsqueeze(0)
    out = wam.embed(img_t, torch.tensor(MSG, dtype=torch.float32).unsqueeze(0))
    wm = out["imgs_w"]
    wm_np = unnormalize_img(wm).cpu().numpy().transpose(0, 2, 3, 1)[0]
    wm_np = (np.clip(wm_np, 0, 1) * 255).astype(np.uint8)

    # torch reference decode
    def torch_decode(t):
        preds = wam.detect(t)["preds"]
        m = torch.sigmoid(preds[:, 0:1])
        b = preds[:, 1:]
        pm = msg_predict_inference(b, m)
        return "".join(str(int(x)) for x in (pm[0] > 0.5).int().tolist())

    print("torch clean decode:", torch_decode(wm))

    # ONNX: embed then extract
    sess_e = ort.InferenceSession(EMB_ONNX, providers=["CPUExecutionProvider"])
    sess_x = ort.InferenceSession(EXT_ONNX, providers=["CPUExecutionProvider"])

    from torchvision import transforms as T
    inp_img = T.Resize((256, 256), interpolation=T.InterpolationMode.BILINEAR)(img_t).numpy()
    inp_msg = torch.tensor(MSG, dtype=torch.float32).numpy()[None, :]
    t0 = time.time()
    wm_onnx = sess_e.run(None, {"img": inp_img, "msg": inp_msg})[0]
    t_emb = time.time() - t0
    print(f"onnx embed: {t_emb:.2f}s")

    t0 = time.time()
    preds_onnx = sess_x.run(None, {"img": wm_onnx})[0]
    t_ext = time.time() - t0
    print(f"onnx extract: {t_ext:.2f}s")

    m = 1 / (1 + np.exp(-preds_onnx[:, 0:1]))
    b = preds_onnx[:, 1:]
    pm = (b * (m > 0.5)).sum((2, 3)) / np.maximum((m > 0.5).sum((2, 3)), 1)
    msg_onnx = "".join(str(int(x)) for x in (pm[0] > 0.5).astype(int).tolist())
    print("onnx fp32 decode:", msg_onnx, "->", "OK" if msg_onnx == MSG_STR else "FAIL")

    # ---- int8 quantization of extractor ----
    from onnxruntime.quantization import quantize_dynamic, QuantType

    ext_int8 = os.path.join(ONNX_DIR, "wam_extractor_int8.onnx")
    quantize_dynamic(EXT_ONNX, ext_int8, weight_type=QuantType.QInt8)
    print("int8 size:", os.path.getsize(ext_int8) / 1e6, "MB")

    sess_q = ort.InferenceSession(ext_int8, providers=["CPUExecutionProvider"])
    t0 = time.time()
    preds_q = sess_q.run(None, {"img": wm_onnx})[0]
    t_q = time.time() - t0
    print(f"onnx int8 extract: {t_q:.2f}s")

    m = 1 / (1 + np.exp(-preds_q[:, 0:1]))
    b = preds_q[:, 1:]
    pm = (b * (m > 0.5)).sum((2, 3)) / np.maximum((m > 0.5).sum((2, 3)), 1)
    msg_q = "".join(str(int(x)) for x in (pm[0] > 0.5).astype(int).tolist())
    print("onnx int8 decode:", msg_q, "->", "OK" if msg_q == MSG_STR else "FAIL")

