#!/usr/bin/env python3
"""Gera o fixture usado por utils/test_png.lua.

Produz um PNG pequeno com um filtro de linha diferente a cada linha, para que o
teste exercite os cinco. Junto, guarda os bytes já descomprimidos (o que a
engine devolveria de core.decompress) e a lista de pixels esperados.
"""
import os
import struct
import zlib

W, H = 9, 7
PX = [[((x * 23 + y * 7) % 256, (x * 11 + y * 37) % 256, (x * 53 + y * 3) % 256)
       for x in range(W)] for y in range(H)]


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def build_raw():
    raw = bytearray()
    prev = [0] * (W * 3)
    for y in range(H):
        ft = y % 5
        line = []
        for x in range(W):
            line.extend(PX[y][x])
        out = bytearray([ft])
        for i in range(W * 3):
            a = line[i - 3] if i >= 3 else 0
            b = prev[i]
            c = prev[i - 3] if i >= 3 else 0
            v = line[i]
            if ft == 0:
                f = v
            elif ft == 1:
                f = (v - a) % 256
            elif ft == 2:
                f = (v - b) % 256
            elif ft == 3:
                f = (v - (a + b) // 2) % 256
            else:
                f = (v - paeth(a, b, c)) % 256
            out.append(f)
        raw += out
        prev = line
    return bytes(raw)


def chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))


def main():
    base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
    os.makedirs(base, exist_ok=True)
    raw = build_raw()

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")

    with open(os.path.join(base, "teste.png"), "wb") as f:
        f.write(png)
    with open(os.path.join(base, "teste.raw"), "wb") as f:
        f.write(raw)
    with open(os.path.join(base, "teste.esperado.txt"), "w") as f:
        for y in range(H):
            for x in range(W):
                f.write("%d %d %d %d %d\n" % ((x, y) + PX[y][x]))

    print("fixture gerado: %dx%d, filtros 0..4" % (W, H))


if __name__ == "__main__":
    main()
