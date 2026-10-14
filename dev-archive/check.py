import ctypes, sys, os

LUA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "obs-fx", "mouse-fx.lua")

print("=== 1) Lua 语法检查 ===")
try:
    import lupa
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    src = open(LUA, "rb").read().decode("utf-8")
    fn, err = rt.eval("function(s) local f,e = load(s, 'mouse-fx.lua'); return f, e end")(src)
    if fn is None:
        print("FAIL:", err)
        sys.exit(1)
    print("OK  编译通过（%d 行）" % src.count("\n"))
except ImportError as e:
    print("SKIP lupa 不可用：", e)

print()
print("=== 2) 符号归属实测（GetProcAddress）===")
api = {}

def sym(dll, name):
    h = ctypes.windll.kernel32.LoadLibraryW(dll)
    if not h:
        return None
    p = ctypes.windll.kernel32.GetProcAddress(h, name.encode())
    ctypes.windll.kernel32.FreeLibrary(h)
    return p

for name in ["GetCursorInfo", "GetIconInfo", "GetObjectA", "GetObjectW",
             "GetSystemMetrics", "GetCursorPos", "EnumDisplayMonitors"]:
    api.setdefault(name, {})["user32"] = bool(sym("user32.dll", name))

for name in ["GetObjectA", "GetObjectW", "CreateCompatibleDC", "DeleteDC",
             "DeleteObject", "GetDIBits"]:
    api.setdefault(name, {})["gdi32"] = bool(sym("gdi32.dll", name))

for k in sorted(api):
    v = api[k]
    u = "user32=YES" if v.get("user32") else "user32=no "
    g = "gdi32=YES" if v.get("gdi32") else "gdi32=no "
    print("  %-24s %s  %s" % (k, u, g))

print()
print("=== 3) 脚本里的调用点 ===")
import re
txt = open(LUA, encoding="utf-8").read()
for m in re.finditer(r"\b(user32|gdi32|kernel32)\.(GetObjectA|GetCursorInfo|GetIconInfo|CreateCompatibleDC|DeleteDC|DeleteObject|GetDIBits|GetTempPathA|DeleteFileA)\b", txt):
    line = txt[:m.start()].count("\n") + 1
    lib, fn = m.group(1), m.group(2)
    need = {"GetObjectA": "gdi32", "GetCursorInfo": "user32", "GetIconInfo": "user32",
            "CreateCompatibleDC": "gdi32", "DeleteDC": "gdi32", "DeleteObject": "gdi32",
            "GetDIBits": "gdi32", "GetTempPathA": "kernel32", "DeleteFileA": "kernel32"}[fn]
    ok = "OK " if lib == need else "BAD"
    print("  [%s] L%-5d %s.%s  (应为 %s)" % (ok, line, lib, fn, need))
