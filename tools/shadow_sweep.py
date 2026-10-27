#!/usr/bin/env python3
"""去阴影参数枚举实验（v1.1 Phase 2，只出报告，不改生产代码）。

复现 `packages/fairscan_engine/.../ShadowCorrection.kt` 的当前实现作为 baseline，
用 `test_assets/fixtures/page.jpg` 合成 4 类阴影样本（合成笔迹含红笔与浅色笔迹），
枚举 Gaussian sigma 分母 / strength / min range / target percentile，
输出指标 CSV 与对比图。

用法：
    python tools/shadow_sweep.py [--full-res]

输出：
    docs/quality/shadow_sweep/metrics.csv
    docs/quality/shadow_sweep/contact_sheet.jpg

只依赖 Python + OpenCV + NumPy。合成样本仅用于初步筛选，不能替代真实样张验收。
"""

from __future__ import annotations

import argparse
import csv
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

REPO = Path(__file__).resolve().parent.parent
FIXTURE = REPO / "test_assets" / "fixtures" / "page.jpg"
OUT_DIR = REPO / "docs" / "quality" / "shadow_sweep"
SHEET_PATH = OUT_DIR / "contact_sheet.jpg"
CSV_PATH = OUT_DIR / "metrics.csv"

# ShadowCorrection.kt 的当前默认值
BASELINE = {"sigma_div": 12.0, "strength": 0.22, "min_range": 14.0, "target_pct": 0.75}

SIGMA_DIVS = [8.0, 10.0, 12.0, 16.0, 20.0]
STRENGTHS = [0.15, 0.22, 0.30, 0.40]
MIN_RANGES = [8.0, 14.0, 20.0]
TARGET_PCTS = [0.65, 0.75, 0.85]

WORK_MAX_DIM = 800  # 速度优先的工作分辨率；sigma = maxDim/sigma_div 是相对尺度，行为一致


