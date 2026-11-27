#!/usr/bin/env python3
"""
taller_gui.py - Cliente RFB/VNC minimo en Python puro (stdlib only)
Permite a agentes de IA ver pantallas (PNG) y enviar clics/teclas por tunel SSH
sin instalar librerias externas en el controlador.
"""

import argparse
import os
import socket
import struct
import sys
import time
import zlib

# --- Tablas estandar FIPS 46-3 DES (para autenticacion RFB Security Type 2) ---

_IP = [
    58, 50, 42, 34, 26, 18, 10, 2,
    60, 52, 44, 36, 28, 20, 12, 4,
    62, 54, 46, 38, 30, 22, 14, 6,
    64, 56, 48, 40, 32, 24, 16, 8,
    57, 49, 41, 33, 25, 17, 9, 1,
    59, 51, 43, 35, 27, 19, 11, 3,
    61, 53, 45, 37, 29, 21, 13, 5,
    63, 55, 47, 39, 31, 23, 15, 7,
]

_FP = [
    40, 8, 48, 16, 56, 24, 64, 32,
    39, 7, 47, 15, 55, 23, 63, 31,
    38, 6, 46, 14, 54, 22, 62, 30,
    37, 5, 45, 13, 53, 21, 61, 29,
    36, 4, 44, 12, 52, 20, 60, 28,
    35, 3, 43, 11, 51, 19, 59, 27,
    34, 2, 42, 10, 50, 18, 58, 26,
    33, 1, 41, 9, 49, 17, 57, 25,
]

_E = [
    32, 1, 2, 3, 4, 5,
    4, 5, 6, 7, 8, 9,
    8, 9, 10, 11, 12, 13,
    12, 13, 14, 15, 16, 17,
    16, 17, 18, 19, 20, 21,
    20, 21, 22, 23, 24, 25,
    24, 25, 26, 27, 28, 29,
    28, 29, 30, 31, 32, 1,
]

_P = [
    16, 7, 20, 21, 29, 12, 28, 17,
    1, 15, 23, 26, 5, 18, 31, 10,
    2, 8, 24, 14, 32, 27, 3, 9,
    19, 13, 30, 6, 22, 11, 4, 25,
]

_PC1 = [
    57, 49, 41, 33, 25, 17, 9,
    1, 58, 50, 42, 34, 26, 18,
    10, 2, 59, 51, 43, 35, 27,
    19, 11, 3, 60, 52, 44, 36,
    63, 55, 47, 39, 31, 23, 15,
    7, 62, 54, 46, 38, 30, 22,
    14, 6, 61, 53, 45, 37, 29,
    21, 13, 5, 28, 20, 12, 4,
]

_PC2 = [
    14, 17, 11, 24, 1, 5,
    3, 28, 15, 6, 21, 10,
    23, 19, 12, 4, 26, 8,
    16, 7, 27, 20, 13, 2,
    41, 52, 31, 37, 47, 55,
    30, 40, 51, 45, 33, 48,
    44, 49, 39, 56, 34, 53,
    46, 42, 50, 36, 29, 32,
]

_SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]

_SBOX = [
    [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7],
        [0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8],
        [4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0],
        [15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    ],
    [
        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10],
        [3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5],
        [0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15],
        [13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    ],
    [
        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8],
        [13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1],
        [13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7],
        [1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    ],
    [
        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15],
        [13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9],
        [10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4],
        [3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    ],
    [
        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9],
        [14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6],
        [4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14],
        [11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    ],
    [
        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11],
        [10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8],
        [9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6],
        [4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    ],
    [
        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1],
        [13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6],
        [1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2],
        [6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    ],
    [
        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7],
        [1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2],
        [7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8],
        [2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ],
]


def _permute(val: int, width: int, table: list[int]) -> int:
    out = 0
    for pos in table:
        out = (out << 1) | ((val >> (width - pos)) & 1)
    return out


def _des_subkeys(key64: int) -> list[int]:
    k56 = _permute(key64, 64, _PC1)
    c = (k56 >> 28) & 0xFFFFFFF
    d = k56 & 0xFFFFFFF
    subkeys = []
    for shift in _SHIFTS:
        c = ((c << shift) | (c >> (28 - shift))) & 0xFFFFFFF
        d = ((d << shift) | (d >> (28 - shift))) & 0xFFFFFFF
        subkeys.append(_permute((c << 28) | d, 56, _PC2))
    return subkeys


