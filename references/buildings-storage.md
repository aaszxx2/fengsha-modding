# 建筑与仓储系统速查

## 一、建筑数据链路（改建筑模组必看）

```
MOInteractiveActorConfig (359 行, ConfigID)
   ├─ BpResPath  ──(负数导入索引→ Imports[|n|-1])──▶  BP_Building_XXX_C 蓝图
   │       蓝图 SCS 组件树见 data/building_components.csv（359 BP / 11,422 组件）
   ├─ InteractiveActorUICfgID ──▶ MOInteractiveActorUIConfig（UI 文案/图标）
   └─ 仓库文案：每个建筑蓝图各自引用 ST_BuildingStorage_NN（data/building_storage_text_map.csv）
```

改建造条件/解锁 → 改 `MOInteractiveActorConfig` 的相关字段（用
`data/datatable_dict.csv` 查该表字段；注意 `SubBuildingType` 全表都是 None，没在用）。

## 二、存储组件全景（data/storage_all_types.csv，96 行）

| 分类 | 建筑 | 组件 |
|---|---|---|
| 物资/粮食/军械仓库 | 辎重库·粮仓·军械库 | `WarehouseStorage` |
| 药品仓库 | 医庐 | `HospitalStorage` |
| 祭祀仓库 | 国社 | `ConsumeRitualStorage`（消耗型） |
| 乡亭仓库 | 乡亭 | `PoliceDepartmentStorage` |
| 上贡仓库 | 中军帐 | `ConsumeTitleUpgradeStorage` |
| 食物/燃料/水/粪池 | 民居·伙房·水井 | `ConsumeFood/Fuel/WaterStorage` |
| 采集仓库/矿脉/尸体/礼品箱 | 采集场·BP_Source_*·BP_Corpse_* | `IdleStorage` |
| 建造材料 | 各建筑 | `MaterialStorage` |

组件分布：IdleStorage 40 建筑、MaterialStorage 18、ConsumeFuelStorage 12、
WarehouseStorage 6。最常见公共组件：`BuildingModularConstruct`(239)/`MOConstruct`(216)/
`Bounds`/`Foundation`(各 156)/`MiniMapMark`(155)。

## 三、仓储建筑基准容量（data/storage_buildings.csv）

| 建筑 | ConfigID | 蓝图 | 容量 |
|---|---|---|---|
| 辎重库 | 2 / 40022 / 40023 | ZiZhong_LV1/2/3 | **1500 / 2500 / 4000** |
| 辎重库(旧) | 40024 | Storehouse | 2000 |
| 粮仓 | 3 / 40032 / 40033 | LiangCang_LV1/2/3 | **1500 / 2500 / 4000** |
| 军械库 | 71 / 90071 | Armoury | 4000 |
| 货栈 | 37 | SupplyDepot | 500 |
| 教学建筑 | 90002 / 90003 | *_T | 继承 Base 蓝图 |

做"仓储扩容"类模组时**用这张表做基准**，别把封口后的值当默认值
（模组升级场景的坑：容量被压低后建筑升级，增量加法会永久损失容量——
正确做法是查表恢复基准，参考 Quota 模组的 `config_capacities` + `BaseCap` 逻辑）。

## 四、建筑布局导出/导入（FengShaBlueprint 模板）

`templates/示例模组_FengShaBlueprint/`：Ctrl+B 导出 / Ctrl+Shift+B 导入，
按 ConfigID + 相对坐标序列化建筑布局。要迁移/分享城建、做蓝图系统，以此为底。

## 五、改建筑外观/内容

- 建筑视觉是 **SM_* 静态网格 + Decal + MI_ 材质**（无骨骼，见 new-menke-guide.md）
- 新建筑走 BPModLoaderMod 蓝图模组路线（mod-feasibility.md）；
  数据侧新条目（ConfigID/文案/UI）在 `MOInteractiveActorConfig` + StringTable 加行
- ⚠️ 33 个 `ST_BuildingName/Storage_NN` 是建造菜单主建筑集合（不含城墙装饰），
  但键由蓝图运行时拼接，新增建筑要自建键并在蓝图中引用