# --------------------------------------------------------------------------- #
# 合成样本
# --------------------------------------------------------------------------- #
def load_page(max_dim: int) -> np.ndarray:
    img = cv2.imread(str(FIXTURE))
    if img is None:
        raise SystemExit(f"读不到夹具图：{FIXTURE}")
    h, w = img.shape[:2]
    scale = max_dim / max(h, w)
    if scale < 1.0:
        img = cv2.resize(img, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    return img


def page_interior(img: np.ndarray) -> tuple[int, int, int, int]:
    h, w = img.shape[:2]
    return int(0.09 * w), int(0.08 * h), int(0.91 * w), int(0.92 * h)


def draw_content(img: np.ndarray, seed: int = 7) -> np.ndarray:
    """在页面上合成“作业内容”：手写行、浅色铅笔痕迹、红笔批改。"""
    rng = np.random.default_rng(seed)
    out = img.copy()
    x0, y0, x1, y1 = page_interior(out)
    width = x1 - x0
    height = y1 - y0

    # 1) 手写正文：抖动折线模拟连笔
    line_gap = max(10, height // 22)
    for row in range(9):
        y = y0 + int(0.06 * height) + row * line_gap
        x = x0 + int(0.03 * width)
        while x < x1 - int(0.10 * width):
            seg = int(rng.integers(28, 70))
            points = []
            for k in range(6):
                px = x + seg * k / 5.0
                py = y + 6 * np.sin(px / 17.0) + rng.integers(-3, 4)
                points.append([int(px), int(py)])
            shade = int(rng.integers(15, 45))
            cv2.polylines(out, [np.array(points)], False, (shade, shade, shade), 2, cv2.LINE_AA)
            x += seg + int(rng.integers(8, 30))

    # 2) 浅色铅笔痕迹（模拟浅色笔迹）
    for row in (3, 6):
        y = y0 + int(0.06 * height) + row * line_gap + line_gap // 2
        pts = np.array(
            [[x0 + int(0.10 * width) + i * 12, y + int(3 * np.sin(i / 2.0))] for i in range(24)]
        )
        cv2.polylines(out, [pts], False, (176, 176, 176), 2, cv2.LINE_AA)

    # 3) 红笔批改：下划线 + 对勾 + 圈注
    red = (30, 30, 215)
    y_red = y0 + int(0.06 * height) + 4 * line_gap
    cv2.line(out, (x0 + int(0.05 * width), y_red), (x0 + int(0.55 * width), y_red), red, 3, cv2.LINE_AA)
    tick_x = x1 - int(0.12 * width)
    tick = np.array(
        [[tick_x, y_red - 14], [tick_x + 10, y_red + 4], [tick_x + 30, y_red - 26]]
    )
    cv2.polylines(out, [tick], False, red, 3, cv2.LINE_AA)
    cv2.ellipse(
        out,
        (x0 + int(0.30 * width), y0 + int(0.55 * height)),
        (26, 16),
        0,
        0,
        360,
        red,
        2,
        cv2.LINE_AA,
    )
    return out


def content_masks(content: np.ndarray) -> dict[str, np.ndarray]:
    x0, y0, x1, y1 = page_interior(content)
    h, w = content.shape[:2]
    rect = np.zeros((h, w), dtype=bool)
    rect[y0:y1, x0:x1] = True

    lab = cv2.cvtColor(content, cv2.COLOR_BGR2LAB)
    light = content[:, :, 0].astype(np.int16)
    blue = content[:, :, 1].astype(np.int16)
    red = content[:, :, 2].astype(np.int16)
    redness = red - (blue + light) // 2

    l_channel = lab[:, :, 0]
    return {
        "rect": rect,
        "paper": rect & (l_channel >= 228),
        "ink": rect & (l_channel <= 120) & (redness < 40),
        "light": rect & (l_channel >= 140) & (l_channel <= 205) & (redness < 40),
        "red": rect & (redness >= 45),
    }


# --------------------------------------------------------------------------- #
# 合成阴影
# --------------------------------------------------------------------------- #
def make_shadow(img: np.ndarray, kind: str, level: int) -> np.ndarray:
    h, w = img.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)

    if kind == "linear":  # 线性渐变：左 0 → 右 level 灰阶
        delta = (xx / (w - 1)) * level
    elif kind == "soft":  # 单侧软阴影：右半边，边缘大半径过渡
        delta = cv2.GaussianBlur(
            np.where(xx > w * 0.45, level, 0).astype(np.float32), (0, 0), w * 0.18
        )
    elif kind == "hard":  # 硬边阴影：右侧一块锐利暗区（手机/手的影子）
        delta = np.zeros((h, w), np.float32)
        delta[:, int(w * 0.55) :] = level
    elif kind == "vignette":  # 暗角：四角最暗
        cx, cy = w / 2.0, h / 2.0
        radius = np.sqrt(((xx - cx) / cx) ** 2 + ((yy - cy) / cy) ** 2) / np.sqrt(2.0)
        delta = level * np.clip((radius - 0.35) / 0.65, 0, 1)
    else:
        raise ValueError(kind)

    # 乘性暗化更接近真实阴影，同时保留“灰阶幅度”这个可读量纲
    factor = np.clip(1.0 - delta / 255.0, 0.0, 1.0)
    return np.clip(img.astype(np.float32) * factor[..., None], 0, 255).astype(np.uint8)


# --------------------------------------------------------------------------- #
# ShadowCorrection.kt 的 Python 复现
# --------------------------------------------------------------------------- #
def percentile_l(channel: np.ndarray, p: float) -> float:
    return float(np.percentile(channel, p * 100.0))


def shadow_correction(
    img: np.ndarray,
    sigma_div: float,
    strength: float,
    min_range: float,
    target_pct: float,
) -> tuple[np.ndarray, bool, float]:
    """返回 (输出, 是否真的施加, background range)。逐行对应 Kotlin 实现。"""
    if img.ndim != 3 or img.shape[2] != 3:
        return img, False, 0.0
    max_dim = float(max(img.shape[0], img.shape[1]))
    if max_dim < 64:
        return img, False, 0.0

    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
    l_channel = lab[:, :, 0]
    l_float = l_channel.astype(np.float32)

    sigma = max(max_dim / sigma_div, 8.0)
    background = cv2.GaussianBlur(l_float, (0, 0), sigmaX=sigma)
    background8 = np.clip(np.rint(background), 0, 255).astype(np.uint8)
    bg_range = percentile_l(background8, 0.95) - percentile_l(background8, 0.05)
    if bg_range < min_range:
        return img, False, bg_range

    target = percentile_l(l_channel, target_pct)
    corrected = np.clip(l_float + strength * (target - background), 0.0, 255.0)
    out_lab = lab.copy()
    out_lab[:, :, 0] = np.clip(np.rint(corrected), 0, 255).astype(np.uint8)
    return cv2.cvtColor(out_lab, cv2.COLOR_LAB2BGR), True, bg_range


# --------------------------------------------------------------------------- #
# 指标
# --------------------------------------------------------------------------- #
@dataclass
class Score:
    uniformity: float
    flat_ratio: float
    ink_contrast: float
    ink_retention: float
    light_contrast: float
    light_blowout: float
    ink_washout: float
    red_retention: float
    applied: bool
    bg_range: float
    ms: float
    composite: float = 0.0
    parts: dict[str, float] = field(default_factory=dict)


def evaluate(
    result: np.ndarray,
    reference: np.ndarray,
    masks: dict[str, np.ndarray],
    clean_stats: dict[str, float],
    applied: bool,
    bg_range: float,
    ms: float,
) -> Score:
    l_result = cv2.cvtColor(result, cv2.COLOR_BGR2LAB)[:, :, 0]
    l_ref = cv2.cvtColor(reference, cv2.COLOR_BGR2LAB)[:, :, 0]
    paper = masks["paper"]
    ink = masks["ink"]
    light = masks["light"]
    red = masks["red"]

    paper_l = l_result[paper].astype(np.float32)
    ref_paper_l = l_ref[paper].astype(np.float32)
    uniformity = float(np.percentile(paper_l, 95) - np.percentile(paper_l, 5))
    uniformity_in = float(np.percentile(ref_paper_l, 95) - np.percentile(ref_paper_l, 5))
    flat_ratio = uniformity / max(uniformity_in, 1e-6)

    ink_contrast = float(paper_l.mean() - l_result[ink].mean())
    ink_retention = ink_contrast / max(clean_stats["ink_contrast"], 1e-6)
    light_contrast = float(paper_l.mean() - l_result[light].mean())
    # 死白风险：本来能看见的浅色笔迹/字迹被提到纸面白里
    light_blowout = float((l_result[light] >= 250).mean())
    ink_washout = float((l_result[ink] > 200).mean())

    def redness(img: np.ndarray) -> float:
        b = img[:, :, 0].astype(np.int16)
        g = img[:, :, 1].astype(np.int16)
        r = img[:, :, 2].astype(np.int16)
        return float((r[red] - (g[red] + b[red]) // 2).mean())

    base_red = redness(reference)
    red_retention = redness(result) / base_red if base_red > 1e-6 else 1.0

    parts = {
        # 背景均匀度：60 灰阶的 P95-P5 视为完全失败
        "uniformity": 1.0 - min(uniformity / 60.0, 1.0),
        "ink_contrast": min(max(ink_retention, 0.0), 1.2) / 1.2,
        "light_blowout": 1.0 - min(light_blowout / 0.5, 1.0),
        "ink_washout": 1.0 - min(ink_washout / 0.5, 1.0),
        "red_retention": float(np.clip(red_retention, 0.0, 1.0)),
    }
    composite = (
        0.35 * parts["uniformity"]
        + 0.25 * parts["ink_contrast"]
        + 0.15 * parts["light_blowout"]
        + 0.15 * parts["ink_washout"]
        + 0.10 * parts["red_retention"]
    )
    if not applied:
        composite = 0.0  # 没有施加 == 没有去阴影，样本里一律不合格

    return Score(
        uniformity=uniformity,
        flat_ratio=flat_ratio,
        ink_contrast=ink_contrast,
        ink_retention=ink_retention,
        light_contrast=light_contrast,
        light_blowout=light_blowout,
        ink_washout=ink_washout,
        red_retention=red_retention,
        applied=applied,
        bg_range=bg_range,
        ms=ms,
        composite=composite,
        parts=parts,
    )


# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #
def label(img: np.ndarray, text: str) -> np.ndarray:
    out = img.copy()
    cv2.rectangle(out, (0, 0), (out.shape[1], 26), (20, 20, 20), -1)
    cv2.putText(out, text, (8, 19), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1, cv2.LINE_AA)
    return out


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="去阴影参数枚举")
    parser.add_argument(
        "--full-res", action="store_true", help=f"在夹具原始分辨率上跑（默认缩到 {WORK_MAX_DIM}px）"
    )
    args = parser.parse_args()

    page = load_page(1200 if args.full_res else WORK_MAX_DIM)
    content = draw_content(page)
    masks = content_masks(content)
    clean = content
    clean_l = cv2.cvtColor(clean, cv2.COLOR_BGR2LAB)[:, :, 0].astype(np.float32)
    clean_stats = {
        "ink_contrast": float(clean_l[masks["paper"]].mean() - clean_l[masks["ink"]].mean()),
        "uniformity": float(
            np.percentile(clean_l[masks["paper"]], 95) - np.percentile(clean_l[masks["paper"]], 5)
        ),
    }

    samples: list[tuple[str, np.ndarray]] = [
        ("linear20", make_shadow(content, "linear", 20)),
        ("linear40", make_shadow(content, "linear", 40)),
        ("linear60", make_shadow(content, "linear", 60)),
        ("soft40", make_shadow(content, "soft", 40)),
        ("hard40", make_shadow(content, "hard", 40)),
        ("vignette40", make_shadow(content, "vignette", 40)),
    ]

    rows: list[dict[str, object]] = []
    best_per_sample: dict[str, tuple[dict[float, ...], Score]] = {}
    sheet_tiles: dict[str, list[np.ndarray]] = {}

    print(f"工作分辨率 {content.shape[1]}x{content.shape[0]}，样本 {len(samples)} 组，"
          f"参数组合 {len(SIGMA_DIVS) * len(STRENGTHS) * len(MIN_RANGES) * len(TARGET_PCTS)} 组/样本")

    for name, shadowed in samples:
        best_obj: Score | None = None
        best_params: tuple[float, ...] | None = None
        best_img: np.ndarray | None = None
        baseline_img: np.ndarray | None = None
        baseline_score: Score | None = None

        for sigma_div in SIGMA_DIVS:
            for strength in STRENGTHS:
                for min_range in MIN_RANGES:
                    for target_pct in TARGET_PCTS:
                        start = time.perf_counter()
                        out, applied, bg_range = shadow_correction(
                            shadowed, sigma_div, strength, min_range, target_pct
                        )
                        ms = (time.perf_counter() - start) * 1000.0
                        score = evaluate(out, shadowed, masks, clean_stats, applied, bg_range, ms)
                        params = (sigma_div, strength, min_range, target_pct)
                        rows.append(
                            {
                                "sample": name,
                                "sigma_div": sigma_div,
                                "strength": strength,
                                "min_range": min_range,
                                "target_pct": target_pct,
                                "applied": applied,
                                "bg_range": round(bg_range, 1),
                                "uniformity": round(score.uniformity, 2),
                                "flat_ratio": round(score.flat_ratio, 3),
                                "ink_contrast": round(score.ink_contrast, 2),
                                "ink_retention": round(score.ink_retention, 3),
                                "light_contrast": round(score.light_contrast, 2),
                                "light_blowout": round(score.light_blowout, 4),
                                "ink_washout": round(score.ink_washout, 4),
                                "red_retention": round(score.red_retention, 3),
                                "ms": round(ms, 2),
                                "composite": round(score.composite, 4),
                            }
                        )
                        if score.composite > (best_obj.composite if best_obj else -1.0):
                            best_obj = score
                            best_params = params
                            best_img = out

                        if params == tuple(
                            BASELINE[k] for k in ("sigma_div", "strength", "min_range", "target_pct")
                        ):
                            baseline_img = out
                            baseline_score = score

        assert best_params is not None and best_img is not None and baseline_img is not None
        assert best_obj is not None and baseline_score is not None
        best_per_sample[name] = (best_params, best_obj)
        sheet_tiles[name] = [shadowed, baseline_img, best_img, clean]
        print(
            f"{name:11s} baseline={baseline_score.composite:.3f} "
            f"(uniformity={baseline_score.uniformity:.1f})  "
            f"best={best_params} score={best_obj.composite:.3f}"
        )

    # CSV
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with CSV_PATH.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"已写入 {CSV_PATH.relative_to(REPO)}（{len(rows)} 行）")

    # Contact sheet：行 = 样本，列 = 合成阴影 / baseline / 最优 / 干净参考
    tiles = []
    headers = ["shadowed", "baseline (12/0.22/14/0.75)", "best", "clean"]
    for name, images in sheet_tiles.items():
        row = [label(img, f"{name} | {headers[i]}") for i, img in enumerate(images)]
        tiles.append(row)

    tile_h, tile_w = 320, 240
    sheet = np.full((len(tiles) * (tile_h + 8) + 8, 4 * (tile_w + 8) + 8, 3), 245, np.uint8)
    for r, row in enumerate(tiles):
        for c, img in enumerate(row):
            resized = cv2.resize(img, (tile_w, tile_h), interpolation=cv2.INTER_AREA)
            y = 8 + r * (tile_h + 8)
            x = 8 + c * (tile_w + 8)
            sheet[y : y + tile_h, x : x + tile_w] = resized
    cv2.imwrite(str(SHEET_PATH), sheet, [cv2.IMWRITE_JPEG_QUALITY, 88])
    print(f"已写入 {SHEET_PATH.relative_to(REPO)}")

    # 参数维度的平均分，用来写“推荐区间”
    print("\n各参数取值的平均分：")
    for key, values in (
        ("sigma_div", SIGMA_DIVS),
        ("strength", STRENGTHS),
        ("min_range", MIN_RANGES),
        ("target_pct", TARGET_PCTS),
    ):
        line = []
        for value in values:
            subset = [r for r in rows if float(r[key]) == value]
            mean = sum(float(r["composite"]) for r in subset) / len(subset)
            line.append(f"{key}={value}: {mean:.3f}")
        print("  " + "  ".join(line))

    print("\n最优参数（按样本）：")
    for name, (params, score) in best_per_sample.items():
        print(
            f"  {name:11s} sigma_div={params[0]:<5g} strength={params[1]:<5g} "
            f"min_range={params[2]:<5g} target={params[3]:<5g} "
            f"uniformity={score.uniformity:5.1f} flat={score.flat_ratio:4.2f} "
            f"ink={score.ink_retention:4.2f} light_out={score.light_blowout:4.2f} "
            f"red={score.red_retention:.2f}"
        )

    # 误触发检查：没有阴影的干净页上，背景 range 是多少，min_range 决定是否生效
    print("\n误触发检查（干净无阴影样本，sigma_div=12 / strength=0.22）：")
    _, _, clean_range = shadow_correction(clean, **BASELINE)
    print(f"  干净页 background range = {clean_range:.1f}")
    for min_range in MIN_RANGES:
        _, fired, _ = shadow_correction(clean, 12.0, 0.22, min_range, 0.75)
        print(f"  min_range={min_range:<5g} -> {'施加' if fired else '跳过'}")
    print("\n各合成阴影样本在 baseline 下的 background range：")
    for name, shadowed in samples:
        _, fired, rng_value = shadow_correction(shadowed, **BASELINE)
        print(f"  {name:11s} range={rng_value:5.1f} -> {'施加' if fired else '跳过'}")


if __name__ == "__main__":
    main()
