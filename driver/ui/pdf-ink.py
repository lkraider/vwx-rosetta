#!/usr/bin/env python3
"""Render page 1 of each PDF with Quick Look and measure its ink.

Usage:
  pdf-ink.py --out-dir DIR [--size 1200] [--min-frac 0.001] [--min-extent 0.25] PDF...

`qlmanage -t -s SIZE -o DIR PDF` writes DIR/<name>.pdf.png with the longest side at SIZE
pixels. The thumbnail is composited onto white and converted to 8-bit luminance with
PIL `Image.convert("L")`. A pixel with luminance below 200 counts as dark.

Each row of the TSV on stdout gives the dark pixel count, the dark fraction of all
pixels, the dark bounding box, and the extent. The extent is the larger of the bounding
box width over the image width and the bounding box height over the image height.

Verdicts:
- `blank`: 0 dark pixels.
- `small`: dark fraction below --min-frac, or extent below --min-extent.
- `ink`: both thresholds met.
- `error`: Quick Look wrote no thumbnail.

The exit status is 0 when every page reads `ink`, and 1 otherwise. Bad arguments exit 2.
"""
import argparse
import os
import subprocess
import sys

from PIL import Image

DARK = 200


def render(pdf, out_dir, size):
    proc = subprocess.run(["qlmanage", "-t", "-s", str(size), "-o", out_dir, pdf],
                          capture_output=True, text=True, timeout=120)
    png = os.path.join(out_dir, os.path.basename(pdf) + ".png")
    return png if os.path.isfile(png) else None, proc.returncode


def measure(png):
    img = Image.open(png).convert("RGBA")
    white = Image.new("RGBA", img.size, (255, 255, 255, 255))
    lum = Image.alpha_composite(white, img).convert("L")
    width, height = lum.size
    mask = lum.point(lambda v: 255 if v < DARK else 0)
    dark = mask.histogram()[255]
    box = mask.getbbox()
    extent = 0.0
    if box:
        extent = max((box[2] - box[0]) / width, (box[3] - box[1]) / height)
    return width, height, dark, box, extent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True, help="directory for the Quick Look renders")
    ap.add_argument("--size", type=int, default=1200)
    ap.add_argument("--min-frac", type=float, default=0.001)
    ap.add_argument("--min-extent", type=float, default=0.25)
    ap.add_argument("pdfs", nargs="+")
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    print("pdf\tpng\twidth\theight\tdark_px\tdark_frac\tbbox\textent\tverdict")
    failed = 0
    for pdf in args.pdfs:
        png, code = render(os.path.abspath(pdf), args.out_dir, args.size)
        if not png:
            failed += 1
            print("%s\t-\t-\t-\t-\t-\t-\t-\terror qlmanage=%d" % (pdf, code))
            continue
        width, height, dark, box, extent = measure(png)
        frac = dark / float(width * height)
        if dark == 0:
            verdict = "blank"
        elif frac < args.min_frac or extent < args.min_extent:
            verdict = "small"
        else:
            verdict = "ink"
        if verdict != "ink":
            failed += 1
        print("%s\t%s\t%d\t%d\t%d\t%.6f\t%s\t%.3f\t%s" % (
            pdf, png, width, height, dark, frac,
            ",".join(str(v) for v in box) if box else "-", extent, verdict))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
