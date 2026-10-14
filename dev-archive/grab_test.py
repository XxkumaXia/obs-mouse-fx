"""用 ctypes 直接复刻 grab_cursor 的逻辑，验证 AND 掩码处理与黑块成因。
这是纯 Python 复刻版（真实脚本是 LuaJIT FFI，逻辑一致）。
"""
import ctypes
from ctypes import wintypes
import sys

user32 = ctypes.WinDLL('user32', use_last_error=True)
gdi32 = ctypes.WinDLL('gdi32', use_last_error=True)

class CURSORINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("hCursor", wintypes.HANDLE), ("ptScreenPos", wintypes.POINT)]

class ICONINFO(ctypes.Structure):
    _fields_ = [("fIcon", wintypes.BOOL), ("xHotspot", wintypes.DWORD),
                ("yHotspot", wintypes.DWORD), ("hbmMask", wintypes.HBITMAP),
                ("hbmColor", wintypes.HBITMAP)]

class BITMAP(ctypes.Structure):
    _fields_ = [("bmType", ctypes.c_long), ("bmWidth", ctypes.c_long),
                ("bmHeight", ctypes.c_long), ("bmWidthBytes", ctypes.c_long),
                ("bmPlanes", wintypes.WORD), ("bmBitsPixel", wintypes.WORD),
                ("bmBits", ctypes.c_void_p)]

user32.GetCursorInfo.argtypes = [ctypes.POINTER(CURSORINFO)]
user32.GetIconInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(ICONINFO)]
gdi32.GetObjectA.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p]
gdi32.DeleteObject.argtypes = [wintypes.HANDLE]

def grab():
    ci = CURSORINFO()
    ci.cbSize = ctypes.sizeof(ci)
    if not user32.GetCursorInfo(ctypes.byref(ci)):
        return "GetCursorInfo 失败"
    if not ci.hCursor:
        # 光标正被隐藏（处于非客户区/全屏独占等）→ 这一步就是黑帧来源之一
        return "hCursor 为空（光标不可见/被隐藏）"
    ii = ICONINFO()
    if not user32.GetIconInfo(ci.hCursor, ctypes.byref(ii)):
        return "GetIconInfo 失败"
    bmp = BITMAP()
    hb = ii.hbmColor or ii.hbmMask
    ok = gdi32.GetObjectA(hb, ctypes.sizeof(bmp), ctypes.byref(bmp)) if hb else 0
    res = dict(w=bmp.bmWidth if ok else 0, h=bmp.bmHeight if ok else 0,
               bits=bmp.bmBitsPixel if ok else 0,
               hotx=ii.xHotspot, hoty=ii.yHotspot,
               has_color=bool(ii.hbmColor), has_mask=bool(ii.hbmMask),
               hcur=hex(ci.hCursor or 0), flags=ci.flags)
    if ii.hbmColor: gdi32.DeleteObject(ii.hbmColor)
    if ii.hbmMask: gdi32.DeleteObject(ii.hbmMask)
    return res

print("=== 当前系统光标实测 ===")
for i in range(3):
    print("  第%d次: %s" % (i + 1, grab()))
print()
print("说明：flags/CURSOR_SHOWING 位为 1 表示光标正在显示。")
print("      hCursor 为空 = 光标此刻被隐藏 → 脚本会立刻返回 nil（好）")
