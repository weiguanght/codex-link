#!/usr/bin/env python3
"""Small original icon, rendered without third-party dependencies."""
import json
from pathlib import Path
import struct
import zlib

root = Path(__file__).resolve().parents[1] / 'ios/CodexLink/Assets.xcassets'
target = root / 'AppIcon.appiconset'
target.mkdir(parents=True, exist_ok=True)
(root / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}))
(target / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'Icon1024.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2))
pixels = bytearray()
for y in range(1024):
    pixels.append(0)
    for x in range(1024):
        # Desktop outline, two terminal chevrons, and an overlapping phone.
        desktop = (170 <= x < 770 and 245 <= y < 655 and (x < 202 or x >= 738 or y < 277 or y >= 623))
        stand = (430 <= x < 490 and 655 <= y < 738) or (340 <= x < 580 and 728 <= y < 760)
        terminal = ((285 <= x < 385 and abs(abs(y - 448) - (x - 285)) < 18) or
                    (440 <= x < 540 and abs(abs(y - 448) - (540 - x)) < 18))
        phone = (630 <= x < 865 and 450 <= y < 840)
        border = phone and (x < 660 or x >= 835 or y < 480 or y >= 810)
        dot = phone and ((x - 747) ** 2 + (y - 770) ** 2 < 14 ** 2)
        lit = border or dot if phone else desktop or stand or terminal
        color = (221, 250, 235) if lit else (17 + y // 100, 66 + y // 60, 59 + x // 95)
        pixels.extend(color)
def chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 1024, 1024, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')
(target / 'Icon1024.png').write_bytes(png)
