# 改表模组流水线（table mod pipeline）

改 DataTable 数值是烽沙模组里**最稳的一条路**：不碰运行时、不碰 UE4SS，
打包成 `_P` pak 放进 `~mods` 就生效。全流程已实测跑通（样板见
`templates/示例模组_FengShaBalanceDemo/`，改的是弓箭手 BattleAttribute）。

## 一、六步闭环

`scripts/asset_mod_roundtrip.sh` 已封装全部命令（首次使用先改脚本头部的
`RT / UAG / PAKS` 三个路径指向你自己的工具与游戏目录）：

```bash
# 1) 解包：按名称过滤，从 pakchunk0_s2 提取 legacy 资产到 ./work
./asset_mod_roundtrip.sh extract "MOBattleAttribute"

# 2) uasset → JSON（UAssetGUI，版本 UE5_6，usmap 名 Game）
./asset_mod_roundtrip.sh tojson "MOProject/Content/MO/XXX/MOBattleAttribute.uasset"

# 3) 用任何编辑器/脚本改 _edit.json 里的数值（保留 JSON 结构不变！）

# 4) JSON → uasset
./asset_mod_roundtrip.sh fromjson "MOProject/Content/MO/XXX/MOBattleAttribute.uasset"

# 5) 打包成 <名字>_P.{utoc,ucas,pak}
./asset_mod_roundtrip.sh pack MyBalance

# 6) 校验 + 安装到 ~mods/
./asset_mod_roundtrip.sh verify MyBalance
./asset_mod_roundtrip.sh install MyBalance
```

手工等价命令（理解原理用）：

```bash
# 解包（注意 -a 传 key，--version UE5_6）
retoc.exe -a "<AES key>" to-legacy "<游戏>/Content/Paks/pakchunk0_s2-Windows.utoc" ./work -f "MOBattleAttribute" --version UE5_6
# JSON 互转
UAssetGUI.exe tojson   <in.uasset>  <out.json>  VER_UE5_6 Game
UAssetGUI.exe fromjson <in.json>    <out.uasset> VER_UE5_6 Game
# 打包（注意输出名必须以 _P 结尾才会被挂载为补丁）
retoc.exe build ./work "<输出>/MyBalance_P" --version UE5_6
```

## 二、JSON 结构速查（UAssetAPI 格式）

```
顶层: NameMap / Imports / Exports
DataTable 的数据在 Exports[i].Table.Data[]：
  每行 { "Name": "RowKey", "StructType": "<行结构体名>", "Value": [属性...] }
每个属性: { "Name": "字段名", "$type": "IntPropertyData,...", "Value": ... }
```

类型映射（改值时保持 `$type` 不动，只改 `Value`）：
`IntPropertyData`=int32 · `FloatPropertyData`=float · `BoolPropertyData`=bool ·
`StrPropertyData`=FString · `NamePropertyData`=FName · `TextPropertyData`=FText（值是
 CultureInvariantString 或 32 位 hex 的 locres key）· `StructPropertyData`（带 `StructType`）·
`ArrayPropertyData`（带 `ValueType`）· `EnumPropertyData`（带 `EnumName`）。

## 三、保命规则

- **只改 Value，不加不减属性**。要新增行/字段，先确认行结构体允许（用
  `data/struct_dict.csv` 查字段是否 SaveGame/编辑器可见）。
- 改前备份原 JSON；改完 diff 一遍再回写。
- FText 值是 32 位 hex 时它是 **locres key**，改文案要改 locres 或换成
  CultureInvariantString（参考 `data/stringtable_st_all.csv` 找现有键值）。
- `TextPropertyData` 的 GUID key 可在游戏本地化文件里查到中文——这是枚举中文名的来源。
- `_P` 后缀必须有；同名旧包会互相冲突，先删旧的。

## 四、已知可直接下手的表

| 表 | 内容 | 模组点子 |
|---|---|---|
| `MOBattleAttribute`（146 列） | 士兵/门客战斗属性，带 GameplayTag | 数值平衡（BalanceDemo 已做） |
| `MOLootPoolConfig` / `MOLootColorRankConfig` | 掉落池 76 行 + 品阶 | 掉落修改 |
| `MOInteractiveActorConfig` | 359 建筑配置（ID/BpResPath/描述） | 建造条件、解锁 |
| `MOInteractiveActorUIConfig` | 建筑 UI（106 行） | 界面调整 |
| `MOBuildingUpgradeEffectTextConfig` | 建筑升级效果文本 | 升级收益改动配套 |
| 生产/配方类表（在 `datatable_dict.csv` 里按名搜 Produce/Recipe/Fuel） | 产出与消耗 | 产能调整 |

查某张表的字段：`grep ",<表名>," data/datatable_dict.csv` 或看
`data/datatable_dict_summary.csv`（汇总：每表行数/字段数/行结构体名）。

## 五、UI 文案 / 汉化

StringTable 资产的 .uexp 格式极简，`scripts/parse_stringtable.py` 可读可写回：

```
<6字节头> FString Namespace("GameTable") / int32 条目数 / 重复 {FString Key, FString Value}
FString: Len>0 → ASCII；Len<0 → UTF-16LE
```

- `data/stringtable_st_all.csv`：796 条现成文案（ST_Mission 95 / ST_WorkerStatus 68 /
  ST_BuildingName 33 / ST_BuildingStorage 33 …）
- 改完写回 .uexp → retoc 打包即可，**不需要** UAssetGUI
- ⚠️ `ST_BuildingStorage_NN` 每个建筑蓝图各引用自己那一条，序号不是枚举，别当全局 ID 用

## 六、验证清单

1. `verify` 步骤通过（容器合法）
2. 进游戏：数值变化可见（BalanceDemo 是弓箭手攻击力 ×2）
3. 若没生效：确认 `_P` 包在 `~mods/`、没有同名旧包、改的确实是游戏加载的那张表
   （用 `data/datatable_dict.csv` 里的行结构体名 grep 游戏日志确认）