def _des_feistel(r32: int, k48: int) -> int:
    x = _permute(r32, 32, _E) ^ k48
    out = 0
    for i in range(8):
        chunk = (x >> (42 - i * 6)) & 0x3F
        row = ((chunk >> 4) & 0x2) | (chunk & 0x1)
        col = (chunk >> 1) & 0xF
        out = (out << 4) | _SBOX[i][row][col]
    return _permute(out, 32, _P)


def des_encrypt_block(key8: bytes, block8: bytes) -> bytes:
    key64 = int.from_bytes(key8, "big")
    block64 = int.from_bytes(block8, "big")
    subkeys = _des_subkeys(key64)
    perm = _permute(block64, 64, _IP)
    left = (perm >> 32) & 0xFFFFFFFF
    right = perm & 0xFFFFFFFF
    for sk in subkeys:
        left, right = right, left ^ _des_feistel(right, sk)
    combined = (right << 32) | left
    cipher = _permute(combined, 64, _FP)
    return cipher.to_bytes(8, "big")


def rfb_vnc_auth_response(password: str, challenge: bytes) -> bytes:
    raw = password.encode("latin-1", errors="ignore")[:8].ljust(8, b"\x00")
    rev_key = bytes(int(f"{b:08b}"[::-1], 2) for b in raw)
    return des_encrypt_block(rev_key, challenge[:8]) + des_encrypt_block(rev_key, challenge[8:16])


# --- Escritor PNG puro ---

def _png_chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def encode_png_rgb(width: int, height: int, rgb_bytes: bytes) -> bytes:
    stride = width * 3
    raw = bytearray((stride + 1) * height)
    for y in range(height):
        src_off = y * stride
        dst_off = y * (stride + 1)
        raw[dst_off] = 0
        raw[dst_off + 1 : dst_off + 1 + stride] = rgb_bytes[src_off : src_off + stride]
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    idat = zlib.compress(bytes(raw), level=6)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", idat)
        + _png_chunk(b"IEND", b"")
    )


# --- Mapa de KeySyms X11 ---

_SPECIAL_KEYS = {
    "enter": 0xFF0D,
    "return": 0xFF0D,
    "tab": 0xFF09,
    "esc": 0xFF1B,
    "escape": 0xFF1B,
    "backspace": 0xFF08,
    "bs": 0xFF08,
    "delete": 0xFFFF,
    "del": 0xFFFF,
    "insert": 0xFF63,
    "ins": 0xFF63,
    "space": 0x0020,
    "home": 0xFF50,
    "end": 0xFF57,
    "pageup": 0xFF55,
    "pgup": 0xFF55,
    "pagedown": 0xFF56,
    "pgdn": 0xFF56,
    "left": 0xFF51,
    "up": 0xFF52,
    "right": 0xFF53,
    "down": 0xFF54,
    "shift": 0xFFE1,
    "ctrl": 0xFFE3,
    "control": 0xFFE3,
    "alt": 0xFFE9,
    "win": 0xFFEB,
    "super": 0xFFEB,
    "capslock": 0xFFE5,
    "printscreen": 0xFF61,
    "f1": 0xFFBE, "f2": 0xFFBF, "f3": 0xFFC0, "f4": 0xFFC1,
    "f5": 0xFFC2, "f6": 0xFFC3, "f7": 0xFFC4, "f8": 0xFFC5,
    "f9": 0xFFC6, "f10": 0xFFC7, "f11": 0xFFC8, "f12": 0xFFC9,
}


