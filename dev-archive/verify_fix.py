"""验证修复：按 1bpp 正确读掩码后，光标应该还原成本来图案，而不是黑方块。
同时和 cursor.png 做逐像素比对，确保两条路径一致。
"""
import ctypes
import os
from ctypes import wintypes
from PIL import Image

user32 = ctypes.WinDLL('user32', use_last_error=True)
gdi32 = ctypes.WinDLL('gdi32', use_last_error=True)


class CURSORINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("hCursor", wintypes.HANDLE), ("ptScreenPos", wintypes.POINT)]


class ICONINFO(ctypes.Structure):
    _fields_ = [("fIcon", wintypes.BOOL), ("xHotspot", wintypes.DWORD),
                ("yHotspot", wintypes.DWORD), ("hbmMask", wintypes.HBITMAP),
                ("hbmColor", wintypes.HBITMAP)]


class BMIH(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", ctypes.c_long),
                ("biHeight", ctypes.c_long), ("biPlanes", wintypes.WORD),
                ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", ctypes.c_long),
                ("biYPelsPerMeter", ctypes.c_long), ("biClrUsed", wintypes.DWORD),
                ("biClrImportant", wintypes.DWORD)]


class BMI(ctypes.Structure):
    _fields_ = [("bmiHeader", BMIH), ("bmiColors", wintypes.DWORD * 3)]


ci = CURSORINFO(); ci.cbSize = ctypes.sizeof(ci)
user32.GetCursorInfo(ctypes.byref(ci))
ii = ICONINFO(); user32.GetIconInfo(ci.hCursor, ctypes.byref(ii))
W = H = 32
hdc = gdi32.CreateCompatibleDC(None)

# --- 颜色 32bpp ---
cbmi = BMI(); ch = cbmi.bmiHeader
ch.biSize = 40; ch.biWidth = W; ch.biHeight = H
ch.biPlanes = 1; ch.biBitCount = 32; ch.biCompression = 0
cbuf = ctypes.create_string_buffer(W * H * 4)
gdi32.GetDIBits(hdc, ii.hbmColor, 0, H, cbuf, ctypes.byref(cbmi), 0)
color = cbuf.raw[:W * H * 4]

# --- 掩码 1bpp（修复后的正确做法）---
mrow = ((W + 31) // 32) * 4
mbmi = BMI(); mh = mbmi.bmiHeader
mh.biSize = 40; mh.biWidth = W; mh.biHeight = H
mh.biPlanes = 1; mh.biBitCount = 1; mh.biCompression = 0
mbuf = ctypes.create_string_buffer(mrow * H)
gdi32.GetDIBits(hdc, ii.hbmMask, 0, H, mbuf, ctypes.byref(mbmi), 0)
mask = mbuf.raw[:mrow * H]

has_alpha = any(color[i * 4 + 3] > 0 for i in range(W * H))
print("hbmColor 有真 alpha ?", has_alpha)

out = bytearray(W * H * 4)
opaque = 0
for y in range(H):
    my = H - 1 - y
    for x in range(W):
        co = (my * W + x) * 4
        b, g, r, a = color[co], color[co + 1], color[co + 2], color[co + 3]
        if not has_alpha:
            byte = mask[my * mrow + x // 8]
            bitv = (byte >> (7 - (x % 8))) & 1
            a = 0 if bitv else 255
        if a == 0:
            r = g = b = 0
        else:
            opaque += 1
        o = (y * W + x) * 4
        out[o:o + 4] = bytes((r, g, b, a))

print("修复后不透明像素 = %d / %d" % (opaque, W * H))
img = Image.frombytes("RGBA", (W, H), bytes(out))
img.save("fixed_cursor.png")
img.resize((W * 10, H * 10), Image.NEAREST).save("fixed_cursor_big.png")

# 与 cursor.png 第一帧对比
ref = Image.open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "..", "obs-fx", "cursor.png")).convert("RGBA").crop((0, 0, W, H))
diff = sum(1 for a, b in zip(img.getdata(), ref.getdata()) if a != b)
print("与 cursor.png 帧0 的差异像素 = %d / %d" % (diff, W * H))
gdi32.DeleteObject(ii.hbmColor); gdi32.DeleteObject(ii.hbmMask)
