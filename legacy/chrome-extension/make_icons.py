#!/usr/bin/env python3
"""Draw the extension icons with the standard library only."""
import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent / "icons"


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))


def coverage(distance, radius, size):
    return max(0.0, min(1.0, (radius - distance) * size + 0.5))


def icon(size):
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            dist = (((x + 0.5) / size - 0.5) ** 2 + ((y + 0.5) / size - 0.5) ** 2) ** 0.5
            bg = coverage(dist, 0.5, size)
            dot = coverage(dist, 0.22, size)
            r = round(0x20 + (0xEA - 0x20) * dot)
            g = round(0x21 + (0x43 - 0x21) * dot)
            b = round(0x24 + (0x35 - 0x24) * dot)
            rows += bytes((r, g, b, round(bg * 255)))
    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(rows))) + chunk(b"IEND", b""))


OUT.mkdir(parents=True, exist_ok=True)
for size in (16, 48, 128):
    (OUT / f"{size}.png").write_bytes(icon(size))