class RFBClient:
    def __init__(self, host: str, port: int, password: str = "", timeout: float = 10.0):
        self.host = host
        self.port = port
        self.password = password
        self.timeout = timeout
        self.sock: socket.socket | None = None
        self.width = 0
        self.height = 0
        self.desktop_name = ""

    def _recv_exact(self, n: int) -> bytes:
        buf = bytearray()
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("Conexion VNC cerrada inesperadamente.")
            buf.extend(chunk)
        return bytes(buf)

    def connect(self) -> None:
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self.sock.settimeout(self.timeout)
        banner = self._recv_exact(12)
        if not banner.startswith(b"RFB "):
            raise RuntimeError(f"Banner VNC invalido: {banner!r}")

        major = int(banner[4:7])
        minor = int(banner[8:11])
        use_ver = b"RFB 003.008\n" if (major > 3 or minor >= 8) else (b"RFB 003.007\n" if minor == 7 else b"RFB 003.003\n")
        self.sock.sendall(use_ver)

        if use_ver == b"RFB 003.003\n":
            (sec_type,) = struct.unpack(">I", self._recv_exact(4))
            if sec_type == 0:
                (rlen,) = struct.unpack(">I", self._recv_exact(4))
                raise RuntimeError(self._recv_exact(rlen).decode("utf-8", errors="replace"))
        else:
            (count,) = struct.unpack(">B", self._recv_exact(1))
            if count == 0:
                (rlen,) = struct.unpack(">I", self._recv_exact(4))
                raise RuntimeError(self._recv_exact(rlen).decode("utf-8", errors="replace"))
            types = list(self._recv_exact(count))
            if self.password and 2 in types:
                sec_type = 2
            elif 1 in types:
                sec_type = 1
            elif 2 in types:
                sec_type = 2
            else:
                raise RuntimeError(f"Ningun metodo de autenticacion VNC compatible: {types}")
            self.sock.sendall(struct.pack(">B", sec_type))

        if sec_type == 2:
            challenge = self._recv_exact(16)
            self.sock.sendall(rfb_vnc_auth_response(self.password, challenge))

        if use_ver == b"RFB 003.008\n" or sec_type == 2:
            (res,) = struct.unpack(">I", self._recv_exact(4))
            if res != 0:
                msg = "Autenticacion VNC fallida"
                if use_ver == b"RFB 003.008\n":
                    try:
                        (rlen,) = struct.unpack(">I", self._recv_exact(4))
                        msg = self._recv_exact(rlen).decode("utf-8", errors="replace")
                    except Exception:
                        pass
                raise RuntimeError(msg)

        # ClientInit: shared=1
        self.sock.sendall(b"\x01")
        init_hdr = self._recv_exact(24)
        self.width, self.height = struct.unpack(">HH", init_hdr[:4])
        (name_len,) = struct.unpack(">I", init_hdr[20:24])
        self.desktop_name = self._recv_exact(name_len).decode("utf-8", errors="replace")

        # SetPixelFormat: 32bpp BGRX little-endian (depth 24)
        pf = struct.pack(">BBBBBBBBHHHBBBBBB", 0, 0, 0, 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0, 0, 0, 0)
        self.sock.sendall(pf)
        # SetEncodings: Raw (0), CopyRect (1)
        self.sock.sendall(struct.pack(">BBHii", 2, 0, 2, 0, 1))

    def close(self) -> None:
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None

    def capture_rgb(self) -> bytes:
        fb = bytearray(self.width * self.height * 4)
        covered = 0
        target_pixels = self.width * self.height
        self.sock.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, self.width, self.height))

        deadline = time.monotonic() + max(self.timeout, 12.0)
        while time.monotonic() < deadline:
            msg_type = self._recv_exact(1)[0]
            if msg_type == 0:  # FramebufferUpdate
                _pad, n_rects = struct.unpack(">BH", self._recv_exact(3))
                for _ in range(n_rects):
                    rx, ry, rw, rh, enc = struct.unpack(">HHHHi", self._recv_exact(12))
                    if enc == 0:  # Raw
                        raw = self._recv_exact(rw * rh * 4)
                        row_bytes = rw * 4
                        for row in range(rh):
                            yy = ry + row
                            if 0 <= yy < self.height and 0 <= rx < self.width:
                                copy_w = min(rw, self.width - rx) * 4
                                dst = (yy * self.width + rx) * 4
                                src = row * row_bytes
                                fb[dst : dst + copy_w] = raw[src : src + copy_w]
                        covered += rw * rh
                    elif enc == 1:  # CopyRect
                        sx, sy = struct.unpack(">HH", self._recv_exact(4))
                        snap = bytes(fb)
                        for row in range(rh):
                            yy = ry + row
                            syy = sy + row
                            if 0 <= yy < self.height and 0 <= syy < self.height:
                                copy_w = min(rw, self.width - rx, self.width - sx) * 4
                                if copy_w > 0:
                                    dst = (yy * self.width + rx) * 4
                                    src = (syy * self.width + sx) * 4
                                    fb[dst : dst + copy_w] = snap[src : src + copy_w]
                        covered += rw * rh
                    else:
                        raise RuntimeError(f"Encoding VNC no soportado: {enc}")
                if covered >= target_pixels:
                    break
                # Si llegaron rectángulos parciales, esperar brevemente otro update o pedir resto
                self.sock.settimeout(0.35)
                try:
                    continue
                except socket.timeout:
                    break
            elif msg_type == 1:  # SetColourMapEntries
                _, n_colors = struct.unpack(">HH", self._recv_exact(4))
                self._recv_exact(n_colors * 6)
            elif msg_type == 2:  # Bell
                pass
            elif msg_type == 3:  # ServerCutText
                self._recv_exact(3)
                (tlen,) = struct.unpack(">I", self._recv_exact(4))
                self._recv_exact(tlen)
            else:
                raise RuntimeError(f"Mensaje RFB desconocido: {msg_type}")

        self.sock.settimeout(self.timeout)
        rgb = bytearray(self.width * self.height * 3)
        rgb[0::3] = fb[2::4]
        rgb[1::3] = fb[1::4]
        rgb[2::3] = fb[0::4]
        return bytes(rgb)

    def pointer_event(self, mask: int, x: int, y: int) -> None:
        cx = max(0, min(x, self.width - 1)) if self.width > 0 else max(0, x)
        cy = max(0, min(y, self.height - 1)) if self.height > 0 else max(0, y)
        self.sock.sendall(struct.pack(">BBHH", 5, mask, cx, cy))

    def key_event(self, down: bool, keysym: int) -> None:
        self.sock.sendall(struct.pack(">BBxxI", 4, 1 if down else 0, keysym))

    def click(self, x: int, y: int, button: str = "left", double: bool = False) -> None:
        mask = 4 if button == "right" else (2 if button == "middle" else 1)
        count = 2 if double else 1
        self.pointer_event(0, x, y)
        time.sleep(0.03)
        for i in range(count):
            self.pointer_event(mask, x, y)
            time.sleep(0.04)
            self.pointer_event(0, x, y)
            if i + 1 < count:
                time.sleep(0.08)
        time.sleep(0.1)

    def drag(self, x1: int, y1: int, x2: int, y2: int) -> None:
        self.pointer_event(0, x1, y1)
        time.sleep(0.03)
        self.pointer_event(1, x1, y1)
        steps = 8
        for s in range(1, steps + 1):
            nx = int(round(x1 + (x2 - x1) * s / steps))
            ny = int(round(y1 + (y2 - y1) * s / steps))
            self.pointer_event(1, nx, ny)
            time.sleep(0.015)
        self.pointer_event(0, x2, y2)
        time.sleep(0.1)

    def type_text(self, text: str) -> None:
        for ch in text:
            if ch == "\n":
                ks = 0xFF0D
            elif ch == "\t":
                ks = 0xFF09
            else:
                ks = ord(ch)
            self.key_event(True, ks)
            time.sleep(0.015)
            self.key_event(False, ks)
            time.sleep(0.015)
        time.sleep(0.1)

    def send_combo(self, combo: str) -> None:
        parts = [p.strip() for p in combo.split("+") if p.strip()]
        if not parts:
            raise ValueError("Tecla o combinacion vacia")
        syms = []
        for p in parts:
            low = p.lower()
            if low in _SPECIAL_KEYS:
                syms.append(_SPECIAL_KEYS[low])
            elif len(p) == 1:
                syms.append(ord(p))
            else:
                raise ValueError(f"Tecla desconocida: '{p}'")
        for ks in syms:
            self.key_event(True, ks)
            time.sleep(0.025)
        for ks in reversed(syms):
            self.key_event(False, ks)
            time.sleep(0.025)
        time.sleep(0.1)


