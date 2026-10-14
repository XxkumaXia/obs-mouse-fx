import re, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pe_exports import exports

LUA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "obs-fx", "mouse-fx.lua")
root = os.environ.get("WINDIR", r"C:\Windows")
tbl = {}
for dll in ["user32", "gdi32", "kernel32"]:
    tbl[dll] = exports(os.path.join(root, "System32", dll + ".dll"))

txt = open(LUA, encoding="utf-8").read()
calls = {}
for m in re.finditer(r"\b(user32|gdi32|kernel32)\.([A-Za-z_][A-Za-z0-9_]*)", txt):
    line = txt[:m.start()].count("\n") + 1
    calls.setdefault((m.group(1), m.group(2)), []).append(line)

bad = 0
for (lib, fn), lines in sorted(calls.items()):
    ok = fn in tbl[lib]
    # 顺便看看它到底在哪个库里
    where = [d for d in tbl if fn in tbl[d]]
    if not ok:
        bad += 1
    print("[%s] %-9s %-24s L%s%s" % (
        "OK " if ok else "BAD", lib, fn, ",".join(map(str, lines)),
        "" if ok else "   -> 实际在: " + (",".join(where) if where else "未找到")))
print()
print("共 %d 个不同调用，%d 个归属错误" % (len(calls), bad))
