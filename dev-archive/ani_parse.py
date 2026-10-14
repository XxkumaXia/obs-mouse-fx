"""从 .ani / .cur 正确解出光标 RGBA 帧（正确处理 AND 掩码，不留白边）。

8bpp 老式光标的结构：
  - hbmColor: 索引色位图（此时常是全黑或无关内容）
  - hbmMask : 1bpp AND 掩码，**白(1) = 透明，黑(0) = 不透明**
关键点：8bpp 时必须用掩码定 alpha，且颜色要按调色板还原；
只有 32bpp 才用自带 alpha 通道。
"""
import struct
import os
from PIL import Image


def parse_ico_blob(data, offset=0):
    """解析一个 ICO/CUR/DIB 图元，返回 (w, h, rgba_bytes_topdown) 或 None。"""
    # ICONDIRENTRY 之后是图元数据
    p = offset
    if data[p:p + 4] == b"\x28\x00\x00\x00":  # BITMAPINFOHEADER
        hdr = data[p:p + 40]
        (biSize, biWidth, biHeight, biPlanes, biBitCount,
         biCompression) = struct.unpack_from("<IiiHH I".replace(" ", ""), hdr)
        # CUR 的 height 是双倍（XOR+AND 两张叠起来）
        h2 = biHeight // 2 if biHeight > 0 else -biHeight // 2
        doubled = biHeight != h2 and biHeight == h2 * 2
        h = h2 if doubled else biHeight
        return _decode_dib(data, p, biWidth, h, biBitCount, doubled)
    return None


def _decode_dib(data, p, w, h, bpp, doubled):
    biSize = struct.unpack_from("<I", data, p)[0]
    pal_off = p + biSize
    palette = []
    if bpp <= 8:
        # BITMAPINFOHEADER(40字节) 时调色板直接跟在头后面；
        # biClrUsed 为 0 表示用满 2^bpp 个表项。
        ncol = 1 << bpp
        for i in range(ncol):
            b, g, r, _ = data[pal_off + i * 4: pal_off + i * 4 + 4]
            palette.append((r, g, b))

    xor_off = pal_off + (len(palette) * 4 if palette else 0)
    row_xor = ((w * bpp + 31) // 32) * 4
    xor_size = row_xor * h
    row_mask = ((w + 31) // 32) * 4
    mask_off = (xor_off + xor_size) if doubled else None

    out = bytearray(w * h * 4)
    for y in range(h):
        sy = h - 1 - y          # DIB 自下而上
        for x in range(w):
            if bpp == 32:
                o = xor_off + sy * row_xor + x * 4
                b, g, r, a = data[o:o + 4]
                if a == 0 and (r or g or b):
                    pass
            elif bpp == 8:
                idx = data[xor_off + sy * row_xor + x]
                r, g, b = palette[idx] if idx < len(palette) else (0, 0, 0)
                a = 255
            elif bpp == 4:
                byte = data[xor_off + sy * row_xor + (x // 2)]
                idx = (byte >> 4) if x % 2 == 0 else (byte & 0xF)
                r, g, b = palette[idx] if idx < len(palette) else (0, 0, 0)
                a = 255
            elif bpp == 1:
                byte = data[xor_off + sy * row_xor + (x // 8)]
                bit = (byte >> (7 - (x % 8))) & 1
                r, g, b = (255, 255, 255) if bit else (0, 0, 0)
                a = 255
            else:
                r = g = b = 0
                a = 255

            # AND 掩码：白(1)=透明
            if mask_off is not None:
                mb = data[mask_off + sy * row_mask + (x // 8)]
                if (mb >> (7 - (x % 8))) & 1:
                    a = 0
            elif bpp <= 8:
                # 没有独立掩码（非 doubled）时，按调色板里是否有「透明色」兜底
                pass

            o = (y * w + x) * 4
            out[o:o + 4] = bytes((r, g, b, a))
    return w, h, bytes(out)


def ani_frames(path):
    """从 .ani 里取出每个 icon 图元的 (w,h,rgba,hotspot)。"""
    d = open(path, "rb").read()
    assert d[:4] == b"RIFF" and d[8:12] == b"ACON", "not a .ani"

    def chunks(buf, start, end):
        p = start
        while p + 8 <= end:
            cid = buf[p:p + 4]
            csz = struct.unpack_from("<I", buf, p + 4)[0]
            yield cid, p + 8, csz
            p += 8 + csz + (csz & 1)

    anih = None
    frames = []
    for cid, off, sz in chunks(d, 12, len(d)):
        if cid == b"anih":
            vals = struct.unpack_from("<9I", d, off)
            anih = vals
        elif cid == b"LIST":
            if d[off:off + 4] == b"fram":
                for c2, o2, s2 in chunks(d, off + 4, off + sz):
                    if c2 == b"icon":
                        frames.append((o2, s2))
    return anih, frames


def decode_icon(d, off, size):
    """icon 块内容可能是 ICO 头 + DIB，也可能直接是 DIB。
    注意：不要相信 ICO 目录项里的宽高/位深，一律以 DIB 头为准。"""
    blob = d[off:off + size]
    if len(blob) >= 6:
        reserved, typ, count = struct.unpack_from("<HHH", blob, 0)
        if reserved == 0 and typ in (1, 2) and count >= 1:
            entry = blob[6:6 + 16]
            _bw, _bh, _ncol, _res, hotx, hoty, _isize, ioff = struct.unpack_from(
                "<BBBBHHII", entry)
            # 从 DIB 头读出真实位深与尺寸
            biSize, biW, biH, biPlanes, biBit, biComp = struct.unpack_from(
                "<IiiHHI", blob, ioff)
            doubled = (biH == (abs(biH) // 2) * 2) and biH > 0
            h = biH // 2 if doubled else abs(biH)
            res = _decode_dib(blob, ioff, biW, h, biBit, doubled)
            return res, (hotx, hoty)
    r = parse_ico_blob(blob, 0)
    return (r, (0, 0)) if r else (None, None)


if __name__ == "__main__":
    import sys
    src = sys.argv[1] if len(sys.argv) > 1 else None
    if not src:
        print("用法: python ani_parse.py 某光标主题.ani [输出精灵图.png]")
        sys.exit(1)
    anih, frames = ani_frames(src)
    print("anih:", anih)
    print("帧数:", len(frames))
    outs = []
    hot = (0, 0)
    for i, (o, s) in enumerate(frames):
        r, hot = decode_icon(open(src, "rb").read(), o, s)
        if r is None:
            print(" 帧%d 解析失败" % i)
            continue
        w, h, rgba = r
        im = Image.frombytes("RGBA", (w, h), rgba)
        outs.append(im)
        if i < 3:
            print(" 帧%d %dx%d hotspot=%s" % (i, w, h, hot))
    print("解析成功", len(outs), "帧")
    if outs:
        w, h = outs[0].size
        sheet = Image.new("RGBA", (w * len(outs), h), (0, 0, 0, 0))
        for i, im in enumerate(outs):
            sheet.paste(im, (i * w, 0))
        sheet.save(sys.argv[2] if len(sys.argv) > 2 else "cursor_sheet.png")
        print("已写出精灵图", sheet.size, "hotspot =", hot)
