"""Interoperability matrix: Python blind_watermark <-> C++ core.

Covers: str / img / bit modes, both directions, PNG lossless + JPEG compressed.
"""
import os
import subprocess
import sys
import numpy as np
import cv2
from blind_watermark import WaterMark

CLI = r"E:\WorkSpace\.local\work\bwm_cli.exe"
TD = r"E:\WorkSpace\.local\work\bwm_test"
os.makedirs(TD, exist_ok=True)

FAILURES = []
CHECKS = 0


def check(name, cond, detail=""):
    global CHECKS
    CHECKS += 1
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f"  <{detail}>" if (detail and not cond) else ""))
    if not cond:
        FAILURES.append(name)


def run_cli(args):
    r = subprocess.run([CLI] + args, capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"CLI failed: {args} rc={r.returncode} err={r.stderr[:200]}")
    return r.stdout


def py_embed_str(ori, text, pw_wm, pw_img, out):
    bwm = WaterMark(password_img=pw_img, password_wm=pw_wm)
    bwm.read_img(ori)
    bwm.read_wm(text, mode="str")
    bwm.embed(out)
    return len(bwm.wm_bit)


def py_extract_str(img, wm_len, pw_wm, pw_img):
    bwm = WaterMark(password_img=pw_img, password_wm=pw_wm)
    return bwm.extract(img, wm_shape=wm_len, mode="str")


def py_embed_img(ori, wm_img, pw_wm, pw_img, out):
    bwm = WaterMark(password_img=pw_img, password_wm=pw_wm)
    bwm.read_img(ori)
    bwm.read_wm(wm_img, mode="img")
    bwm.embed(out)
    return len(bwm.wm_bit)


def py_extract_img(img, h, w, pw_wm, pw_img, out):
    bwm = WaterMark(password_img=pw_img, password_wm=pw_wm)
    bwm.extract(img, wm_shape=(h, w), mode="img", out_wm_name=out)


def py_embed_bits(ori, bits, pw_wm, pw_img, out):
    bwm = WaterMark(password_img=pw_img, password_wm=pw_wm)
    bwm.read_img(ori)
    bwm.read_wm(bits, mode="bit")
    bwm.embed(out)
    return len(bwm.wm_bit)


