#!/usr/bin/env python3
"""Pack PNG renders into an .icns file (no macOS tools needed).
Usage: make_icns.py <dir with <size>.png files> <out.icns>"""
import pathlib
import struct
import sys

# (icns chunk type, pixel size): 16/32/128/256/512 pt, each @1x and @2x
TYPES = [
    (b"icp4", 16), (b"ic11", 32),
    (b"icp5", 32), (b"ic12", 64),
    (b"ic07", 128), (b"ic13", 256),
    (b"ic08", 256), (b"ic14", 512),
    (b"ic09", 512), (b"ic10", 1024),
]


def main(png_dir: str, out_path: str) -> None:
    chunks = []
    for tag, size in TYPES:
        data = (pathlib.Path(png_dir) / f"{size}.png").read_bytes()
        chunks.append(tag + struct.pack(">I", len(data) + 8) + data)
    body = b"".join(chunks)
    with open(out_path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
    print(f"ok: {out_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
