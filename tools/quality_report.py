#!/usr/bin/env python3
"""Sprint 1 quality evidence builder.

Consumes the raw engine output pulled from the device (docs/quality/raw) and
produces the review bundle in docs/quality:

  hwN_detection.jpg       detected quad drawn on the source photo
  hwN_pagecheck.jpg       detected quad vs. an independent page-contour estimate
  hwN_2mp.jpg / _4mp.jpg  full grayscale output at both pixel budgets
  hwN_compare.jpg         2 MP (left) vs 4 MP (right), equal height
  hwN_cropfix.jpg         auto frame vs. manual-corner frame (rejected samples)
  hwN_detail_*            native 1:1 crops of the densest small-text region
  quality_metrics.json    numeric checks used by the acceptance report
  review.html             everything in one page for human review

Samples whose auto frame was rejected by the engine use the manual-corner
output for the 2 MP / 4 MP comparison, so the quality comparison is always made
on the whole page rather than on a clipped strip.

Usage: python tools/quality_report.py
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "docs" / "quality" / "raw"
OUT = ROOT / "docs" / "quality"
SAMPLES = ROOT / "test_assets" / "real_samples"

# Sample id -> source photo. 1/2/3 are the fixed test set (51.jpg/49.jpg/47.jpg).
SOURCES = {"hw1": "1.jpg", "hw2": "2.jpg", "hw3": "3.jpg"}
BUDGETS = (2_000_000, 4_000_000)


def load_rgb(path: Path) -> np.ndarray:
    data = np.fromfile(str(path), dtype=np.uint8)
    image = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if image is None:
        raise SystemExit(f"cannot decode {path}")
    return image


def write_jpg(path: Path, image: np.ndarray, quality: int = 90) -> None:
    ok, buf = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, quality])
    if not ok:
        raise SystemExit(f"cannot encode {path}")
    path.write_bytes(buf.tobytes())


def write_png(path: Path, image: np.ndarray) -> None:
    ok, buf = cv2.imencode(".png", image)
    if not ok:
        raise SystemExit(f"cannot encode {path}")
    path.write_bytes(buf.tobytes())


def label(image: np.ndarray, text: str) -> np.ndarray:
    """Draws a legible banner above the image."""
    height = 46
    bar = np.full((height, image.shape[1], 3), 24, np.uint8)
    cv2.putText(bar, text, (14, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.9,
                (235, 235, 235), 2, cv2.LINE_AA)
    return np.vstack([bar, image])


def fit_height(image: np.ndarray, height: int) -> np.ndarray:
    scale = height / image.shape[0]
    width = max(1, int(round(image.shape[1] * scale)))
    return cv2.resize(image, (width, height), interpolation=cv2.INTER_AREA)


def quad_points(quad: list[list[float]], width: int, height: int) -> np.ndarray:
    return np.array(
        [[int(round(x * width)), int(round(y * height))] for x, y in quad],
        dtype=np.int32,
    )


def estimate_page(gray: np.ndarray) -> np.ndarray | None:
    """Independent page estimate: Otsu paper/background split, largest region.

    Deliberately simple and unrelated to the engine's segmentation model, so a
    disagreement with the detected quad is a real signal rather than an echo.
    """
    small = cv2.resize(gray, (0, 0), fx=0.25, fy=0.25, interpolation=cv2.INTER_AREA)
    blurred = cv2.GaussianBlur(small, (7, 7), 0)
    _, paper = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    kernel = np.ones((7, 7), np.uint8)
    paper = cv2.morphologyEx(paper, cv2.MORPH_OPEN, kernel, iterations=2)
    paper = cv2.morphologyEx(paper, cv2.MORPH_CLOSE, kernel, iterations=3)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(paper, connectivity=8)
    if count <= 1:
        return None
    best = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    mask = np.where(labels == best, 255, 0).astype(np.uint8)
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None
    hull = cv2.convexHull(max(contours, key=cv2.contourArea))
    return np.array(
        [[int(p[0][0] / 0.25), int(p[0][1] / 0.25)] for p in hull], np.int32
    )


def poly_mask(shape: tuple[int, int], polygon: np.ndarray) -> np.ndarray:
    mask = np.zeros(shape, np.uint8)
    cv2.fillPoly(mask, [np.asarray(polygon, np.int32)], 255)
    return mask


def source_ink(gray: np.ndarray) -> np.ndarray:
    """Handwriting/print on the photo, independent of lighting."""
    block = max(31, (min(gray.shape) // 40) | 1)
    ink = cv2.adaptiveThreshold(
        gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, block, 18
    )
    return cv2.morphologyEx(ink, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))


def ink_inside(ink: np.ndarray, polygon: np.ndarray) -> tuple[int, int, float]:
    mask = poly_mask(ink.shape, polygon) > 0
    total = int(np.count_nonzero(ink))
    inside = int(np.count_nonzero((ink > 0) & mask))
    return inside, total, (inside / total if total else 0.0)


def detail_window(sharp: np.ndarray, size: tuple[int, int]) -> tuple[int, int]:
    """Top-left of the window with the most edge energy (dense small writing)."""
    edges = cv2.Canny(cv2.cvtColor(sharp, cv2.COLOR_BGR2GRAY), 60, 160)
    integral = cv2.integral((edges > 0).astype(np.uint8))
    win_w, win_h = size
    height, width = edges.shape[:2]
    win_w = min(win_w, width)
    win_h = min(win_h, height)
    sums = (
        integral[win_h:, win_w:]
        - integral[:-win_h, win_w:]
        - integral[win_h:, :-win_w]
        + integral[:-win_h, :-win_w]
    )
    y, x = np.unravel_index(int(np.argmax(sums)), sums.shape)
    # Trim the outer 3% so we never sample the page border / background.
    margin_x, margin_y = int(width * 0.03), int(height * 0.03)
    x = int(np.clip(x, margin_x, max(margin_x, width - win_w - margin_x)))
    y = int(np.clip(y, margin_y, max(margin_y, height - win_h - margin_y)))
    return x, y


def crop_native(image: np.ndarray, box: tuple[int, int, int, int]) -> np.ndarray:
    x, y, w, h = box
    return image[y:y + h, x:x + w].copy()


def stroke_stats(region: np.ndarray) -> dict:
    """Faint-stroke retention proxies measured on the same physical region."""
    block = max(15, (min(region.shape) // 25) | 1)
    ink = cv2.adaptiveThreshold(
        region, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, block, 10
    )
    values = region[ink > 0]
    faint = int(np.count_nonzero((ink > 0) & (region > 120) & (region < 205)))
    return {
        "inkPixels": int(np.count_nonzero(ink)),
        "faintPixels": faint,
        "inkStd": round(float(values.std()) if values.size else 0.0, 1),
        "p5": int(np.percentile(values, 5)) if values.size else 255,
        "min": int(values.min()) if values.size else 255,
    }


def sample_report(sample_id: str, metrics: dict) -> dict:
    source = load_rgb(SAMPLES / SOURCES[sample_id])
    detect = next(r for r in metrics["runs"] if r["id"] == sample_id and "detect" in r)
    runs = [r for r in metrics["runs"] if r["id"] == sample_id and "budget" in r]
    auto = {r["budget"]: r for r in runs if not r.get("manual")}
    manual = {r["budget"]: r for r in runs if r.get("manual")}
    chosen = manual or auto
    source_h, source_w = source.shape[:2]
    quad = detect["detect"]["quad"]
    polygon = quad_points(quad, source_w, source_h)
    gray = cv2.cvtColor(source, cv2.COLOR_BGR2GRAY)
    ink = source_ink(gray)
    ink_in, ink_total, ink_share = ink_inside(ink, polygon)

    # --- detection review overlay (quad on the original photo) ---
    overlay = source.copy()
    cv2.polylines(overlay, [polygon], True, (60, 220, 90), 6, cv2.LINE_AA)
    for index, (x, y) in enumerate(polygon):
        cv2.circle(overlay, (int(x), int(y)), 22, (40, 90, 250), -1, cv2.LINE_AA)
        cv2.circle(overlay, (int(x), int(y)), 22, (255, 255, 255), 3, cv2.LINE_AA)
        cv2.putText(overlay, str(index + 1), (int(x) + 28, int(y) - 18),
                    cv2.FONT_HERSHEY_SIMPLEX, 1.1, (40, 90, 250), 3, cv2.LINE_AA)
    write_jpg(OUT / f"{sample_id}_detection.jpg", fit_height(overlay, 1400), 86)

    # --- independent page estimate vs. the engine's quad ---
    page = estimate_page(gray)
    page_iou = None
    if page is not None:
        page_mask = poly_mask(gray.shape, page)
        quad_mask = poly_mask(gray.shape, polygon)
        inter = int(np.count_nonzero(page_mask & quad_mask))
        union = int(np.count_nonzero((page_mask | quad_mask) > 0))
        page_iou = inter / union if union else None
        check = source.copy()
        cv2.polylines(check, [page], True, (230, 80, 230), 5, cv2.LINE_AA)
        cv2.polylines(check, [polygon], True, (60, 220, 90), 5, cv2.LINE_AA)
        write_jpg(OUT / f"{sample_id}_pagecheck.jpg", fit_height(check, 1200), 85)

    # --- 2 MP vs 4 MP on the accepted frame (manual corners when rejected) ---
    images = {}
    for budget in BUDGETS:
        run = chosen[budget]
        output = load_rgb(RAW / run["file"])
        images[budget] = output
        tag = "2mp" if budget == 2_000_000 else "4mp"
        write_jpg(OUT / f"{sample_id}_{tag}.jpg", output, 92)
    low, high = images[2_000_000], images[4_000_000]

    compare_height = 1500
    left = label(
        fit_height(low, compare_height),
        f"{sample_id} 2MP  {low.shape[1]}x{low.shape[0]}  "
        f"{chosen[2_000_000]['fileBytes'] // 1024} KB",
    )
    right = label(
        fit_height(high, compare_height),
        f"{sample_id} 4MP  {high.shape[1]}x{high.shape[0]}  "
        f"{chosen[4_000_000]['fileBytes'] // 1024} KB",
    )
    gap = np.full((left.shape[0], 16, 3), 12, np.uint8)
    write_jpg(OUT / f"{sample_id}_compare.jpg", np.hstack([left, gap, right]), 88)

    # --- auto frame vs. the manual-corner frame it was replaced with ---
    crop_fix = None
    if manual:
        auto_out = load_rgb(RAW / auto[4_000_000]["file"])
        manual_out = load_rgb(RAW / manual[4_000_000]["file"])
        left = label(
            fit_height(auto_out, compare_height),
            f"auto {auto_out.shape[1]}x{auto_out.shape[0]} — 引擎判定不可信",
        )
        right = label(
            fit_height(manual_out, compare_height),
            f"manual {manual_out.shape[1]}x{manual_out.shape[0]} — 四角修正后整页",
        )
        gap = np.full((left.shape[0], 16, 3), 12, np.uint8)
        write_jpg(OUT / f"{sample_id}_cropfix.jpg", np.hstack([left, gap, right]), 88)
        crop_fix = f"{sample_id}_cropfix.jpg"

    # --- 1:1 detail crops of the densest small-text region ---
    win_w, win_h = 760, 520
    x, y = detail_window(high, (win_w, win_h))
    high_crop = crop_native(high, (x, y, win_w, win_h))
    scale = low.shape[1] / high.shape[1]
    low_w = max(1, int(round(win_w * scale)))
    low_h = max(1, int(round(win_h * scale)))
    low_x = min(int(round(x * scale)), max(0, low.shape[1] - low_w))
    low_y = min(int(round(y * scale)), max(0, low.shape[0] - low_h))
    low_crop = crop_native(low, (low_x, low_y, low_w, low_h))

    write_png(OUT / f"{sample_id}_detail_2mp.png", label(low_crop, "2MP 1:1"))
    write_png(OUT / f"{sample_id}_detail_4mp.png", label(high_crop, "4MP 1:1"))
    # Side-by-side at native scale: both panels show the same physical region,
    # so the 4 MP panel simply holds more captured pixels.
    pad_h = max(low_crop.shape[0], high_crop.shape[0]) + 46
    pair = np.full((pad_h, low_crop.shape[1] + 16 + high_crop.shape[1], 3), 12, np.uint8)
    pair[:low_crop.shape[0] + 46, :low_crop.shape[1]] = label(low_crop, "2MP 1:1")
    pair[:high_crop.shape[0] + 46, low_crop.shape[1] + 16:] = label(high_crop, "4MP 1:1")
    write_png(OUT / f"{sample_id}_detail_pair.png", pair)

    high_gray = cv2.cvtColor(high_crop, cv2.COLOR_BGR2GRAY)
    low_matched = cv2.resize(
        cv2.cvtColor(low_crop, cv2.COLOR_BGR2GRAY), (win_w, win_h), interpolation=cv2.INTER_CUBIC
    )

    def run_info(tag: str, run: dict) -> dict:
        return {
            "file": run["file"],
            "width": run["outputWidth"],
            "height": run["outputHeight"],
            "fileBytes": run["fileBytes"],
            "totalMs": run["timings"]["总计"],
            "timings": run["timings"],
            "manual": bool(run.get("manual")),
            "tag": tag,
        }

    return {
        "id": sample_id,
        "source": SOURCES[sample_id],
        "sourceSize": [source_w, source_h],
        "detect": {
            "stage": detect["detect"]["stage"],
            "score": round(float(detect["detect"]["score"]), 4),
            "meanProb": round(float(detect["detect"]["meanProb"]), 4),
            "coverage": round(float(detect["detect"]["coverage"]), 4),
            "frameFill": round(float(detect["detect"]["frameFill"]), 4),
            "autoAccepted": bool(detect["detect"]["autoAccepted"]),
            "threshold": detect["detect"]["threshold"],
            "segmentationMs": detect["detect"]["segmentationMs"],
            "detectionMs": detect["detect"]["detectionMs"],
            "quad": [[round(c, 4) for c in p] for p in quad],
            "pageIoU": None if page_iou is None else round(page_iou, 4),
            "inkInsideFrame": ink_in,
            "inkTotal": ink_total,
            "inkKept": round(ink_share, 4),
            "overlay": f"{sample_id}_detection.jpg",
            "cropFix": crop_fix,
        },
        "runs": {
            f"{budget // 1_000_000}mp": run_info(
                "manual" if (budget in manual) else "auto", chosen[budget]
            )
            for budget in BUDGETS
        },
        "autoRuns": {
            f"{budget // 1_000_000}mp": run_info("auto", run) for budget, run in auto.items()
        },
        "detail": {
            "box4mp": [x, y, win_w, win_h],
            "2mp": stroke_stats(low_matched),
            "4mp": stroke_stats(high_gray),
        },
    }


def stroke_metrics(ink: np.ndarray) -> dict:
    """Shape descriptors used to describe binarisation artefacts.

    Broken hairlines show up as many tiny components, thickened/merged glyphs
    as few very large ones, and rule lines as long horizontal runs.
    """
    binary = (ink > 0).astype(np.uint8)
    count, _, stats, _ = cv2.connectedComponentsWithStats(binary, connectivity=8)
    areas = stats[1:, cv2.CC_STAT_AREA] if count > 1 else np.array([0])
    thickness = cv2.distanceTransform(binary, cv2.DIST_L2, 5) * binary
    ink_px = thickness[thickness > 0]
    runs = []
    for row in binary[::4]:
        padded = np.concatenate(([0], row, [0]))
        edges = np.flatnonzero(np.diff(padded))
        runs.extend((edges[1::2] - edges[0::2]).tolist())
    runs = np.array(runs) if runs else np.array([0])
    return {
        "inkFrac": round(float(binary.mean()), 4),
        "components": int(count - 1),
        "componentsPerMpx": int(round((count - 1) / (binary.size / 1e6))),
        "tinyShare": round(float((areas < 20).mean()), 4),
        "largeShare": round(float((areas > 2000).mean()), 4),
        "medianArea": int(np.median(areas)),
        "strokePx": round(float(ink_px.mean() * 2) if ink_px.size else 0.0, 2),
        "runMeanPx": round(float(runs.mean()), 1),
        "runP95Px": int(np.percentile(runs, 95)),
        "runMaxPx": int(runs.max()),
    }


def bw_report(metrics: dict) -> dict | None:
    """Compares the Sauvola bitonal output with grayscale binarised at the same
    pixel scale, on the same physical region, and writes the review images."""
    runs = [r for r in metrics["runs"] if r["id"].startswith("bw") and "budget" in r]
    if not runs:
        return None
    run = runs[0]
    bw = cv2.imread(str(RAW / run["file"]), cv2.IMREAD_GRAYSCALE)
    gray_run = next(
        r for r in metrics["runs"]
        if r["id"] == "hw1" and r.get("budget") == 4_000_000 and not r.get("manual")
    )
    gray = cv2.imread(str(RAW / gray_run["file"]), cv2.IMREAD_GRAYSCALE)

    write_jpg(OUT / "bw1_full.jpg", fit_height(cv2.cvtColor(bw, cv2.COLOR_GRAY2BGR), 1500), 88)

    scale = bw.shape[1] / gray.shape[1]
    win_w, win_h = int(round(760 * scale)), int(round(520 * scale))
    win_w, win_h = min(win_w, bw.shape[1]), min(win_h, bw.shape[0])
    x, y = detail_window(cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR), (760, 520))
    bx, by = int(round(x * scale)), int(round(y * scale))
    bx = min(bx, bw.shape[1] - win_w)
    by = min(by, bw.shape[0] - win_h)
    bw_crop = bw[by:by + win_h, bx:bx + win_w]
    gray_crop = cv2.resize(
        gray[int(round(y)):int(round(y)) + 520, int(round(x)):int(round(x)) + 760],
        (win_w, win_h),
        interpolation=cv2.INTER_CUBIC,
    )
    ink_bw = (bw_crop < 128).astype(np.uint8)
    ink_gray = (gray_crop < 128).astype(np.uint8)
    write_png(
        OUT / "bw1_detail_1to1.png",
        label(cv2.cvtColor(bw_crop, cv2.COLOR_GRAY2BGR), "黑白 (Sauvola) 1:1"),
    )
    pair = np.hstack([
        label(cv2.cvtColor(gray_crop, cv2.COLOR_GRAY2BGR), "灰度→同尺寸 1:1"),
        np.full((gray_crop.shape[0] + 46, 16, 3), 12, np.uint8),
        label(cv2.cvtColor(bw_crop, cv2.COLOR_GRAY2BGR), "黑白 Sauvola 1:1"),
    ])
    write_png(OUT / "bw1_detail_compare.png", pair)

    return {
        "file": run["file"],
        "width": run["outputWidth"],
        "height": run["outputHeight"],
        "fileBytes": run["fileBytes"],
        "totalMs": run["timings"]["总计"],
        "timings": run["timings"],
        "grayscaleRef": gray_run["file"],
        "grayscaleSize": [gray.shape[1], gray.shape[0]],
        "bw": stroke_metrics(ink_bw),
        "grayscale": stroke_metrics(ink_gray),
        "box": [bx, by, win_w, win_h],
    }


def render_review(reports: list[dict], metrics: dict, bw: dict | None) -> None:
    rows = []
    for report in reports:
        d = report["detect"]
        status = "自动接受" if d["autoAccepted"] else "自动拒绝 → 手动四角"
        rows.append(
            "        <tr>"
            f"<td>{report['id']}<br><small>{report['source']}</small></td>"
            f"<td>{d['stage']}</td>"
            f"<td>{d['score']:.3f}</td>"
            f"<td>{d['meanProb']:.3f} / {d['coverage']:.3f} / {d['frameFill']:.3f}</td>"
            f"<td>{d['inkKept'] * 100:.1f}%</td>"
            f"<td>{status}</td>"
            "</tr>"
        )
    figures = []
    for report in reports:
        sid = report["id"]
        run2, run4 = report["runs"]["2mp"], report["runs"]["4mp"]
        note = "自动四角" if report["detect"]["autoAccepted"] else "手动四角（自动结果被拒绝）"
        figures.append(
            f"""      <figure>
        <img src="{sid}_detection.jpg" alt="{sid} 检测四角">
        <figcaption><b>{sid} · {report['source']} 检测四角</b><br>
        入口 {report['detect']['stage']} · 置信度 {report['detect']['score']:.3f}
        （纸面 {report['detect']['meanProb']:.3f} / 覆盖 {report['detect']['coverage']:.3f} /
        取景 {report['detect']['frameFill']:.3f}）· {note}</figcaption>
      </figure>"""
        )
        if report["detect"]["cropFix"]:
            figures.append(
                f"""      <figure class="wide">
        <img src="{report['detect']['cropFix']}" alt="{sid} 裁切修正">
        <figcaption><b>{sid} · 自动框 vs. 手动四角</b><br>
        自动框只保留了源图 {report['detect']['inkKept'] * 100:.1f}% 的笔迹，手动四角后整页保留</figcaption>
      </figure>"""
            )
        figures.append(
            f"""      <figure class="wide">
        <img src="{sid}_compare.jpg" alt="{sid} 2MP vs 4MP">
        <figcaption><b>{sid} · 2 MP vs 4 MP 灰度</b><br>
        2 MP {run2['width']}×{run2['height']} · {run2['fileBytes'] // 1024} KB ·
        {run2['totalMs']} ms ｜ 4 MP {run4['width']}×{run4['height']} ·
        {run4['fileBytes'] // 1024} KB · {run4['totalMs']} ms</figcaption>
      </figure>"""
        )
        figures.append(
            f"""      <figure class="wide">
        <img src="{sid}_detail_pair.png" alt="{sid} 1:1 细节">
        <figcaption><b>{sid} · 小字/上下标区域 1:1 裁切</b><br>
        同一物理区域，左 2 MP、右 4 MP，均为原始像素（未缩放）</figcaption>
      </figure>"""
        )

    if bw:
        figures.append(
            f"""      <figure class="wide">
        <img src="bw1_detail_compare.png" alt="黑白 vs 灰度 1:1">
        <figcaption><b>黑白（Sauvola）对照 · 同一区域 1:1</b><br>
        左：灰度增强后二值化基线；右：引擎 Sauvola 输出。连通域/笔画厚度等指标见
        docs/quality/quality_metrics.json → bw</figcaption>
      </figure>"""
        )

    html = f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>FairScan Sprint 1 · 扫描画质与裁切证据</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{ margin: 0; font-family: system-ui, "Segoe UI", sans-serif; background: #101214; color: #e8e8e8; }}
  header {{ padding: 16px 20px 4px; }}
  h1 {{ font-size: 18px; margin: 0 0 6px; font-weight: 600; }}
  p.note {{ font-size: 12px; color: #9aa4ad; margin: 0 0 12px; line-height: 1.6; }}
  table {{ border-collapse: collapse; font-size: 12px; margin: 0 20px 8px; }}
  th, td {{ border: 1px solid #2a3138; padding: 6px 10px; text-align: left; }}
  th {{ background: #171c21; font-weight: 600; }}
  small {{ color: #8c969f; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 14px; padding: 16px 20px 28px; }}
  figure {{ margin: 0; background: #191d21; border: 1px solid #262c31; border-radius: 10px; padding: 10px; }}
  figure.wide {{ grid-column: 1 / -1; }}
  img {{ width: 100%; height: auto; display: block; border-radius: 6px; background: #000; }}
  figcaption {{ font-size: 12px; color: #a9b3bc; padding-top: 8px; line-height: 1.5; }}
  figcaption b {{ color: #e8e8e8; font-weight: 600; }}
</style>
</head>
<body>
<header>
  <h1>FairScan 引擎 · Sprint 1 扫描画质与裁切证据</h1>
  <p class="note">
    设备：Android 模拟器 x86_64 / API 36（实体手机未测）· 输入：test_assets/real_samples
    1/2/3.jpg（原 51/49/47）3072×4096 · 灰度模式 · 引擎输出由 App 内 headless 批处理写盘后拉回。
  </p>
  <table>
    <tr><th>样本</th><th>检测入口</th><th>置信度</th><th>纸面 / 覆盖 / 取景</th><th>框内笔迹占比</th><th>处理</th></tr>
{chr(10).join(rows)}
  </table>
</header>
<div class="grid">
{chr(10).join(figures)}
</div>
</body>
</html>
"""
    (OUT / "review.html").write_text(html, encoding="utf-8")
    print(f"wrote {OUT / 'review.html'} ({len(reports)} samples, {len(metrics['runs'])} runs)")


def main() -> None:
    metrics = json.loads((RAW / "metrics.json").read_text(encoding="utf-8"))
    OUT.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(RAW / "metrics.json", OUT / "metrics.json")
    reports = [sample_report(sample_id, metrics) for sample_id in SOURCES]
    bw = bw_report(metrics)
    (OUT / "quality_metrics.json").write_text(
        json.dumps({"samples": reports, "bw": bw}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    render_review(reports, metrics, bw)
    for report in reports:
        d = report["detect"]
        print(f"{report['id']}: {d['stage']} score={d['score']:.3f} "
              f"paper={d['meanProb']:.3f} cov={d['coverage']:.3f} "
              f"fill={d['frameFill']:.3f} inkKept={d['inkKept'] * 100:.1f}% "
              f"accepted={d['autoAccepted']}")
        for tag, run in report["runs"].items():
            print(f"   {tag} {run['tag']}: {run['width']}x{run['height']} "
                  f"{run['fileBytes'] // 1024}KB {run['totalMs']}ms")
        print(f"   faint px 2mp={report['detail']['2mp']['faintPixels']} "
              f"4mp={report['detail']['4mp']['faintPixels']}  "
              f"ink px 2mp={report['detail']['2mp']['inkPixels']} "
              f"4mp={report['detail']['4mp']['inkPixels']}")
    if bw:
        print(f"bw1: {bw['width']}x{bw['height']} {bw['fileBytes'] // 1024}KB "
              f"{bw['totalMs']}ms")
        for name in ("grayscale", "bw"):
            m = bw[name]
            print(f"   {name:9s} ink={m['inkFrac']:.3f} cc={m['componentsPerMpx']}/Mpx "
                  f"tiny={m['tinyShare']:.2f} large={m['largeShare']:.2f} "
                  f"stroke={m['strokePx']:.2f}px run95={m['runP95Px']}px")


if __name__ == "__main__":
    main()
