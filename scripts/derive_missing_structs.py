# -*- coding: utf-8 -*-
"""
从 cfg_json（UAssetAPI JSON）推导「结构体不存在于 UHT dump」的 5 张 DataTable 的字段定义。
按 17_DataTable数据字典_汇总.csv 里 字段数=0 的行定位，补进字典并更新汇总。
"""
import csv, io, json, os

CFG = r"E:\fs_mod\cfg_json"
OUT_DICT = r"D:\源代码\MOProject_FullReverse\17_DataTable数据字典.csv"
OUT_SUMM = r"D:\源代码\MOProject_FullReverse\17_DataTable数据字典_汇总.csv"

TYPE_MAP = {
    "IntPropertyData": "int32", "Int64PropertyData": "int64",
    "FloatPropertyData": "float", "DoublePropertyData": "double",
    "BoolPropertyData": "bool", "StrPropertyData": "FString",
    "NamePropertyData": "FName", "TextPropertyData": "FText",
    "ObjectPropertyData": "ObjectRef", "InterfacePropertyData": "InterfaceRef",
    "EnumPropertyData": "enum",
}

def norm_type(p):
    t = (p.get("$type") or "").split(",")[0].split(".")[-1]
    if t == "ArrayPropertyData":
        return "TArray<%s>" % (p.get("ValueType") or "?")
    if t == "StructPropertyData":
        return p.get("StructType") or "?"
    if t in ("EnumPropertyData", "BytePropertyData"):
        en = p.get("EnumName") or ""
        return en if en else ("enum" if t == "EnumPropertyData" else "uint8")
    return TYPE_MAP.get(t, t)

def collect(path):
    d = json.load(open(path, encoding="utf-8"))
    fields, order, nrows = {}, [], 0
    for e in d.get("Exports") or []:
        t = e.get("Table")
        if not isinstance(t, dict):
            continue
        data = t.get("Data") or []
        nrows = max(nrows, len(data))
        for row in data:
            for p in (row.get("Value") or []):
                n = p.get("Name")
                if not n or n in fields:
                    continue
                fields[n] = norm_type(p)
                order.append(n)
    return [(n, fields[n]) for n in order], nrows

def find_json(table_name):
    for cand in (table_name + ".json", "DT_" + table_name + ".json",
                 table_name[3:] + ".json" if table_name.startswith("DT_") else None):
        if cand and os.path.exists(os.path.join(CFG, cand)):
            return os.path.join(CFG, cand)
    return None

# ---- 读汇总，找字段数=0 的表 ----
sum_rows = list(csv.DictReader(open(OUT_SUMM, encoding="utf-8-sig")))
sum_cols = list(sum_rows[0].keys())
missing = [r for r in sum_rows if r.get("字段数") in ("0", "")]
print("缺失表:", [r["表"] for r in missing])

dict_rows = list(csv.DictReader(open(OUT_DICT, encoding="utf-8-sig")))
dict_cols = list(dict_rows[0].keys())
new_rows = []

for r in missing:
    tname = r["表"]
    p = find_json(tname)
    if not p:
        print("  ✘ 找不到 JSON:", tname)
        continue
    fields, nrows = collect(p)
    if not fields:
        print("  ✘ 无字段:", tname)
        continue
    for f, ty in fields:
        row = {c: "" for c in dict_cols}
        row["表"] = tname
        row["行结构"] = r["行结构"]
        row["字段"] = f
        row["类型"] = ty
        new_rows.append(row)
    r["字段数"] = str(len(fields))
    r["结构体已解析"] = "是(JSON推导)"
    if nrows:
        r["行数"] = str(nrows)
    print("  ✔ %-40s %2d 字段  %3d 行  (%s)" % (tname, len(fields), nrows, os.path.basename(p)))

if new_rows:
    with io.open(OUT_DICT, "a", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=dict_cols)
        w.writerows(new_rows)
with io.open(OUT_SUMM, "w", encoding="utf-8-sig", newline="") as f:
    w = csv.DictWriter(f, fieldnames=sum_cols)
    w.writeheader(); w.writerows(sum_rows)

# ---- 终验 ----
dict_rows = list(csv.DictReader(open(OUT_DICT, encoding="utf-8-sig")))
tabs = {}
for row in dict_rows:
    tabs[row["表"]] = tabs.get(row["表"], 0) + 1
sr = list(csv.DictReader(open(OUT_SUMM, encoding="utf-8-sig")))
ok = sum(1 for r in sr if r["表"] in tabs and int(r["字段数"] or 0) > 0)
print("\n终验：字典 %d 张表 / %d 字段行；汇总有字段 %d / %d" % (len(tabs), len(dict_rows), ok, len(sr)))
