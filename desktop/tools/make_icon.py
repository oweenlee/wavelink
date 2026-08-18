import zlib, struct, os

W = H = 32

def pixels():
    out = []
    cx = (W - 1) / 2.0
    cy = (H - 1) / 2.0
    for y in range(H):
        for x in range(W):
            dx = x - cx
            dy = y - cy
            r = (dx * dx + dy * dy) ** 0.5
            # white circle on transparent background
            if r < 13.0:
                out.append((235, 238, 245, 255))
            else:
                out.append((0, 0, 0, 0))
    return out

def chunk(typ, data):
    return (struct.pack('>I', len(data)) + typ + data +
            struct.pack('>I', zlib.crc32(typ + data) & 0xffffffff))

def make_png(path):
    px = pixels()
    raw = bytearray()
    for i in range(W * H):
        raw.append(0)  # filter type 0
        R, G, B, A = px[i]
        raw += bytes((R, G, B, A))
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as f:
        f.write(png)

def make_ico(path):
    px = pixels()
    xor = bytearray()
    for y in reversed(range(H)):
        for x in range(W):
            R, G, B, A = px[y * W + x]
            xor += bytes((B, G, R, A))
    androw = ((W + 31) // 32) * 4
    andmask = b'\x00' * (androw * H)
    dib = struct.pack('<IiiHHIIiiII', 40, W, H * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    img = dib + bytes(xor) + andmask
    icondir = struct.pack('<HHH', 0, 1, 1)
    entry = struct.pack('<BBBBHHII', W if W < 256 else 0, H if H < 256 else 0,
                        0, 0, 1, 32, len(img), 6 + 16)
    with open(path, 'wb') as f:
        f.write(icondir + entry + img)

os.makedirs('assets', exist_ok=True)
make_png('assets/tray_icon.png')
make_ico('assets/tray_icon.ico')
print('icons written:', os.path.getsize('assets/tray_icon.png'), os.path.getsize('assets/tray_icon.ico'))
