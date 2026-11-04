"""
把 FengShaFullDump 导出的 DataTable JSON 转成 Excel 可直接打开的一行一行 CSV。

用法：python export_datatable_csv.py
输出：D:\\源代码\\MOProject_FullReverse\\07_DataTable全量数据\\
        _索引.csv            每张表的元信息
        <表名>.csv           一行一个 rowKey，列 = 安全字段
"""
import os, re, csv, json, glob, sys

DUMP = r"D:\STEAM\steamapps\common\mo\MOProject\Binaries\Win64\ue4ss\Mods\FengShaFullDump\dumps\datatables"
OUT = r"D:\源代码\MOProject_FullReverse\07_DataTable全量数据"

def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)

def safe_name(s):
    return re.sub(r'[\\/:*?"<>|]', "_", s)

def cell(v):
    """把嵌套的 list/dict 压成一行文本，方便 Excel 看"""
    if v is None:
        return ""
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float, str)):
        return v
    if isinstance(v, list):
        return " ; ".join(str(cell(x)) for x in v)
    if isinstance(v, dict):
        return " ".join("%s=%s" % (k, cell(x)) for k, x in v.items())
    return str(v)

def main():
    os.makedirs(OUT, exist_ok=True)
    jobs = [(os.path.join(DUMP, "*.json"), OUT, "安全字段"),
            (os.path.join(os.path.dirname(DUMP), "deep", "*.json"),
             os.path.join(OUT, "deep"), "深读")]
    for pattern, outdir, label in jobs:
        files = sorted(glob.glob(pattern))
        if not files:
            print("[%s] 无文件：%s" % (label, pattern))
            continue
        os.makedirs(outdir, exist_ok=True)
        index_rows = []
        total_rows = total_nz = 0
        for p in files:
            base = os.path.basename(p)[:-5]
            try:
                d = load(p)
            except Exception as e:
                print("跳过损坏文件", base, e)
                continue
            rows = d.get("rows")
            if not isinstance(rows, dict):
                continue
            fields = d.get("fields") or d.get("specs") or []
            cols = list(fields)
            seen = set(cols)
            for v in rows.values():
                if isinstance(v, dict):
                    for k in v:
                        if k not in seen:
                            seen.add(k); cols.append(k)

            nz = 0
            for v in rows.values():
                if isinstance(v, dict) and any(x is not None for x in v.values()):
                    nz += 1
            total_rows += len(rows); total_nz += nz

            out_csv = os.path.join(outdir, safe_name(base) + ".csv")
            with open(out_csv, "w", encoding="utf-8-sig", newline="") as f:
                w = csv.writer(f)
                w.writerow(["RowKey"] + cols)
                for k, v in rows.items():
                    v = v if isinstance(v, dict) else {}
                    w.writerow([k] + [cell(v.get(c)) for c in cols])

            index_rows.append({
                "表名": base,
                "资产路径": (d.get("table") or "").replace("DataTable ", ""),
                "行结构体": (d.get("rowStruct") or "").split(".")[-1],
                "行数": len(rows),
                "有值行数": nz,
                "字段数": len(fields),
                "字段列表": ",".join(fields),
                "数据版本": d.get("v", 1),
            })

        index_rows.sort(key=lambda r: -r["行数"])
        ip = os.path.join(outdir, "_索引.csv")
        with open(ip, "w", encoding="utf-8-sig", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["表名", "资产路径", "行结构体", "行数",
                                              "有值行数", "字段数", "字段列表", "数据版本"])
            w.writeheader()
            w.writerows(index_rows)

        print("[%s] 表数=%d  总行数=%d  有值行数=%d (%.1f%%)  -> %s"
              % (label, len(index_rows), total_rows, total_nz,
                 100.0 * total_nz / max(total_rows, 1), outdir))

if __name__ == "__main__":
    main()
