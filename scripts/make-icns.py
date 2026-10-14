#!/usr/bin/env python3
"""Build a macOS icon from the checked-in PNG using macOS's sips."""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def main(source: Path, output: Path) -> None:
    # ICNS stores PNGs for these modern icon sizes, including Retina variants.
    sizes = {
        b"ic07": 128,
        b"ic08": 256,
        b"ic09": 512,
        b"ic10": 1024,
        b"ic11": 32,
        b"ic12": 64,
        b"ic13": 256,
        b"ic14": 512,
    }
    chunks = []
    with tempfile.TemporaryDirectory() as directory:
        for code, size in sizes.items():
            png = Path(directory) / f"{size}.png"
            if not png.exists():
                subprocess.run(
                    ["sips", "-z", str(size), str(size), str(source), "--out", str(png)],
                    check=True,
                    stdout=subprocess.DEVNULL,
                )
            data = png.read_bytes()
            chunks.append(code + struct.pack(">I", len(data) + 8) + data)
    body = b"".join(chunks)
    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
