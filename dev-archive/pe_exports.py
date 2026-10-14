import struct, sys, os

def exports(path):
    """解析 PE 导出表，返回导出函数名集合。"""
    d = open(path, "rb").read()
    if d[:2] != b"MZ":
        raise ValueError("not PE")
    e_lfanew = struct.unpack_from("<I", d, 0x3C)[0]
    if d[e_lfanew:e_lfanew + 4] != b"PE\0\0":
        raise ValueError("no PE sig")
    coff = e_lfanew + 4
    nsec, = struct.unpack_from("<H", d, coff + 2)
    optsz, = struct.unpack_from("<H", d, coff + 16)
    opt = coff + 20
    magic, = struct.unpack_from("<H", d, opt)
    pe32p = (magic == 0x20B)
    # 数据目录：PE32+ 从 opt+112 开始，PE32 从 opt+96
    dd = opt + (112 if pe32p else 96)
    exp_rva, exp_size = struct.unpack_from("<II", d, dd)
    if exp_rva == 0:
        return set()
    secs = []
    sh = opt + optsz
    for i in range(nsec):
        off = sh + i * 40
        name = d[off:off + 8]
        vsz, va, rsz, ra = struct.unpack_from("<IIII", d, off + 8)
        secs.append((va, vsz, ra, rsz, name))

    def rva2off(r):
        for va, vsz, ra, rsz, _ in secs:
            if va <= r < va + max(vsz, rsz):
                return ra + (r - va)
        return None

    eo = rva2off(exp_rva)
    if eo is None:
        return set()
    nnames, = struct.unpack_from("<I", d, eo + 24)
    names_rva, = struct.unpack_from("<I", d, eo + 32)
    no = rva2off(names_rva)
    out = set()
    for i in range(nnames):
        nr, = struct.unpack_from("<I", d, no + i * 4)
        p = rva2off(nr)
        end = d.index(b"\0", p)
        out.add(d[p:end].decode("ascii", "replace"))
    return out


root = os.environ.get("WINDIR", r"C:\Windows")
for dll in ["user32.dll", "gdi32.dll", "kernel32.dll"]:
    p = os.path.join(root, "System32", dll)
    try:
        s = exports(p)
    except Exception as ex:
        print("%-14s 解析失败: %s" % (dll, ex))
        continue
    print("%-14s 共 %d 个导出" % (dll, len(s)))
    for fn in ["GetObjectA", "GetObjectW", "GetCursorInfo", "GetIconInfo",
               "CreateCompatibleDC", "DeleteDC", "DeleteObject", "GetDIBits",
               "GetCursorPos", "GetTempPathA", "DeleteFileA"]:
        if fn in s:
            print("    ★ %s" % fn)