def run_self_test() -> int:
    # 1. Vector oficial FIPS 46-3 DES ECB
    k = bytes.fromhex("133457799BBCDFF1")
    pt = bytes.fromhex("0123456789ABCDEF")
    ct = des_encrypt_block(k, pt)
    assert ct == bytes.fromhex("85E813540F0AB405"), f"DES mismatch: {ct.hex()}"

    k0 = bytes.fromhex("0000000000000000")
    ct0 = des_encrypt_block(k0, k0)
    assert ct0 == bytes.fromhex("8CA64DE9C1B123A7"), f"DES zero mismatch: {ct0.hex()}"

    # 2. Vector RFB bit-reversed key
    chal = bytes.fromhex("00112233445566778899AABBCCDDEEFF")
    resp = rfb_vnc_auth_response("secret", chal)
    assert len(resp) == 16 and resp != chal

    # 3. Round-trip PNG
    w, h = 4, 3
    sample_rgb = bytes([(i * 19) % 256 for i in range(w * h * 3)])
    png = encode_png_rgb(w, h, sample_rgb)
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    off = 8
    chunks = {}
    while off < len(png):
        clen = struct.unpack(">I", png[off : off + 4])[0]
        ctype = png[off + 4 : off + 8]
        cdata = png[off + 8 : off + 8 + clen]
        ccrc = struct.unpack(">I", png[off + 8 + clen : off + 12 + clen])[0]
        assert (zlib.crc32(ctype + cdata) & 0xFFFFFFFF) == ccrc
        chunks[ctype] = cdata
        off += 12 + clen
    assert b"IHDR" in chunks and b"IDAT" in chunks and b"IEND" in chunks
    raw = zlib.decompress(chunks[b"IDAT"])
    expected_len = h * (1 + w * 3)
    assert len(raw) == expected_len
    print("SELF-TEST OK (DES FIPS-46-3, RFB auth, PNG CRC32 round-trip)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Control GUI VNC por RFB 3.8 (Python puro)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    def add_conn_args(p):
        p.add_argument("--host", default="127.0.0.1")
        p.add_argument("--port", type=int, required=True)
        p.add_argument("--password", default="")

    p_screen = sub.add_parser("screen")
    add_conn_args(p_screen)
    p_screen.add_argument("--out", required=True)

    p_click = sub.add_parser("click")
    add_conn_args(p_click)
    p_click.add_argument("--x", type=int, required=True)
    p_click.add_argument("--y", type=int, required=True)
    p_click.add_argument("--button", choices=["left", "right", "middle"], default="left")
    p_click.add_argument("--double", action="store_true")

    p_drag = sub.add_parser("drag")
    add_conn_args(p_drag)
    p_drag.add_argument("--x1", type=int, required=True)
    p_drag.add_argument("--y1", type=int, required=True)
    p_drag.add_argument("--x2", type=int, required=True)
    p_drag.add_argument("--y2", type=int, required=True)

    p_type = sub.add_parser("type")
    add_conn_args(p_type)
    p_type.add_argument("--text", required=True)

    p_key = sub.add_parser("key")
    add_conn_args(p_key)
    p_key.add_argument("--combo", required=True)

    sub.add_parser("self-test")

    args = parser.parse_args()
    if args.cmd == "self-test":
        return run_self_test()

    pw = args.password
    if not pw and os.environ.get("TALLER_VNC_PASS"):
        pw = os.environ["TALLER_VNC_PASS"]

    client = RFBClient(args.host, args.port, password=pw)
    try:
        client.connect()
        if args.cmd == "screen":
            rgb = client.capture_rgb()
            png = encode_png_rgb(client.width, client.height, rgb)
            os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
            with open(args.out, "wb") as f:
                f.write(png)
            print(f"SCREEN_OK {client.width}x{client.height} {args.out}")
        elif args.cmd == "click":
            client.click(args.x, args.y, button=args.button, double=args.double)
            print(f"CLICK_OK {args.x},{args.y} {args.button}{' double' if args.double else ''}")
        elif args.cmd == "drag":
            client.drag(args.x1, args.y1, args.x2, args.y2)
            print(f"DRAG_OK {args.x1},{args.y1}->{args.x2},{args.y2}")
        elif args.cmd == "type":
            client.type_text(args.text)
            print(f"TYPE_OK len={len(args.text)}")
        elif args.cmd == "key":
            client.send_combo(args.combo)
            print(f"KEY_OK {args.combo}")
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
