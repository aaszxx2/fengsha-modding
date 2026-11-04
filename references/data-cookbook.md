# 数据查询手册（data-cookbook）

所有 CSV 带 UTF-8 BOM，Excel 直接打开，Python 用 `encoding="utf-8-sig"`。

## 一、每张表的列

| 文件 | 列 |
|---|---|
| `datatable_dict.csv` | 表, 行结构, 字段, 类型, 容器, SaveGame |
| `datatable_dict_summary.csv` | 表, 行结构, 行数, 字段数, 结构体已解析 |
| `struct_dict.csv` | 结构体, 字段, 类型, 容器, SaveGame, 源文件, 基类 |
| `enum_dict.csv` | 枚举, 取值, 数值, 底层类型, 中文名 |
| `enum_cn.csv` | 来源表, 枚举值, 中文名 |
| `enum_field_usage.csv` | 表, 字段, 枚举, 数值, 取值, 出现行数, 中文名 |
| `stringtable_st_all.csv` | 键, 命名空间, 文本 |
| `ui_text_index.csv` | 前缀, 序号, 文本, 疑似枚举, 绑定置信度 |
| `ui_text_refs.csv` | 键, 文本, 引用资源数, 资源引用 |
| `storage_buildings.csv` | 建筑名, ConfigID, 行键, 建筑蓝图, 仓储组件, 仓库文案键, 仓库中文, 默认容量, 文案来源 |
| `storage_all_types.csv` | 96 行全类型存储建筑（含医庐/国社/乡亭/民居/矿脉/尸体） |
| `consume_storage.csv` | 建筑蓝图, 组件节点, Capacity, ReserveMax/Min/Default, bAllowUserSetReserve … |
| `building_components.csv` | 建筑蓝图, 组件数, 逻辑组件数, 全组件(分号分隔) |
| `fk_relations.csv` | 源表, 源字段, 目标表, 目标字段, 匹配率, lift, 置信度 |

## 二、常用查询配方

```python
import csv
def load(name):  # data/ 目录下
    return list(csv.DictReader(open(f"data/{name}", encoding="utf-8-sig")))

# 1) 某张表有哪些字段
[r for r in load("datatable_dict.csv") if r["表"] == "MOInteractiveActorConfig"]

# 2) 某枚举的全部取值 + 中文
[r for r in load("enum_dict.csv") if r["枚举"] == "EMOStorageFlag"]

# 3) 某结构体字段（含 SaveGame 线索）
[r for r in load("struct_dict.csv") if r["结构体"] == "FWarehouseRemoteItemEntry"]

# 4) 所有会进存档的字段（做存档相关模组的索引）
[r for r in load("struct_dict.csv") if r["SaveGame"] == "是"]

# 5) 某建筑有哪些组件
[r for r in load("building_components.csv") if r["建筑蓝图"] == "BP_Building_ZiZhong_LV1"]

# 6) 搜 UI 文案
[r for r in load("stringtable_st_all.csv") if "辎重" in r["文本"]]
```

shell 下更快：`grep ",EMOStorageFlag," data/enum_dict.csv`。

## 三、已确认的关键事实（别再猜）

### ID 与容量
- 仓储建筑 ConfigID：辎重库 2/40022/40023（LV1-3）+ 40024(旧 Storehouse)；粮仓 3/40032/40033；
  军械库 71/90071；货栈 37；医庐 35（容量 100）；乡亭 60；国社 38；教学 _T 90002/90003
- **容量升级曲线：辎重库/粮仓 LV1 1500 → LV2 2500 → LV3 4000**；军械库 4000；货栈 500

### 组件命名
- 仓储组件的**属性名是 `WarehouseStorage`**（不是 WarehouseStorageComponent）
- `BpResPath` 在配置表 JSON 里是**负数导入索引**（如 -453），
  解析：`Imports[|n|-1].ObjectName` → `BP_Building_XXX_C`

### 枚举
- `EMOStorageFlag` 20 值（食物/燃料/独轮车/牛车/水井/粪肥/木材/尸体/药材/农田肥料/
  农田用水/农田收获/补给/通用/谷物/军械/石料/高级/医馆/弹药仓储）——决定建筑能存哪类货
- `ELogisticsStationMode` 只有 SendOnly / ReceiveOnly / Both（**没有 Disabled**）
- 84% 枚举没有中文名是**数据里本来就没有**（内部状态机值，UI 不展示），别浪费时间去挖

### 文案
- `ST_BuildingStorage_NN`（33 条）与 `ST_BuildingName_NN` 序号平行，但**每个建筑蓝图各引各的键**，
  序号不是枚举值；`_19 肥料仓库` 是孤儿键（全库零引用）
- `EMOGameViewType` 与 `ST_GameView_N` 序号错位（低置信），别直接绑定

## 四、数据溯源与可信度

- 全部来自 UHT 头文件解析、UAssetGUI JSON、BP 字节码反汇编、资产二进制扫描与 retoc 解包，
  **无编造**；推断项都标了置信度（见 `fk_relations.csv`、`ui_text_index.csv`）
- 枚举字段"实际取值"比"定义取值"更可信：某字段 219 行全是 None = 游戏从没用过它
  （如 `MOInteractiveActorConfig.SubBuildingType` 全 None）

## 五、本地化（Game_zh-Hans.csv 等 14 语言，不在本 skill，在完整逆向库 11_Localization/）

- 两条查找路径：`{RowKey}_ItemName` 命名键（物资名）；**32 位 hex GUID 键**（*TextConfig 表的
  FText，如 MOSoldierTypeTextConfig → 戈兵/伐木工）
- 想要完整 locres 中文映射：把游戏 `Content/Localization/Game/zh-Hans.csv` 拖给 AI 即可
