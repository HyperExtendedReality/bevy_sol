"""Measure patch variation in Cornell captures; requires Pillow and NumPy.

This is a noise/texture diagnostic in final sRGB code values, not a ground-truth
lighting error metric. Real gradients contribute; sampling, denoising and AA all
affect it. Images are read only and are never rewritten.
"""
import json
import sys

import numpy as np
from PIL import Image


def blur(array, sigma):
    radius = int(3 * sigma)
    offsets = np.arange(-radius, radius + 1)
    kernel = np.exp(-offsets * offsets / (2 * sigma * sigma))
    kernel /= kernel.sum()
    padded = np.pad(array, ((radius, radius), (radius, radius)), mode="reflect")
    horizontal = np.apply_along_axis(
        lambda row: np.convolve(row, kernel, mode="valid"), 1, padded
    )
    return np.apply_along_axis(
        lambda column: np.convolve(column, kernel, mode="valid"), 0, horizontal
    )


def measure(path):
    image = np.asarray(Image.open(path), dtype=float)[:, :, :3]
    if image.shape[:2] != (640, 640):
        raise ValueError("Expected the unmodified 640x640 Cornell capture")
    result = {}
    for name, bounds, channel in [
        ("red_wall", (30, 160, 90, 390), 0),
        ("green_wall", (550, 160, 610, 390), 1),
        ("back_wall", (285, 175, 495, 330), None),
    ]:
        x0, y0, x1, y1 = bounds
        patch = image[y0:y1, x0:x1]
        patch = patch[:, :, channel] if channel is not None else patch.mean(axis=2)
        residual = (blur(patch, 1) - blur(patch, 8))[8:-8, 8:-8]
        result[name] = float(np.sqrt(np.mean(residual * residual)))
    return result


if __name__ == "__main__":
    paths = sys.argv[1:] or ["screenshots/cornell-before.png", "screenshots/cornell.png"]
    print(json.dumps({path: measure(path) for path in paths}, indent=2))
