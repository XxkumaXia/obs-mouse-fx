"""真正把光标像素读出来，检查 32bpp 的 alpha 通道是否可信。"""
import ctypes
from ctypes import wintypes

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

user32.GetCursorInfo.argtypes = [ctypes.POINTER(CURSORINFO)]
user32.GetIconInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(ICONINFO)]
gdi32.CreateCompatibleDC.argtypes = [wintypes.HDC]
gdi32.GetDIBits.argtypes = [wintypes.HDC, wintypes.HBITMAP, wintypes.UINT,
                            wintypes.UINT, ctypes.c_void_p, ctypes.POINTER(BMI),
                            wintypes.UINT]

ci = CURSORINFO(); ci.cbSize = ctypes.sizeof(ci)
user32.GetCursorInfo(ctypes.byref(ci))
ii = ICONINFO(); user32.GetIconInfo(ci.hCursor, ctypes.byref(ii))

W = H = 32
bmi = BMI(); hd = bmi.bmiHeader
hd.biSize = 40; hd.biWidth = W; hd.biHeight = H
hd.biPlanes = 1; hd.biBitCount = 32; hd.biCompression = 0

hdc = gdi32.CreateCompatibleDC(None)
buf = ctypes.create_string_buffer(W * H * 4)
n = gdi32.GetDIBits(hdc, ii.hbmColor, 0, H, buf, ctypes.byref(bmi), 0)
print("GetDIBits(hbmColor) 返回", n, "行")
raw = buf.raw[:W * H * 4]

alpha = [raw[i * 4 + 3] for i in range(W * H)]
zero_a = sum(1 for a in alpha if a == 0)
print("alpha 通道: 全0像素=%d/%d, 非0像素=%d" % (zero_a, W*H, W*H-zero_a))
print("alpha 取值集合(前10):", sorted(set(alpha))[:10])

# 掩码
mbuf = ctypes.create_string_buffer(W * H * 4)
m = gdi32.GetDIBits(hdc, ii.hbmMask, 0, H, mbuf, ctypes.byref(bmi), 0)
mraw = mbuf.raw[:W * H * 4]
malpha = [mraw[i * 4 + 3] for i in range(W * H)]
print()
print("掩码 GetDIBits 返回", m)
print("掩码 alpha 通道: 非0=%d, 为0=%d" % (sum(1 for a in malpha if a), sum(1 for a in malpha if not a)))

# 关键判断
print()
print("=== 判定 ===")
if zero_a == W*H:
    print("hbmColor 的 alpha 全 0 —— 但这是 32bpp，脚本会走 has_alpha=False 分支用掩码 → 正常")
else:
    print("hbmColor 有真实 alpha（非0）→ 脚本走 alpha 分支")
    # 检查是否所有非透明像素的 RGB 都是黑
    blk = sum(1 for i in range(W*H)
              if raw[i*4+3] > 0 and raw[i*4] < 16 and raw[i*4+1] < 16 and raw[i*4+2] < 16)
    op = sum(1 for a in alpha if a > 0)
    print("不透明像素中纯黑 %d / %d (%.1f%%)" % (blk, op, 100*blk/max(op,1)))
gdi32.DeleteObject(ii.hbmColor); gdi32.DeleteObject(ii.hbmMask)
