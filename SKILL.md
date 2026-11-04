---
name: fengsha-modding
description: 《烽沙》(MOProject, UE5.6) 模组开发知识库。当用户提到"烽沙"或 MOProject 游戏的任何 mod/模组需求时务必使用本技能——改数值/改表/掉落/配方、UE4SS Lua 脚本模组、仓储配额、消耗点调参、UI 文案汉化、新门客/新内容、建筑布局、pak 打包（retoc/UAssetGUI）、查询游戏数据（DataTable 字段/枚举/结构体/建筑组件）。即使用户只说"给烽沙做个XX模组"或"烽沙的XX数据是什么"，也应触发本技能。
---

# 烽沙模组开发（fengsha-modding）

《烽沙》(MOProject) 是 UE 5.6 城建生存游戏。本技能浓缩了对该游戏的**全量静态逆向成果**：
166 张 DataTable 全字段、6,222 个结构体、400 个枚举（2,308 取值含中文）、377 个 BP 的
K2 字节码、796 条 UI 文案、建筑组件与容量曲线，以及 6 个已实测跑通的模组模板。

## 〇、先读：四条铁律（违反必翻车）

1. **改数据表用 pak 闭环，不碰 UE4SS**（最稳）：解包 → UAssetGUI JSON → 改 → 回写 → retoc 打包 → `~mods`。机制已实测验证。
2. **UE4SS 里不要用 `FindAllOf("XXX")` 做全对象兜底**——主菜单/世界未加载时会堵死整个 Lua 线程（所有模组按键失灵）。要枚举建筑，按 BP 生成类名逐类来：`FindAllOf("BP_Building_Granary_C")`，这是实测可靠的有界扫描。
3. **UE4SS 运行时拼的 UMG 面板不一定进视口**。凡是给用户看的内容，同时落到 `dumps\*.txt` 文件，别只赌 `AddToViewport`。
4. **不要凭字段名猜语义**。先查 `data/` 里的字典 CSV；枚举字段在 UE4SS 运行时读出来全是 0，真实值要用 UAssetGUI 的 JSON 看。

## 一、环境（Tools）

| 工具 | 作用 | 获取 |
|---|---|---|
| `retoc.exe` | IoStore(.utoc/.ucas) ↔ legacy 资产互转、打包 | 开源，GitHub 搜 retoc |
| `UAssetGUI.exe` | uasset ↔ JSON 互转（**改表就靠它**） | 开源，GitHub 搜 UAssetGUI |
| `usmap` 映射 | UAssetGUI 需要，`%LOCALAPPDATA%/UAssetGUI/Mappings/Game.usmap`（config 里 `PreferredMappings = "Game"`，不带扩展名） | 用游戏头文件生成 |
| UE4SS | Lua 模组运行时，装到 `<游戏>/Binaries/Win64/ue4ss/` | 开源，GitHub UE4SS |

关键路径与常量：
```
游戏:     <Steam库>/steamapps/common/mo/MOProject
Paks:     MOProject/Content/Paks/pakchunk0_s2-Windows.utoc   (IoStore, 需 aes key)
AES key:  0xcf6e4b651d5b94bb234cc485b9977ca6ff1467ecdb52d7a7c1047b6749f5398b
pak 模组: MOProject/Content/Paks/~mods/<名字>_P.{utoc,ucas,pak}
UE4SS:    MOProject/Binaries/Win64/ue4ss/Mods/<模组名>/Scripts/main.lua
版本参数:  retoc --version UE5_6    UAssetGUI: VER_UE5_6
UHT 头文件: <游戏>/Binaries/Win64/ue4ss/UHTHeaderDump/  (装 UE4SS 后自动生成)
```

## 二、按任务路由（读对应 reference 再动手）

| 用户想做什么 | 读 | 用什么 |
|---|---|---|
| **改数值/掉落/配方/属性**（最常见） | `references/table-mod-pipeline.md` | `scripts/asset_mod_roundtrip.sh` 六步闭环；样板 `templates/示例模组_FengShaBalanceDemo` |
| **UE4SS Lua 行为模组**（快捷键/面板/内存改属性） | `references/ue4ss-lua-modding.md` | 模板 `templates/示例模组_FengShaQuota`（复杂）/ `FengShaConsume`（简单） |
| **查"某张表/枚举/结构体/建筑"的数据** | `references/data-cookbook.md` | 直接 grep `data/*.csv`，查询配方在里面 |
| **仓储/建筑/物流相关** | `references/buildings-storage.md` | 组件能力矩阵 + 容量曲线 + 33 条仓储文案 |
| **新门客/新内容/蓝图模组** | `references/new-menke-guide.md` + `references/mod-feasibility.md` | BPModLoaderMod 路线 |
| **UI 文案/汉化** | `references/table-mod-pipeline.md` §文案 | `scripts/parse_stringtable.py`（可读可写回） |
| **联机** | `references/mod-feasibility.md` | 引擎有地基、游戏层没盖楼，四阶段工程 |

## 三、data/ 数据字典（greppable，都带 UTF-8 BOM）

| 文件 | 规模 | 用途 |
|---|---|---|
| `datatable_dict.csv` | 1,239 行 / **166 表全覆盖** | 表→字段→类型（含行结构体名） |
| `struct_dict.csv` | 25,701 字段 / 6,222 结构体 | 任意结构体字段、SaveGame 标记 |
| `enum_dict.csv` | 2,308 取值 / 400 枚举 | 取值→数值→中文名 |
| `stringtable_st_all.csv` | 796 条 | UI 文案原文（键 = ST_xxx） |
| `storage_buildings.csv`（30 号） | 12 行 | 仓储建筑：ID→蓝图→组件→文案→**基准容量** |
| `storage_all_types.csv`（32 号） | 96 行 | **全部**有存储的建筑 |
| `consume_storage.csv`（33 号） | 14 行 | 消耗型组件实测值（Reserve 等） |
| `building_components.csv`（31 宽表） | 359 BP | 每个建筑的组件清单 |
| `fk_relations.csv`（23 号） | 14 条 | 表间外键（带置信度） |
| `enum_field_usage.csv`（24 号） | 959 条 | 枚举字段**实际用到的值** |

⚠️ 本地若还有游戏本体，更全的数据在 `D:\源代码\MOProject_FullReverse\`（含 188 张表的全部数据行、14 语言本地化、BP 字节码）。

## 四、改完之后

- pak 模组：装进 `~mods/`，删掉旧版本（同名 `_P` 会冲突）；游戏更新后若表结构没变可继续用
- UE4SS 模组：`mods.txt` 里 `<模组名> : 1`；注意**目录里有 `enabled.txt` 的模组无视 mods.txt 的 0**，要停用得移走目录
- 排查 UE4SS 模组没生效：先看日志有没有打出"已加载"——没有就是加载阶段挂了，不是按键绑错
