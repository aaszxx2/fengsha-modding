# scripts/

| 脚本 | 用途 |
|---|---|
| `asset_mod_roundtrip.sh` | **改表六步闭环**（extract/tojson/fromjson/pack/verify/install）。首次使用改头部 `RT/UAG/PAKS` 三个路径；内含游戏 AES key |
| `asset_pipeline.py` | 批量导出：IoStore → legacy → JSON → 结构化 CSV（类别 st/wbp/bp/da/mass） |
| `parse_stringtable.py` | StringTable .uexp 读取（可直接改造成写回，做汉化/文案模组） |
| `derive_missing_structs.py` | 从 UAssetGUI JSON 反推 DataTable 字段定义（结构体不在 UHT dump 时用） |
| `export_datatable_csv.py` | DataTable JSON → CSV 导出 |

所有脚本默认参数指向作者机器路径，用前先看头部常量。
