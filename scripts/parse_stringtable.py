# -*- coding: utf-8 -*-
"""直接解析 UE StringTable 的 .uexp（不需要 UAssetGUI / retoc 转换）。

格式（实测 2026-10-19）
    <6 字节头>  FString Namespace("GameTable")
    int32       条目数
    重复 N 次：  FString Key, FString Value

FString 编码：int32 Len
    Len > 0 → 后面 Len 字节 ASCII（含结尾 \\0）
    Len < 0 → 后面 -Len*2 字节 UTF-16LE（含结尾 \\0）

输出
    D:\\源代码\\MOProject_FullReverse\\26_StringTable_ST_All.csv
"""
import csv, io, os, struct, sys

SRC_DIR = r"D:\ai\2026-10-13-11-01-31\work\fengsha-re\extracted\MOProject\Content\MO\StringTables"
OUT = r"D:\源代码\MOProject_FullReverse\26_StringTable_ST_All.csv"


def read_fstring(d, off):
    if off + 4 > len(d):
        return None, off
    (n,) = struct.unpack_from("<i", d, off)
    off += 4
    if n == 0:
        return "", off
    if n > 0:
        raw = d[off:off + n]
        off += n
        return raw.rstrip(b"\0").decode("utf-8", "replace"), off
    m = -n
    raw = d[off:off + m * 2]
    off += m * 2
    return raw.decode("utf-16-le", "replace").rstrip("\0"), off


def parse(path):
    d = open(path, "rb").read()
    # 定位命名空间：找第一个可解析的 FString
    off = 6
    ns, off = read_fstring(d, off)
    if ns is None or not ns.isprintable():
        # 兜底：从 0 开始试
        off = 0
        ns, off = read_fstring(d, off)
    (count,) = struct.unpack_from("<i", d, off)
    off += 4
    rows = []
    for _ in range(count):
        k, off = read_fstring(d, off)
        v, off = read_fstring(d, off)
        if k is None:
            break
        rows.append({"命名空间": ns, "键": k, "文本": v})
    return rows, ns, count, len(d)


def main():
    allrows = []
    for fn in sorted(os.listdir(SRC_DIR)):
        if not fn.endswith(".uexp"):
            continue
        p = os.path.join(SRC_DIR, fn)
        try:
            rows, ns, count, size = parse(p)
        except Exception as e:
            print("  X %-22s %s" % (fn, str(e)[:50]))
            continue
        print("  OK %-22s 命名空间=%-14s 声明 %4d 条，实读 %4d 条 (%d 字节)"
              % (fn, ns, count, len(rows), size))
        for r in rows:
            r["来源"] = fn[:-5]
            allrows.append(r)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with io.open(OUT, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["来源", "命名空间", "键", "文本"])
        w.writeheader()
        w.writerows(allrows)

    print("\n合计 %d 条，写出 %s" % (len(allrows), OUT))
    print("\n样例：")
    for r in allrows[:8]:
        print("  %-24s %s" % (r["键"], r["文本"][:40]))


if __name__ == "__main__":
    main()
