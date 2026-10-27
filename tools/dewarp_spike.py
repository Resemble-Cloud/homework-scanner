#!/usr/bin/env python3
"""书页弯曲展平 Spike（v1.1 Phase 3，只出原型与报告，不改生产代码）。

做法：用 `test_assets/fixtures/page.jpg` 合成「桌面 + 单页作业」的平面图，
按已知圆柱模型正向 warp 出弯曲照片（保留已知 displacement），再用两种方法
尝试还原平面，与 ground truth 逐像素对比。

方法 A：文本行拟合（灰度 + 自适应阈值 + 水平形态学连接 → 每条文本行的基线
        偏移 → 平滑曲线 → 逐列垂直 remap）。只修垂直方向，不修水平压缩。
方法 B：页面边缘 / 圆柱模型（分割纸面 → 取上下边界曲线 → 网格搜索半径与焦比
        → 解析反解整幅位移场）。垂直 + 水平一起修。

两种方法的输出统一落在「平面画布网格」上，指标口径一致：
  PSNR / SSIM：与 ground truth 平面图比（纸页内部区域）；
  文本行直线度：该图自身检测到的行带基线在 x 方向的 std（px）；
  位移误差：输出像素取到的源点与 ground truth 源点在弯曲照片坐标下的距离。

用法：
    python tools/dewarp_spike.py

输出：
    docs/quality/dewarp/level{1,2,3}_*_before_after.jpg
    docs/quality/dewarp/failure_*.jpg
    docs/quality/dewarp/metrics.csv

只依赖 Python + OpenCV + NumPy；不接入 App，不改 Kotlin/Flutter。
"""

from __future__ import annotations

import csv
import math
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

REPO = Path(__file__).resolve().parent.parent
FIXTURE = REPO / "test_assets" / "fixtures" / "page.jpg"
OUT_DIR = REPO / "docs" / "quality" / "dewarp"
CSV_PATH = OUT_DIR / "metrics.csv"

CANVAS_W, CANVAS_H = 900, 1200
PAGE_W, PAGE_H = 700, 950
PAGE_X, PAGE_Y = 110, 130
INSET = 0.06  # 指标区域：纸页内缩比例，避开边缘重采样

TRUE_FOCAL = 1600.0
TRUE_CX, TRUE_CY = CANVAS_W / 2.0, CANVAS_H / 2.0
LEVELS = {"level1_mild": 900.0, "level2_medium": 600.0, "level3_strong": 380.0}


