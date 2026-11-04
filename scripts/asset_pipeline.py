"""
资产属性批量导出流水线（IoStore → Legacy → JSON → CSV）

三个环节（都调用现成工具，不自研二进制解析）：
  1) `retoc to-legacy`：IoStore(.utoc/.ucas) → 标准 legacy `.uasset` + `.uexp`（带头部）
  2) `UAssetGUI tojson`：`.uasset` → UAssetAPI 的完整 JSON（NameMap/Imports/Exports/属性树）
  3) 本脚本：解析 JSON → 结构化 CSV

为什么之前做不到：FModelCLI 只导出**无头部的 IoStore chunk**，
UAssetGUI 不认；而 `retoc` 能补出头部 → UAssetGUI 就能解析 → 拿到**完整属性值**。

用法：
  python asset_pipeline.py <类别> [--filter 子串] [--version UE5_6]
  类别: st | wbp | bp | da | mass | custom
"""
import os, re, sys, csv, json, glob, shutil, subprocess, collections

RETOC = r"D:\FengSha_UI_Upgrade\tools\retoc\retoc.exe"
UASSETGUI = r"D:\FengSha_UI_Upgrade\tools\UAssetGUI.exe"
PAKS = r"D:\STEAM\steamapps\common\mo\MOProject\Content\Paks"
AES = "0xcf6e4b651d5b94bb234cc485b9977ca6ff1467ecdb52d7a7c1047b6749f5398b"
WORK = r"D:\ai\2026-10-13-11-01-31\work\MOProject-FullReverse"
OUTD = r"D:\源代码\MOProject_FullReverse"

CATS = {
    "st":   ("MOMassStateTree", os.path.join(OUTD, "01_MassEntity", "StateTree资产清单.csv")),
    "mass": ("MOMassEntity",    os.path.join(OUTD, "01_MassEntity", "Mass实体配置属性.csv")),
    "wbp":  ("MO/UI/Blueprint", os.path.join(OUTD, "03_Assets", "Widget蓝图清单.csv")),
    "bp":   ("MO/GamePlay",     os.path.join(OUTD, "03_Assets", "蓝图清单.csv")),
    "da":   ("MO/Config",       os.path.join(OUTD, "03_Assets", "DataAsset属性.csv")),
}

def run(cmd, timeout=1800):
    print("  $ " + " ".join('"%s"' % c if " " in c else c for c in cmd))
    r = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=timeout)
    tail = (r.stdout or "").strip().split("\n")[-3:]
    for t in tail:
        print("    " + t)
    if r.returncode != 0:
        print("    !! 退出码 %d" % r.returncode)
    return r.returncode

def flatten(node, prefix="", out=None, depth=0):
    """把 UAssetAPI 的属性树压成 路径=值 的列表"""
    if out is None:
        out = []
    if depth > 12:
        return out
    if isinstance(node, dict):
        # 属性节点常见形态： {"$type":"...","Name":"X","Value":...}
        nm = node.get("Name")
        if nm and "Value" in node:
            key = prefix + ("." if prefix else "") + str(nm)
            v = node["Value"]
            if isinstance(v, (str, int, float, bool)) or v is None:
                out.append((key, v))
            elif isinstance(v, dict):
                # 结构体/对象：可能含 ObjectName / StructType
                on = v.get("ObjectName") or v.get("StructType") or v.get("$type")
                if on:
                    out.append((key, on))
                flatten(v, key, out, depth + 1)
            elif isinstance(v, list):
                for i, item in enumerate(v):
                    flatten(item, "%s[%d]" % (key, i), out, depth + 1)
            return out
        for k, v in node.items():
            if k in ("$type", "Data", "Extras", "CustomVersionContainer", "Generations"):
                if k == "Data":
                    flatten(v, prefix, out, depth + 1)
                continue
            if isinstance(v, (dict, list)):
                flatten(v, prefix + ("." if prefix else "") + k, out, depth + 1)
            elif isinstance(v, (str, int, float, bool)) and k in (
                    "ObjectName", "StructType", "ArrayType", "ClassIndex", "SuperIndex"):
                out.append((prefix + "." + k, v))
    elif isinstance(node, list):
        for i, item in enumerate(node):
            flatten(item, "%s[%d]" % (prefix, i), out, depth + 1)
    return out

