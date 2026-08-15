"""Robustness test (argv-safe): ASCII watermark via C++ CLI, Chinese watermark
via Python-embed -> C++-extract (no argv involved)."""
import os
import subprocess
import sys
import numpy as np
import cv2
from blind_watermark import WaterMark

CLI = r"E:\WorkSpace\.local\attack\bwm_cli.exe"
TD = r"E:\WorkSpace\.local\attack"
os.makedirs(TD, exist_ok=True)

TEXT_ASCII = "RobustnessTest-2026-Watermark-Attack"
TEXT_ZH = "秘密水印测试中文"
PW_WM, PW_IMG = 1, 1


def run_cli(args):
    r = subprocess.run([CLI] + args, capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"CLI failed: {args} rc={r.returncode} {r.stderr[:200]}")
    return r.stdout.decode("utf-8", "replace").strip()


def build_carrier():
    h, w = 768, 1024
    yy, xx = np.mgrid[0:h, 0:w]
    img = np.zeros((h, w, 3), np.uint8)
    img[..., 0] = (xx * 255 / w).astype(np.uint8)
    img[..., 1] = (yy * 255 / h).astype(np.uint8)
    img[..., 2] = ((xx + yy) * 255 / (w + h)).astype(np.uint8)
    rng = np.random.default_rng(11)
    img = cv2.addWeighted(img, 0.8, rng.integers(0, 80, (h, w, 3), np.uint8), 0.2, 0)
    return img


def attack_matrix(base, extract):
    results = []
    h, w = base.shape[:2]

    def attack(name, attacked_img):
        p = os.path.join(TD, f"atk_{name}.png")
        cv2.imwrite(p, attacked_img)
        got = extract(p)
        ok = got == expect
        results.append((name, ok, got))
        print(f"[{'PASS' if ok else 'FAIL'}] {name}: got={got!r}")

    for q in (95, 90, 80, 70, 60, 50):
        p = os.path.join(TD, f"atk_jpg_{q}.jpg")
        cv2.imwrite(p, base, [cv2.IMWRITE_JPEG_QUALITY, q])
        got = extract(p)
        ok = got == expect
        results.append((f"jpeg q{q}", ok, got))
        print(f"[{'PASS' if ok else 'FAIL'}] jpeg q{q}: got={got!r}")

    for k in (3, 5, 7):
        attack(f"blur{k}", cv2.GaussianBlur(base, (k, k), 0))

    for frac in (0.75, 0.5, 0.3):
        ch, cw = int(h * frac), int(w * frac)
        y0, x0 = (h - ch) // 2, (w - cw) // 2
        attack(f"crop{int(frac*100)}", base[y0:y0 + ch, x0:x0 + cw])

    for frac in (0.1, 0.25, 0.5):
        damaged = base.copy()
        bh, bw = int(h * frac), int(w * frac)
        y0, x0 = (h - bh) // 2, (w - bw) // 2
        damaged[y0:y0 + bh, x0:x0 + bw] = 0
        attack(f"damage{int(frac*100)}", damaged)

    for ang in (2, 5, 10):
        M = cv2.getRotationMatrix2D((w / 2, h / 2), ang, 1.0)
        attack(f"rot{ang}", cv2.warpAffine(base, M, (w, h)))

    for scale in (0.75, 0.5):
        attack(f"resize{int(scale*100)}", cv2.resize(base, (int(w * scale), int(h * scale))))

    attack("brightness-20", cv2.convertScaleAbs(base, alpha=0.8, beta=0))
    rng = np.random.default_rng(3)
    noise = base.astype(np.int16) + rng.integers(-40, 41, base.shape)
    attack("noise40", np.clip(noise, 0, 255).astype(np.uint8))

    passed = sum(1 for _, ok, _ in results if ok)
    print(f"\n===== {passed}/{len(results)} survived =====")
    return results


# ============ A: ASCII via C++ CLI embed + C++ extract ============
print("===== A: ASCII text (C++ embed -> C++ extract) =====")
expect = TEXT_ASCII
ori = os.path.join(TD, "ori_a.png")
cv2.imwrite(ori, build_carrier())
emb = os.path.join(TD, "emb_a.png")
out = run_cli(["embed_text", ori, TEXT_ASCII, str(PW_WM), str(PW_IMG), emb])
n = int(out.split("=")[1])
base = cv2.imread(emb)
results_a = attack_matrix(base, lambda p: run_cli(
    ["extract_text", p, str(n), str(PW_WM), str(PW_IMG)]))

# ============ B: Chinese via Python embed -> C++ extract ============
print("\n===== B: Chinese text (Python embed -> C++ extract) =====")
expect = TEXT_ZH
ori = os.path.join(TD, "ori_b.png")
cv2.imwrite(ori, build_carrier())
bwm = WaterMark(password_img=PW_IMG, password_wm=PW_WM)
bwm.read_img(ori)
bwm.read_wm(TEXT_ZH, mode="str")
n = len(bwm.wm_bit)
emb = os.path.join(TD, "emb_b.png")
bwm.embed(emb)
base = cv2.imread(emb)
results_b = attack_matrix(base, lambda p: run_cli(
    ["extract_text", p, str(n), str(PW_WM), str(PW_IMG)]))

print("\n===== SUMMARY =====")
print(f"A (ASCII): {sum(1 for _, ok, _ in results_a if ok)}/{len(results_a)}")
print(f"B (Chinese): {sum(1 for _, ok, _ in results_b if ok)}/{len(results_b)}")
sys.exit(0 if all(ok for _, ok, _ in results_a + results_b) else 1)
