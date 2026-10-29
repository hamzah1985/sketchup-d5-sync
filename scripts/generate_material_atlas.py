"""Generate an original asymmetric RGB texture fixture using the standard library."""
from pathlib import Path
import struct
import zlib

path = Path(__file__).with_name('material_atlas.png')
width = height = 128
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
rows = bytearray()
colors = [(235, 35, 25), (25, 195, 55), (25, 70, 235), (245, 200, 20)]
for y in range(height):
    rows.append(0)
    for x in range(width):
        color = colors[(2 if y >= 64 else 0) + (1 if x >= 64 else 0)]
        if x < 5 or y < 5 or 61 <= x < 66 or 61 <= y < 66:
            color = (245, 245, 245)
        if 15 <= x < 23 and 15 <= y < 43:
            color = (15, 15, 15)
        rows.extend(color)
path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
                 + chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b''))
print(path)