def main():
    # ---- test carrier image: gradient + noise ----
    h, w = 512, 512
    yy, xx = np.mgrid[0:h, 0:w]
    img = np.zeros((h, w, 3), np.uint8)
    img[..., 0] = (xx * 255 / w).astype(np.uint8)
    img[..., 1] = (yy * 255 / h).astype(np.uint8)
    img[..., 2] = ((xx + yy) * 255 / (w + h)).astype(np.uint8)
    rng = np.random.default_rng(7)
    img = cv2.addWeighted(img, 0.85, rng.integers(0, 60, (h, w, 3), np.uint8), 0.15, 0)
    ori = os.path.join(TD, "ori.png")
    cv2.imwrite(ori, img)

    # ---- watermark logo (text-free b/w pattern) ----
    logo = np.zeros((32, 32), np.uint8)
    cv2.rectangle(logo, (4, 4), (27, 27), 255, -1)
    cv2.circle(logo, (16, 16), 8, 0, -1)
    cv2.line(logo, (4, 20), (27, 20), 0, 2)
    logo_img = os.path.join(TD, "logo.png")
    cv2.imwrite(logo_img, logo)

    texts = [
        "Hello, Blind Watermark!",
        "blind-watermark-interop-test-2026",
    ]
    bit_str = "1010100101011010" + "0" * 24 + "1111000011110000"
    pw_pairs = [(1, 1), (42, 7), (999, 1234)]

    # ============ A: Python embed -> C++ extract ============
    for pw_wm, pw_img in pw_pairs:
        for text in texts:
            out = os.path.join(TD, f"py_str_{pw_wm}_{pw_img}.png")
            n = py_embed_str(ori, text, pw_wm, pw_img, out)
            got = run_cli(["extract_text", out, str(n), str(pw_wm), str(pw_img)]).decode("utf-8", "replace").strip()
            check(f"py->cpp str pw=({pw_wm},{pw_img}) {text[:16]}", got == text, f"got={got!r}")

    # image watermark
    for pw_wm, pw_img in pw_pairs:
        out = os.path.join(TD, f"py_img_{pw_wm}_{pw_img}.png")
        n = py_embed_img(ori, logo_img, pw_wm, pw_img, out)
        got = os.path.join(TD, f"cpp_ext_img_{pw_wm}_{pw_img}.png")
        run_cli(["extract_img", out, "32", "32", str(pw_wm), str(pw_img), got])
        ref = cv2.imread(logo_img, cv2.IMREAD_GRAYSCALE)
        val = cv2.imread(got, cv2.IMREAD_GRAYSCALE)
        corr = np.corrcoef(ref.astype(float).ravel(), val.astype(float).ravel())[0, 1]
        check(f"py->cpp img pw=({pw_wm},{pw_img}) corr={corr:.3f}", corr > 0.85, f"corr={corr}")

    # bit watermark
    for pw_wm, pw_img in pw_pairs:
        out = os.path.join(TD, f"py_bit_{pw_wm}_{pw_img}.png")
        n = py_embed_bits(ori, [c == "1" for c in bit_str], pw_wm, pw_img, out)
        got = run_cli(["extract_bits", out, str(n), str(pw_wm), str(pw_img)]).decode().strip()
        check(f"py->cpp bit pw=({pw_wm},{pw_img})", got == bit_str, f"got={got!r}")

    # ============ B: C++ embed -> Python extract ============
    for pw_wm, pw_img in pw_pairs:
        for text in texts:
            out = os.path.join(TD, f"cpp_str_{pw_wm}_{pw_img}.png")
            n = int(run_cli(["embed_text", ori, text, str(pw_wm), str(pw_img), out]).decode().split()[-1].split("=")[1])
            got = py_extract_str(out, n, pw_wm, pw_img)
            check(f"cpp->py str pw=({pw_wm},{pw_img}) {text[:16]}", got == text, f"got={got!r}")

    for pw_wm, pw_img in pw_pairs:
        out = os.path.join(TD, f"cpp_img_{pw_wm}_{pw_img}.png")
        n = int(run_cli(["embed_img", ori, logo_img, str(pw_wm), str(pw_img), out]).decode().split()[-1].split("=")[1])
        got = os.path.join(TD, f"py_ext_img_{pw_wm}_{pw_img}.png")
        py_extract_img(out, 32, 32, pw_wm, pw_img, got)
        ref = cv2.imread(logo_img, cv2.IMREAD_GRAYSCALE)
        val = cv2.imread(got, cv2.IMREAD_GRAYSCALE)
        corr = np.corrcoef(ref.astype(float).ravel(), val.astype(float).ravel())[0, 1]
        check(f"cpp->py img pw=({pw_wm},{pw_img}) corr={corr:.3f}", corr > 0.85, f"corr={corr}")

    for pw_wm, pw_img in pw_pairs:
        out = os.path.join(TD, f"cpp_bit_{pw_wm}_{pw_img}.png")
        n = int(run_cli(["embed_bits", ori, bit_str, str(pw_wm), str(pw_img), out]).decode().split()[-1].split("=")[1])
        bwm = WaterMark(password_img=pw_img, password_wm=pw_wm)
        got = bwm.extract(out, wm_shape=n, mode="bit")
        got_str = "".join("1" if b > 0.5 else "0" for b in got)
        check(f"cpp->py bit pw=({pw_wm},{pw_img})", got_str == bit_str, f"got={got_str!r}")

    # ============ C: JPEG robustness (both directions) ============
    for pw_wm, pw_img in [(1, 1)]:
        for q in (95, 80):
            # py embed -> jpeg -> cpp extract
            out = os.path.join(TD, f"py_jpg_{q}.png")
            n = py_embed_str(ori, texts[0], pw_wm, pw_img, out)
            jpg = os.path.join(TD, f"py_jpg_{q}.jpg")
            im = cv2.imread(out)
            cv2.imwrite(jpg, im, [cv2.IMWRITE_JPEG_QUALITY, q])
            got = run_cli(["extract_text", jpg, str(n), str(pw_wm), str(pw_img)]).decode("utf-8", "replace").strip()
            check(f"py->cpp jpeg q={q}", got == texts[0], f"got={got!r}")

            # cpp embed -> jpeg -> python extract
            out = os.path.join(TD, f"cpp_jpg_{q}.png")
            n = int(run_cli(["embed_text", ori, texts[0], str(pw_wm), str(pw_img), out]).decode().split()[-1].split("=")[1])
            jpg = os.path.join(TD, f"cpp_jpg_{q}.jpg")
            im = cv2.imread(out)
            cv2.imwrite(jpg, im, [cv2.IMWRITE_JPEG_QUALITY, q])
            got = py_extract_str(jpg, n, pw_wm, pw_img)
            check(f"cpp->py jpeg q={q}", got == texts[0], f"got={got!r}")

    # ============ D: Chinese text (UTF-8 payload) ============
    zh = "涓枃姘村嵃娴嬭瘯锛欯浣滆€?2026 漏"
    # py embed (utf-8 args via python, no console encoding issue)
    out = os.path.join(TD, "py_zh.png")
    n = py_embed_str(ori, zh, 1, 1, out)
    got = run_cli(["extract_text", out, str(n), "1", "1"]).decode("utf-8", "replace").strip()
    check("py->cpp Chinese text", got == zh, f"got={got!r}")
    # cpp embed: write text via file to avoid argv encoding (argv is ANSI on MinGW)
    tf = os.path.join(TD, "zh.txt")
    with open(tf, "wb") as f:
        f.write(zh.encode("utf-8"))
    out = os.path.join(TD, "cpp_zh.png")
    run_cli(["embed_text_file", ori, tf, "1", "1", out]) if os.path.exists(
        os.path.join(os.path.dirname(CLI), "bwm_cli_file.exe")) else None

    print(f"\n===== RESULT: {CHECKS} checks, {len(FAILURES)} failures =====")
    for f in FAILURES:
        print("  FAIL:", f)
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()