def parse_json(p):
    """返回 (导出对象名列表, 引用类名列表, 任务/条件/求值器类名, 名称表)"""
    try:
        d = json.load(open(p, encoding="utf-8"))
    except Exception:
        return None, [], [], []
    names = [str(x) for x in (d.get("NameMap") or [])]
    exports = d.get("Exports") or []
    objnames = [e.get("ObjectName", "") for e in exports if isinstance(e, dict)]
    imports = [i.get("ObjectName", "") for i in (d.get("Imports") or []) if isinstance(i, dict)]
    # 引用到的类（Import 里以 /Script/ 开头的包名 + 类名）
    refs = []
    for i in (d.get("Imports") or []):
        if not isinstance(i, dict):
            continue
        on = i.get("ObjectName") or ""
        cp = i.get("ClassPackage") or ""
        if on.startswith("/Script/"):
            refs.append(on)
        elif on and not on.startswith("Default__"):
            refs.append(on)
    # 任务/条件/求值器（从名称表里挑）
    pat = re.compile(r"(Task|Condition|Conditions|Evaluator|Consideration|Schema)$")
    st = [x for x in names if pat.search(x)]
    return objnames, refs, st, names

def main():
    if len(sys.argv) < 2 or sys.argv[1] not in CATS:
        print("用法: python asset_pipeline.py {%s}" % "|".join(CATS))
        return
    cat = sys.argv[1]
    filt, outcsv = CATS[cat]
    if "--filter" in sys.argv:
        filt = sys.argv[sys.argv.index("--filter") + 1]
    ver = "UE5_6"
    if "--version" in sys.argv:
        ver = sys.argv[sys.argv.index("--version") + 1]

    legacy = os.path.join(WORK, "legacy_" + cat)
    jsond = os.path.join(WORK, "json_" + cat)
    for d in (legacy, jsond):
        if os.path.isdir(d):
            shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d, exist_ok=True)

    print("=== 1/3 retoc to-legacy（filter=%s）===" % filt)
    run([RETOC, "-a", AES, "to-legacy", "--version", ver, "--no-shaders",
         "-f", filt, PAKS, legacy])

    uas = sorted(glob.glob(os.path.join(legacy, "**", "*.uasset"), recursive=True))
    print("  legacy .uasset: %d" % len(uas))
    if not uas:
        print("!! 没有产出，检查 filter")
        return

    print("=== 2/3 UAssetGUI tojson ===")
    ok = 0
    for i, p in enumerate(uas):
        jp = os.path.join(jsond, os.path.basename(p)[:-7] + ".json")
        cmd = [UASSETGUI, "tojson", p, jp, "VER_" + ver]
        try:
            subprocess.run(cmd, capture_output=True, timeout=180,
                           cwd=os.path.dirname(UASSETGUI))
        except Exception:
            continue
        if os.path.exists(jp):
            ok += 1
        if (i + 1) % 100 == 0:
            print("   %d/%d 已转 %d" % (i + 1, len(uas), ok))
    print("  JSON 产出: %d / %d" % (ok, len(uas)))

    print("=== 3/3 解析 JSON → CSV ===")
    rows = []
    for p in sorted(glob.glob(os.path.join(jsond, "*.json"))):
        base = os.path.basename(p)[:-5]
        objnames, refs, st, names = parse_json(p)
        if objnames is None:
            continue
        seen = set()
        refs2 = [x for x in refs if not (x in seen or seen.add(x))]
        rows.append({
            "资产": base,
            "导出对象数": len(objnames),
            "导出对象": " ; ".join(objnames[:30]),
            "引用数": len(refs2),
            "引用类/包": " ; ".join(refs2[:40]),
            "任务条件求值器数": len(st),
            "任务条件求值器": " ; ".join(st[:40]),
            "名称表条目数": len(names),
        })
    os.makedirs(os.path.dirname(outcsv), exist_ok=True)
    with open(outcsv, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["资产", "导出对象数", "导出对象", "引用数", "引用类/包",
                                          "任务条件求值器数", "任务条件求值器", "名称表条目数"])
        w.writeheader(); w.writerows(rows)
    print("写出: %s (%d 行)" % (outcsv, len(rows)))
    print()
    print("=== 抽样 ===")
    for r in rows[:5]:
        print("  %-34s 导出=%d 引用=%d 任务/条件=%d" % (r["资产"], r["导出对象数"], r["引用数"], r["任务条件求值器数"]))
        print("      任务: %s" % r["任务条件求值器"][:170])

if __name__ == "__main__":
    main()
