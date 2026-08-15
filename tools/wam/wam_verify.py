"""WAM local validation v3: official single-watermark decoding."""
import os
import sys

import numpy as np
import cv2
import torch
from PIL import Image

sys.path.insert(0, r"E:\WorkSpace\.local\wam\watermark-anything")
sys.path.insert(0, r"E:\WorkSpace\.local\wam\watermark-anything\notebooks")

from inference_utils import load_model_from_checkpoint, msg2str
from watermark_anything.data.transforms import default_transform, unnormalize_img
from watermark_anything.data.metrics import msg_predict_inference

CKPT = r"E:\WorkSpace\.local\wam\watermark-anything\checkpoints\wam_mit.pth"
PARAMS = r"E:\WorkSpace\.local\wam\watermark-anything\checkpoints\params.json"
TD = r"E:\WorkSpace\.local\wam\test"
os.makedirs(TD, exist_ok=True)

torch.set_num_threads(os.cpu_count() or 4)
device = "cpu"

print("loading WAM...")
wam = load_model_from_checkpoint(PARAMS, CKPT).to(device).eval()

MSG = [True] + [False] * 10 + [True] * 5 + [False] * 6 + [True] * 10
MSG_STR = msg2str(MSG)
print(f"message: {MSG_STR}")

h, w = 512, 512
yy, xx = np.mgrid[0:h, 0:w]
img = np.zeros((h, w, 3), np.uint8)
img[..., 0] = (xx * 255 / w).astype(np.uint8)
img[..., 1] = (yy * 255 / h).astype(np.uint8)
img[..., 2] = ((xx + yy) * 255 / (w + h)).astype(np.uint8)
rng = np.random.default_rng(7)
img = cv2.addWeighted(img, 0.8, rng.integers(0, 70, (h, w, 3), np.uint8), 0.2, 0)
img_pil = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)

with torch.no_grad():
    img_t = default_transform(img_pil).unsqueeze(0).to(device)
    out = wam.embed(img_t, torch.tensor(MSG, dtype=torch.float32).unsqueeze(0).to(device))
    wm_img = out["imgs_w"]
    wm_np = unnormalize_img(wm_img).cpu().numpy().transpose(0, 2, 3, 1)[0]
    wm_np = (np.clip(wm_np, 0, 1) * 255).astype(np.uint8)

    def decode(rgb_arr):
        pil = Image.fromarray(rgb_arr)
        t = default_transform(pil).unsqueeze(0).to(device)
        preds = wam.detect(t)["preds"]
        mask_preds = torch.sigmoid(preds[:, 0:1, :, :])
        bit_preds = preds[:, 1:, :, :]
        pred_msg = msg_predict_inference(bit_preds, mask_preds)
        return "".join(str(int(b)) for b in (pred_msg[0] > 0.5).int().tolist())

    got = decode(wm_np)
    print(f"clean decode: {got} -> {'OK' if got == MSG_STR else 'FAIL'}")

    base = wm_np.copy()
    results = []

    def attack(name, arr):
        got = decode(arr)
        ok = got == MSG_STR
        results.append((name, ok))
        print(f"[{'PASS' if ok else 'FAIL'}] {name}: {got}")

    for q in (90, 70, 50, 30):
        p = os.path.join(TD, f"jpg_{q}.jpg")
        cv2.imwrite(p, cv2.cvtColor(base, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, q])
        attack(f"jpeg q{q}", cv2.imread(p)[:, :, ::-1].copy())

    for k in (3, 5, 7):
        attack(f"blur{k}", cv2.GaussianBlur(base, (k, k), 0))

    for frac in (0.75, 0.5, 0.3):
        ch = cw = int(256 * frac)
        y0 = x0 = (256 - ch) // 2
        attack(f"crop{int(frac*100)}", base[y0:y0 + ch, x0:x0 + cw])

    for ang in (5, 15, 30, 90):
        M = cv2.getRotationMatrix2D((128, 128), ang, 1.0)
        attack(f"rot{ang}", cv2.warpAffine(base, M, (256, 256)))

    for scale in (0.5, 0.25):
        small = cv2.resize(base, (int(256 * scale), int(256 * scale)))
        attack(f"resize{int(scale*100)}", cv2.resize(small, (256, 256)))

    for frac in (0.25, 0.5):
        dmg = base.copy()
        bh = bw = int(256 * frac)
        y0 = x0 = (256 - bh) // 2
        dmg[y0:y0 + bh, x0:x0 + bw] = 0
        attack(f"damage{int(frac*100)}", dmg)

    attack("bright-20", cv2.convertScaleAbs(base, alpha=0.8, beta=0))

passed = sum(1 for _, ok in results if ok)
print(f"\n===== WAM: {passed}/{len(results)} attacks survived =====")