# --------------------------------------------------------------------------- #
# 圆柱弯曲模型
# --------------------------------------------------------------------------- #
@dataclass
class Cylinder:
    """水平方向绕竖直轴弯曲。平面 (x, y) → 弯曲照片：

    theta = (x - cx) / R
    x'    = cx + R * sin(theta)                     # 正交投影，边缘水平压缩
    s     = focal / (focal + R * (1 - cos(theta)))  # 越远缩得越小
    y'    = cy + (y - cy) * s
    """

    R: float
    focal: float
    cx: float
    cy: float

    def _theta(self, dx: np.ndarray) -> np.ndarray:
        return np.arcsin(np.clip(dx / self.R, -0.985, 0.985))

    def _scale(self, th: np.ndarray) -> np.ndarray:
        return self.focal / (self.focal + self.R * (1.0 - np.cos(th)))

    def forward(self, x: np.ndarray, y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """平面 → 弯曲照片。"""
        th = self._theta(x - self.cx)
        return self.cx + self.R * np.sin(th), self.cy + (y - self.cy) * self._scale(th)

    def inverse(self, bx: np.ndarray, by: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """弯曲照片 → 平面。"""
        th = self._theta(bx - self.cx)
        return self.cx + self.R * th, self.cy + (by - self.cy) / self._scale(th)

    def bend(self, img: np.ndarray) -> np.ndarray:
        """平面图 → 弯曲照片（每个输出像素取平面的对应点）。"""
        h, w = img.shape[:2]
        gx, gy = np.meshgrid(np.arange(w, dtype=np.float64), np.arange(h, dtype=np.float64))
        sx, sy = self.inverse(gx, gy)
        return sample(img, sx, sy)


def sample(img: np.ndarray, mx: np.ndarray, my: np.ndarray) -> np.ndarray:
    return cv2.remap(
        img,
        mx.astype(np.float32),
        my.astype(np.float32),
        cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_REPLICATE,
    )


def smooth_1d(x: np.ndarray, k: int) -> np.ndarray:
    """滑动中值（OpenCV 5 的 medianBlur 只吃 CV_8U，边界曲线是浮点像素数）。"""
    k = max(3, int(k) | 1)
    if x.size <= k:
        return x.copy()
    pad = k // 2
    xp = np.pad(x.astype(np.float64), pad, mode="edge")
    return np.median(np.lib.stride_tricks.sliding_window_view(xp, k), axis=-1)


def canvas_grid() -> tuple[np.ndarray, np.ndarray]:
    return np.meshgrid(
        np.arange(CANVAS_W, dtype=np.float64), np.arange(CANVAS_H, dtype=np.float64)
    )


# --------------------------------------------------------------------------- #
# 合成样本
# --------------------------------------------------------------------------- #
def paper_page(w: int = PAGE_W, h: int = PAGE_H) -> np.ndarray:
    """夹具图 `page.jpg` 是「空表格」：黑色边框 + 顶部两条横线。

    只取中间的空白纸面当纸纹理，避免夹具自带的长横线被当成文本行。
    """
    raw = cv2.imread(str(FIXTURE))
    if raw is None:
        raise SystemExit(f"读不到夹具图：{FIXTURE}")
    fh, fw = raw.shape[:2]
    raw = raw[int(0.30 * fh) : int(0.92 * fh), int(0.10 * fw) : int(0.90 * fw)]
    page = cv2.resize(raw, (w, h), interpolation=cv2.INTER_AREA)
    rng = np.random.default_rng(5)
    noise = rng.normal(0.0, 1.4, page.shape).astype(np.float32)
    return np.clip(page.astype(np.float32) + noise, 0, 255).astype(np.uint8)


def draw_text_content(page: np.ndarray, rng: np.random.Generator) -> tuple[np.ndarray, list[int]]:
    """11 行「正文」，每行由基线速写 + 一列竖笔画组成（模拟字母），

    竖笔画很重要：只有横线条的页面在 PSNR 上对水平错位不敏感，会低估水平压缩的伤害。
    返回 (图, 每行真实基线 y)。
    """
    h, w = page.shape[:2]
    out = page.copy()
    margin_x = int(0.10 * w)
    baselines = np.linspace(int(0.15 * h), int(0.90 * h), 11).round().astype(int)
    for y in baselines:
        x = margin_x
        while x < w - margin_x - 70:
            word = int(rng.integers(45, 105))
            shade = int(rng.integers(28, 68))
            pts = np.array(
                [
                    [int(x + word * k / 6.0), int(y + rng.integers(-1, 2))]
                    for k in range(7)
                ]
            )
            cv2.polylines(out, [pts], False, (shade, shade, shade), 2, cv2.LINE_AA)
            # 竖笔画：字身高度 10-18px，水平方向每 6-10px 一根
            cx = x + 3
            while cx < x + word - 3:
                top = y - int(rng.integers(10, 19))
                cv2.line(out, (int(cx), int(top)), (int(cx), int(y)), (shade, shade, shade), 2, cv2.LINE_AA)
                cx += int(rng.integers(6, 11))
            x += word + int(rng.integers(12, 34))
    return out, [int(v) for v in baselines]


def draw_figure_content(page: np.ndarray) -> np.ndarray:
    """没有长文本行的页面：圆、三角、斜线填充、几段短标注。"""
    h, w = page.shape[:2]
    out = page.copy()
    ink = (45, 45, 45)
    cv2.circle(out, (int(0.30 * w), int(0.28 * h)), 90, ink, 3, cv2.LINE_AA)
    cv2.polylines(
        out,
        [
            np.array(
                [
                    [int(0.62 * w), int(0.42 * h)],
                    [int(0.86 * w), int(0.42 * h)],
                    [int(0.74 * w), int(0.16 * h)],
                ]
            )
        ],
        True,
        ink,
        3,
        cv2.LINE_AA,
    )
    for i in range(14):
        x0 = int(0.14 * w) + i * 14
        cv2.line(out, (x0, int(0.62 * h)), (x0 + 26, int(0.74 * h)), ink, 2, cv2.LINE_AA)
    for i in range(3):
        y = int(0.84 * h) + i * 34
        cv2.line(out, (int(0.20 * w), y), (int(0.36 * w), y), ink, 3, cv2.LINE_AA)
    return out


def synthesize_desk(
    page: np.ndarray,
    offset: tuple[int, int] = (PAGE_X, PAGE_Y),
    desk: tuple[float, float] = (58.0, 84.0),
    noise_sigma: float = 2.5,
    seed: int = 3,
) -> np.ndarray:
    """把纸页贴到桌面上。offset 可以为负，让纸页铺满画幅（看不到纸边）。"""
    rng = np.random.default_rng(seed)
    lo, hi = desk
    base = np.linspace(lo, hi, CANVAS_H, dtype=np.float32)[:, None]
    base = np.repeat(base, CANVAS_W, axis=1)
    tint = np.linspace(0, 12, CANVAS_W, dtype=np.float32)[None, :]
    canvas = np.zeros((CANVAS_H, CANVAS_W, 3), np.uint8)
    for c, gain in enumerate((0.92, 0.97, 1.06)):
        canvas[:, :, c] = np.clip(base * gain + tint, 0, 255).astype(np.uint8)
    canvas = np.clip(
        canvas.astype(np.float32) + rng.normal(0.0, noise_sigma, canvas.shape), 0, 255
    ).astype(np.uint8)
    ox, oy = offset
    ph, pw = page.shape[:2]
    sx0, sy0 = max(0, -ox), max(0, -oy)
    dx0, dy0 = max(0, ox), max(0, oy)
    cw = min(pw - sx0, CANVAS_W - dx0)
    ch = min(ph - sy0, CANVAS_H - dy0)
    if cw > 0 and ch > 0:
        canvas[dy0 : dy0 + ch, dx0 : dx0 + cw] = page[sy0 : sy0 + ch, sx0 : sx0 + cw]
    return canvas


def interior_mask() -> np.ndarray:
    mask = np.zeros((CANVAS_H, CANVAS_W), np.uint8)
    mask[
        int(PAGE_Y + INSET * PAGE_H) : int(PAGE_Y + (1 - INSET) * PAGE_H),
        int(PAGE_X + INSET * PAGE_W) : int(PAGE_X + (1 - INSET) * PAGE_W),
    ] = 1
    return mask


# --------------------------------------------------------------------------- #
# 方法 A：文本行拟合
# --------------------------------------------------------------------------- #
def page_region_mask(img: np.ndarray) -> np.ndarray:
    """亮纸面 vs 暗桌面（Otsu + 最大连通域）。"""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    blur = cv2.GaussianBlur(gray, (0, 0), 3)
    _, m = cv2.threshold(blur, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((11, 11), np.uint8))
    n, labels, stats, _ = cv2.connectedComponentsWithStats(m, 8)
    if n <= 1:
        return np.zeros_like(gray)
    biggest = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    return (labels == biggest).astype(np.uint8) * 255


def ink_mask(img: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    ink = cv2.adaptiveThreshold(
        gray, 255, cv2.ADAPTIVE_THRESH_MEAN_C, cv2.THRESH_BINARY_INV, 31, 12
    )
    return np.where(page_region_mask(img) > 0, ink, 0).astype(np.uint8)


def detect_text_bands(ink: np.ndarray, w: int, h: int) -> list[tuple[int, int]]:
    """水平形态学连接 + 连通域。要求够宽、够扁，避免把插图短线当文本行。"""
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (max(21, w // 18), 3))
    closed = cv2.morphologyEx(ink, cv2.MORPH_CLOSE, kernel)
    n, _, stats, _ = cv2.connectedComponentsWithStats(closed, 8)
    bands = []
    for i in range(1, n):
        _, y, bw, bh, area = stats[i]
        if bw < 0.35 * w or bh > 0.06 * h or area < 0.002 * w * h:
            continue
        bands.append((int(y), int(y + bh)))
    bands.sort()
    return bands


def baseline_curves(
    ink: np.ndarray, bands: list[tuple[int, int]], x0: int, x1: int
) -> list[tuple[np.ndarray, np.ndarray]]:
    """每条行带在每个列上的基线（该列最下方的墨迹行）。"""
    out = []
    for by0, by1 in bands:
        lo, hi = max(0, by0 - 6), min(ink.shape[0], by1 + 6)
        strip = ink[lo:hi, x0:x1] > 0
        ys = np.full(x1 - x0, np.nan)
        for c in range(x1 - x0):
            rows = np.where(strip[:, c])[0]
            if rows.size >= 2:
                ys[c] = lo + int(rows.max())
        valid = ~np.isnan(ys)
        if valid.sum() >= max(8, (x1 - x0) // 8):
            idx = np.where(valid)[0]
            ys = np.interp(np.arange(x1 - x0), idx, ys[idx])
            ys = smooth_1d(ys, (x1 - x0) // 40)
        out.append((np.arange(x0, x1), ys, valid))
    return out


@dataclass
class MethodResult:
    img: np.ndarray
    maps: tuple[np.ndarray, np.ndarray]  # 平面画布网格 → 弯曲照片的采样坐标
    ms: float
    note: str


def method_a_textlines(img: np.ndarray) -> MethodResult:
    """文本行垂直拉直：只修垂直弓形，不修水平压缩。"""
    t0 = time.perf_counter()
    h, w = img.shape[:2]
    gx, gy = canvas_grid()
    if gx.shape != (h, w):
        gx, gy = np.meshgrid(np.arange(w, dtype=np.float64), np.arange(h, dtype=np.float64))

    ink = ink_mask(img)
    bands = detect_text_bands(ink, w, h)
    shift = np.zeros((h, w), np.float32)
    fallback = (gx, gy)
    if not bands:
        return MethodResult(img.copy(), fallback, (time.perf_counter() - t0) * 1000.0,
                            "未检测到文本行 → 原样返回")

    mask = page_region_mask(img)
    cols = np.where(mask.any(axis=0))[0]
    x0, x1 = int(cols[0]), int(cols[-1]) + 1
    curves = baseline_curves(ink > 0, bands, x0, x1)

    # 参考列 = 纸面水平中心（该处弯曲模型是恒等），各行的目标行就取它的值
    mid = 0.5 * (x0 + x1)
    half_win = max(4, int(0.04 * (x1 - x0)))
    m0, m1 = int(max(x0, mid - half_win)), int(min(x1, mid + half_win))

    rows_obs: list[float] = []
    cols_v: list[np.ndarray] = []
    for (by0, by1), (_, ys, _) in zip(bands, curves):
        if np.isnan(ys).all():
            continue
        ref = float(np.nanmedian(ys[m0 - x0 : m1 - x0]))
        rows_obs.append(ref)
        cols_v.append(ys - ref)
    if len(rows_obs) < 3:
        return MethodResult(img.copy(), fallback, (time.perf_counter() - t0) * 1000.0,
                            f"{len(bands)} 条行带，可用基线不足 → 原样返回")

    Y = np.array(rows_obs, dtype=np.float64)
    V = np.array(cols_v, dtype=np.float64)  # (n_lines, n_cols)
    # 位移场应当近似是 y 的线性函数：shift(x, y) = a(x) + b(x) * y。
    # 对每一列用全部行节点做一次最小二乘，比在相邻行之间做分段线性更稳，
    # 也不会把行距改形。
    n_lines = len(Y)
    y_mean = Y.mean()
    dy2 = float(((Y - y_mean) ** 2).sum())
    a = np.zeros(V.shape[1], dtype=np.float64)
    b = np.zeros(V.shape[1], dtype=np.float64)
    v_mean = V.mean(axis=0)
    b = ((Y[:, None] - y_mean) * (V - v_mean)).sum(axis=0) / max(dy2, 1e-9)
    a = v_mean - b * y_mean
    step = max(5, (x1 - x0) // 40)
    a = smooth_1d(a, step)
    b = smooth_1d(b, step)
    shift[:, x0:x1] = (a[None, :] + b[None, :] * (np.arange(h, dtype=np.float64)[:, None])).astype(np.float32)

    maps = (gx, gy + shift)
    out = sample(img, maps[0], maps[1])
    ms = (time.perf_counter() - t0) * 1000.0
    return MethodResult(out, maps, ms, f"{len(bands)} 条行带，垂直拉直，{ms:.0f} ms")


# --------------------------------------------------------------------------- #
# 方法 B：页面边界 / 圆柱模型
# --------------------------------------------------------------------------- #
def page_boundaries(img: np.ndarray) -> tuple[np.ndarray, np.ndarray, int, int] | None:
    mask = page_region_mask(img) > 0
    cols = np.where(mask.any(axis=0))[0]
    if cols.size < 40:
        return None
    x0, x1 = int(cols[0]), int(cols[-1])
    top = np.full(x1 - x0, np.nan)
    bot = np.full(x1 - x0, np.nan)
    for i, x in enumerate(range(x0, x1)):
        rows = np.where(mask[:, x])[0]
        if rows.size:
            top[i], bot[i] = rows[0], rows[-1]
    valid = ~np.isnan(top)
    if valid.sum() < 40:
        return None
    idx = np.where(valid)[0]
    top = np.interp(np.arange(x1 - x0), idx, top[idx])
    bot = np.interp(np.arange(x1 - x0), idx, bot[idx])
    k = (x1 - x0) // 30
    top = smooth_1d(top, k)
    bot = smooth_1d(bot, k)
    return top, bot, x0, x1


def estimate_cylinder(img: np.ndarray) -> tuple[Cylinder | None, float, str]:
    """只靠纸面上下边界曲线搜索圆柱参数（半径、焦比、投影中心 y）。"""
    bounds = page_boundaries(img)
    if bounds is None:
        return None, float("nan"), "找不到纸面边界"
    top, bot, x0, x1 = bounds
    xs = np.arange(x0, x1, dtype=np.float64)
    cx = 0.5 * (x0 + x1 - 1)
    centre = int(np.argmin(np.abs(xs - cx)))
    top_c, bot_c = float(top[centre]), float(bot[centre])
    span = bot_c - top_c
    if span < 50:
        return None, float("nan"), "纸面高度异常"
    cy_grid = np.linspace(top_c - 0.6 * span, bot_c + 0.6 * span, 25)
    best: tuple[float, tuple[float, float, float] | None] = (float("inf"), None)
    for R in np.linspace(220.0, 6000.0, 45):
        th = np.arcsin(np.clip((xs - cx) / R, -0.985, 0.985))
        depth = R * (1.0 - np.cos(th))
        for focal in (700.0, 900.0, 1200.0, 1600.0, 2100.0, 2800.0, 3800.0):
            s = focal / (focal + depth)
            for cy in cy_grid:
                res = (top - (cy + (top_c - cy) * s)) ** 2 + (
                    bot - (cy + (bot_c - cy) * s)
                ) ** 2
                rms = float(np.sqrt(np.mean(res)))
                if rms < best[0]:
                    best = (rms, (R, focal, float(cy)))
    if best[1] is None:
        return None, float("nan"), "参数搜索失败"
    R, focal, cy = best[1]
    return Cylinder(R, focal, cx, cy), best[0], (
        f"R={R:.0f}px focal={focal:.0f} cy={cy:.0f}，边界残差 {best[0]:.2f}px"
    )


def method_b_cylinder(img: np.ndarray) -> MethodResult:
    """边缘/圆柱模型：解析反解整幅位移场，垂直 + 水平一起修。"""
    t0 = time.perf_counter()
    h, w = img.shape[:2]
    gx, gy = np.meshgrid(np.arange(w, dtype=np.float64), np.arange(h, dtype=np.float64))
    est, _, note = estimate_cylinder(img)
    if est is None:
        return MethodResult(img.copy(), (gx, gy), (time.perf_counter() - t0) * 1000.0, note)
    maps = est.forward(gx, gy)
    out = sample(img, maps[0], maps[1])
    ms = (time.perf_counter() - t0) * 1000.0
    return MethodResult(out, maps, ms, f"{note}，{ms:.0f} ms")


# --------------------------------------------------------------------------- #
# 指标
# --------------------------------------------------------------------------- #
def gray(img: np.ndarray) -> np.ndarray:
    return cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32)


def psnr(a: np.ndarray, b: np.ndarray, region: np.ndarray) -> float:
    d = (a - b)[region > 0]
    if d.size == 0:
        return float("nan")
    mse = float(np.mean(d**2))
    return 99.0 if mse <= 1e-9 else 10.0 * math.log10(255.0**2 / mse)


def ssim(a: np.ndarray, b: np.ndarray, region: np.ndarray) -> float:
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    k, sigma = (11, 11), 1.5
    mu_a, mu_b = cv2.GaussianBlur(a, k, sigma), cv2.GaussianBlur(b, k, sigma)
    saa = cv2.GaussianBlur(a * a, k, sigma) - mu_a * mu_a
    sbb = cv2.GaussianBlur(b * b, k, sigma) - mu_b * mu_b
    sab = cv2.GaussianBlur(a * b, k, sigma) - mu_a * mu_b
    s = ((2 * mu_a * mu_b + c1) * (2 * sab + c2)) / (
        (mu_a**2 + mu_b**2 + c1) * (saa + sbb + c2)
    )
    return float(s[region > 0].mean())


def straightness(img: np.ndarray) -> tuple[float, int]:
    """文本行直线度：检测到的每条行带基线在 x 方向的 std（px），越小越直。"""
    h, w = img.shape[:2]
    ink = ink_mask(img)
    bands = detect_text_bands(ink, w, h)
    if not bands:
        return float("nan"), 0
    mask = page_region_mask(img)
    cols = np.where(mask.any(axis=0))[0]
    if cols.size < 40:
        return float("nan"), len(bands)
    x0, x1 = int(cols[0]), int(cols[-1]) + 1
    curves = baseline_curves(ink > 0, bands, x0, x1)
    # 先把基线曲线做一次宽平滑：逐列的「最下方墨迹行」会被笔画末端抖动污染，
    # 平滑后剩下的才是弓形本身。
    wide = max(21, (x1 - x0) // 12)
    devs = []
    for _, ys, valid in curves:
        if np.isnan(ys).all() or valid.sum() < 3:
            continue
        # 只统计真正有墨迹的列：两端没有内容的部分是插值出来的常数，会把弓形摊平
        devs.append(float(np.std(smooth_1d(ys, wide)[valid])))
    return (float(np.mean(devs)) if devs else float("nan")), len(bands)


def displacement_error(
    maps: tuple[np.ndarray, np.ndarray],
    truth_map: tuple[np.ndarray, np.ndarray],
    region: np.ndarray,
) -> tuple[float, float]:
    err = np.sqrt((maps[0] - truth_map[0]) ** 2 + (maps[1] - truth_map[1]) ** 2)
    sel = region > 0
    if sel.sum() == 0:
        return float("nan"), float("nan")
    e = err[sel]
    return float(np.median(e)), float(np.percentile(e, 95))


def label(img: np.ndarray, text: str, scale: float = 0.5) -> np.ndarray:
    out = img.copy()
    cv2.rectangle(out, (0, 0), (out.shape[1], 26), (18, 18, 18), -1)
    cv2.putText(out, text, (8, 18), cv2.FONT_HERSHEY_SIMPLEX, scale, (255, 255, 255), 1, cv2.LINE_AA)
    return out


def contact_row(
    images: list[np.ndarray], labels: list[str], tile_w: int, tile_h: int
) -> np.ndarray:
    gap = 10
    row = np.full((tile_h + gap * 2, len(images) * (tile_w + gap) + gap, 3), 235, np.uint8)
    for i, (img, text) in enumerate(zip(images, labels)):
        resized = cv2.resize(img, (tile_w, tile_h), interpolation=cv2.INTER_AREA)
        y, x = gap, gap + i * (tile_w + gap)
        row[y : y + tile_h, x : x + tile_w] = label(resized, text)
    return row


# --------------------------------------------------------------------------- #
# 单个样本
# --------------------------------------------------------------------------- #
def run_case(
    name: str,
    flat: np.ndarray,
    truth: Cylinder,
    region: np.ndarray,
) -> dict[str, object]:
    bent = truth.bend(flat)
    a = method_a_textlines(bent)
    b = method_b_cylinder(bent)

    gt_gray = gray(flat)
    bent_gray = gray(bent)
    a_gray, b_gray = gray(a.img), gray(b.img)

    # 方法 A 的输出是弯曲网格上的图；它的 maps 已经把平面网格映射到弯曲网格，
    # 所以 a.img 本身就是「平面网格」上的结果，可直接与 ground truth 比。
    straight_bent, bands_bent = straightness(bent)
    straight_a, bands_a = straightness(a.img)
    straight_b, bands_b = straightness(b.img)
    straight_gt, bands_gt = straightness(flat)

    gx, gy = canvas_grid()
    truth_map = truth.forward(gx, gy)
    med_a, p95_a = displacement_error(a.maps, truth_map, region)
    med_b, p95_b = displacement_error(b.maps, truth_map, region)
    # 参照：完全不校正时的位移（= 弯曲本身的位移量），用来衡量两个方法各自消掉了多少
    med_id, p95_id = displacement_error((gx, gy), truth_map, region)

    result = {
        "name": name,
        "flat": flat,
        "bent": bent,
        "a": a.img,
        "b": b.img,
        "psnr_bent": psnr(bent_gray, gt_gray, region),
        "ssim_bent": ssim(bent_gray, gt_gray, region),
        "psnr_a": psnr(a_gray, gt_gray, region),
        "ssim_a": ssim(a_gray, gt_gray, region),
        "psnr_b": psnr(b_gray, gt_gray, region),
        "ssim_b": ssim(b_gray, gt_gray, region),
        "straight_bent": straight_bent,
        "bands_bent": bands_bent,
        "straight_a": straight_a,
        "bands_a": bands_a,
        "straight_b": straight_b,
        "bands_b": bands_b,
        "straight_gt": straight_gt,
        "bands_gt": bands_gt,
        "med_a": med_a,
        "p95_a": p95_a,
        "med_b": med_b,
        "p95_b": p95_b,
        "med_id": med_id,
        "p95_id": p95_id,
        "note_a": a.note,
        "note_b": b.note,
        "ms_a": a.ms,
        "ms_b": b.ms,
    }
    print(
        f"{name:24s} PSNR before {result['psnr_bent']:5.2f} | A {result['psnr_a']:5.2f} "
        f"SSIM {result['ssim_a']:.4f} 直 {result['straight_a']:5.2f}px({bands_a}带) "
        f"| B {result['psnr_b']:5.2f} SSIM {result['ssim_b']:.4f} "
        f"直 {result['straight_b']:5.2f}px({bands_b}带) | GT 直 {straight_gt:5.2f}px"
    )
    print(f"{'':24s} A: {a.note}")
    print(f"{'':24s} B: {b.note}")
    return result


def figure(
    name: str, result: dict[str, object], box: tuple[int, int, int, int]
) -> None:
    names = ["bent photo", "A: text-line (vertical only)", "B: cylinder (full inverse)", "ground truth"]
    full = contact_row(
        [result["bent"], result["a"], result["b"], result["flat"]],
        names,
        tile_w=250,
        tile_h=330,
    )
    x, y, w, h = box
    crops = [
        img[y : y + h, x : x + w]
        for img in (result["bent"], result["a"], result["b"], result["flat"])
    ]
    detail = contact_row(crops, ["zoom", "zoom", "zoom", "zoom"], tile_w=250, tile_h=110)
    sheet = np.vstack([full, detail])
    path = OUT_DIR / f"{name}_before_after.jpg"
    cv2.imwrite(str(path), sheet, [cv2.IMWRITE_JPEG_QUALITY, 90])
    print(f"已写入 {path.relative_to(REPO)}")


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    rng = np.random.default_rng(11)
    text_page, baselines = draw_text_content(paper_page(), rng)
    flat_text = synthesize_desk(text_page)
    region = interior_mask()

    print(f"画布 {CANVAS_W}x{CANVAS_H}，纸页 {PAGE_W}x{PAGE_H}，合成正文 {len(baselines)} 行，真实 focal {TRUE_FOCAL:.0f}")
    print("=" * 130)

    results: list[dict[str, object]] = []
    for name, R in LEVELS.items():
        res = run_case(name, flat_text, Cylinder(R, TRUE_FOCAL, TRUE_CX, TRUE_CY), region)
        results.append(res)
        figure(name, res, box=(PAGE_X + 20, PAGE_Y + 30, 420, 190))

    # 失败 1：纸页铺满画幅，看不到纸边 → 方法 B 失去边界线索
    big_page, _ = draw_text_content(paper_page(1500, 1900), np.random.default_rng(23))
    flat_full = synthesize_desk(big_page, offset=(-300, -350), seed=9)
    res_full = run_case(
        "failure_border_invisible", flat_full, Cylinder(LEVELS["level3_strong"], TRUE_FOCAL, TRUE_CX, TRUE_CY), region
    )
    results.append(res_full)
    figure("failure_border_invisible", res_full, box=(120, 150, 420, 190))

    # 失败 2：桌面接近纸面亮度 → 分割失效
    flat_lowcontrast = synthesize_desk(text_page, desk=(196.0, 224.0), noise_sigma=1.5, seed=17)
    res_low = run_case(
        "failure_low_contrast_desk", flat_lowcontrast, Cylinder(LEVELS["level2_medium"], TRUE_FOCAL, TRUE_CX, TRUE_CY), region
    )
    results.append(res_low)
    figure("failure_low_contrast_desk", res_low, box=(PAGE_X + 20, PAGE_Y + 30, 420, 190))

    # 失败 3：没有长文本行 → 方法 A 无可拟合对象
    flat_fig = synthesize_desk(draw_figure_content(paper_page()), seed=31)
    res_fig = run_case(
        "failure_no_textlines", flat_fig, Cylinder(LEVELS["level2_medium"], TRUE_FOCAL, TRUE_CX, TRUE_CY), region
    )
    results.append(res_fig)
    figure("failure_no_textlines", res_fig, box=(PAGE_X + 20, PAGE_Y + 20, 420, 400))

    with CSV_PATH.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(
            [
                "case", "psnr_bent", "ssim_bent", "straight_bent", "bands_bent",
                "psnr_a", "ssim_a", "straight_a", "bands_a", "med_err_a", "p95_err_a", "ms_a",
                "psnr_b", "ssim_b", "straight_b", "bands_b", "med_err_b", "p95_err_b", "ms_b",
                "med_err_identity", "p95_err_identity",
                "straight_gt", "bands_gt", "note_a", "note_b",
            ]
        )
        for r in results:
            writer.writerow(
                [
                    r["name"],
                    f"{r['psnr_bent']:.2f}", f"{r['ssim_bent']:.4f}",
                    f"{r['straight_bent']:.2f}", f"{r['bands_bent']:.0f}",
                    f"{r['psnr_a']:.2f}", f"{r['ssim_a']:.4f}",
                    f"{r['straight_a']:.2f}", f"{r['bands_a']:.0f}",
                    f"{r['med_a']:.2f}", f"{r['p95_a']:.2f}", f"{r['ms_a']:.0f}",
                    f"{r['psnr_b']:.2f}", f"{r['ssim_b']:.4f}",
                    f"{r['straight_b']:.2f}", f"{r['bands_b']:.0f}",
                    f"{r['med_b']:.2f}", f"{r['p95_b']:.2f}", f"{r['ms_b']:.0f}",
                    f"{r['med_id']:.2f}", f"{r['p95_id']:.2f}",
                    f"{r['straight_gt']:.2f}", f"{r['bands_gt']:.0f}",
                    r["note_a"], r["note_b"],
                ]
            )
    print(f"已写入 {CSV_PATH.relative_to(REPO)}")


if __name__ == "__main__":
    main()
