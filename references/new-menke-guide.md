# 新门客制作指南

> 问题：给《烽沙》做一个新门客，需要新模型吗？模型需要绑骨骼吗？
> 日期：2026-10-14（结论基于全量资产清单 23,174 项 + 79 个 Mass 实体配置实测）

---

## 一、直接回答

| 问题 | 答案 |
|------|------|
| **需要新模型吗？** | **不一定** —— 只做"数据新门客"可完全复用现有外形；要独特外形才需要新模型 |
| **模型需要绑骨骼吗？** | **不需要** —— 门客立绘是 **StaticMesh（纯静态网格，无骨骼）**；上阵单位**直接复用士兵的现成骨骼** |

**一句话**：门客的模型门槛**比想象中低很多** —— 不需要建骨骼、不需要绑蒙皮、不需要做动画。

---

## 二、门客有两种表现形态（这是关键）

### 形态 A：立绘/展示部件（`/Game/MO/Art/Character/Hero/`）

**每个门客 = 3 个 StaticMesh 部件**：

| 部件 | 路径 | 命名 |
|------|------|------|
| 身体/服装 | `Hero/Garment/<名字>/` | `SM_Hero_<名字>_Garment_01_Ins` |
| 头 | `Hero/Head/<名字>/` | `SM_Hero_<名字>_Head_01_Ins` |
| 头盔 | `Hero/Helmet/<名字>/` | `SM_Hero_<名字>_Helmet_01` |

**实测数据**：
- `Hero/` 目录下：**23 个 StaticMesh + 119 个 Texture2D + 0 个 SkeletalMesh + 0 个 Skeleton**
- 后缀 `_Ins` = **Instanced Static Mesh**（实例化静态网格）
- **✅ 确认：门客立绘完全不用骨骼**

**现有 8 套立绘**（可直接参考/复用/换贴图）：

```
DiJiJianShi（低级剑士）      GaoJiBuYi（高级布衣）
GaoJiJianShi（高级剑士）     MingJiaMenKe（名家门客）
MoTu（墨徒）                 WeiWuJi（魏无忌）
ZhaoWuYang（赵武阳）         ZhongJiJiangLing（中级将领）
（另有 GouYi 的头复用 SM_Hero_ZhongJiJiangLing_Head_01_Ins）
```

### 形态 B：上阵单位（Mass ECS 实体）

门客上阵走 Mass 系统，配置资产是 **`DA_MOMenKe*Config`（MassEntityConfigAsset）**。

实测它的关键字段：

```
SoldierType  = MenKe / MenKeNv        ← 门客（男/女）
AnimFSMType  = SoldierAnimFSM         ← ★ 用士兵的动画状态机
```

Trait 列表（11 个）：
```
MassAssortedFragmentsTrait, MassMovementTrait, MassNavigationObstacleTrait,
MassObstacleAvoidanceTrait, MassSmoothOrientationTrait, MassStateTreeTrait,
MassSteeringTrait, MOCommonAnimFSMTrait, MOEntityMovementTrait,
MOMassMenKeTrait, TestInstanceVisualizationTrait
```

**✅ 关键结论**：`AnimFSMType=SoldierAnimFSM` 说明门客**直接复用士兵的动画体系** ——
所以**不需要自己建骨骼、绑蒙皮、做动画**，套用士兵骨骼即可。

---

## 三、士兵的模型体系（门客上阵复用的就是这套）

`/Game/MO/Art/Character/Soldier/`：**42 Texture2D + 26 StaticMesh + 14 MaterialInstance + 4 SkeletalMesh**

**同一套装备有"骨骼版"和"静态版"两份**：

| 类型 | 例子 | 用途 |
|------|------|------|
| SkeletalMesh（`SK_`） | `SK_Soldier_MinFu_Garment_02` | 近处/主角，有骨骼动画 |
| StaticMesh（`SM_..._Ins`） | `SM_Soldier_MinFu_Garment_02_Ins` | 远处/大批量（ISM，性能方案） |

**共享骨骼**：`/Game/MO/Art/Character/Skeleton/SKEL_Soldier_Common_02_Ins`

**现成动画 307 条**（`AllUsedAnims` 表），如：
```
A_Life_Civilian_Neutral_Loop      A_Life_Civilian_Walk_Loop
A_Game_Soldier_ChangBing_Neu_Stand_Walk_Prudent_B_Loop_
A_Game_Soldier_DunBing_Neu_Stand_Idle_Active_Loop_01
```
`BaseIdleAnimationConfig`（38 行）按单位类型指定待机动画（民夫/民兵/难民…）。

> ⚠️ **注意**：全游戏 `SkeletalMesh` 资产**极少**（模型清单里只有 5 个：鹿/野猪/床弩车/投石车/瓦缸车）。
> 角色类的 SkeletalMesh 在 `Soldier/` 目录下（4 个）。
> **说明游戏大量依赖 StaticMesh + ISM + 材质/程序化表现**。

---

## 四、做一个新门客的完整清单

### 必改（数据层）

| # | 文件/资产 | 内容 |
|---|----------|------|
| 1 | `MOMenKeInformationConfig`（99 行） | 门客基础信息：`ID` / `NameID` / `ChannelsType`（门派）/ `RecruitableNumber`（可招募数）/ `MaxSatisfaction`（满意度上限）/ `SatisfactionRecover` / `ExtraSOOutputDaoBi` |
| 2 | `MOMenKeSkillConfig` | 技能：`ID` / `NameID` / `GroupID` / `HaloID` / `TypeValue` |
| 3 | `MOMenKeBackgroundConfig` | 背景故事 |
| 4 | `DA_MOMenKe<新名字>Config` | MassEntityConfigAsset（上阵实体配置，11 个 Trait） |
| 5 | `ST_MOMenKe`（StateTree） | 行为树（现有任务：`MOMassFindMenKeRandomMoveLocationTask` 随机走动 / `MOMassMoveToLocationTask` / `MOMassWaitTask` 等待） |

### 可选（美术层）

| # | 内容 | 需要骨骼？ |
|---|------|-----------|
| 6 | 立绘 3 个 StaticMesh（Garment / Head / Helmet） | ❌ **不需要** |
| 7 | 贴图（`T_..._D` 漫反射 / `_N` 法线 / `_ARM` 遮罩） | ❌ |
| 8 | 材质实例（`MI_...`） | ❌ |

### 现有门派（20+ 个 `DA_MOMenKe*Config`）

```
儒家(menke_ru)   道家(menke_dao)   法家(Fa)      墨家(Mo)     兵家(Bing)
农家(Nong)       华山(HuaShan01)   伏虎门(FuHuMen01/02)
江洋大盗(JiangYangDaDao01)        劫掠流民(JiELiuMin01)
慕容世家(MuRongShijia01)          道袍贼(DaoBaoZei01)  …
```

---

## 五、三条路线（按投入排序）

### 🥇 路线 1：纯数据新门客（**不需要任何模型**）
复制一个现有门客的配置，改名字/门派/数值/技能。
**投入**：改 3 张 DataTable + 1 个 Mass 配置。**立即可做**。

### 🥈 路线 2：换皮门客（**不需要骨骼**）
用现有 8 套立绘之一，换贴图（改颜色/纹样）→ 看起来是"新门客"。
**投入**：Blender 只做贴图或轻改静态网格，**不碰骨骼**。

### 🥉 路线 3：全新外形门客
- **立绘**：Blender 做 3 个 StaticMesh（Garment/Head/Helmet）→ **仍然不需要骨骼**
- **上阵单位**：做 SkeletalMesh，但**套用士兵骨骼** `SKEL_Soldier_Common_02_Ins`
  （Blender 里对齐骨骼 / Retarget，不新建骨骼，直接用 307 个现成动画）
**投入**：需要建模，但**骨骼和动画全白嫖**。

---

## 六、打包与安装

模型/贴图/DataTable 都是资产 → 用已实测打通的闭环：

```bash
RT="D:/FengSha_UI_Upgrade/tools/retoc/retoc.exe"
KEY="0xcf6e4b651d5b94bb234cc485b9977ca6ff1467ecdb52d7a7c1047b6749f5398b"
PAKS="D:/STEAM/steamapps/common/mo/MOProject/Content/Paks"

# ① 解包要改的资产
"$RT" -a "$KEY" to-legacy "$PAKS" ./work --version UE5_6 -f "MOMenKeInformationConfig"

# ② 改（.uasset ↔ JSON，注意 fromjson 没有 version 参数）
UAssetGUI tojson   ./work/.../MOMenKeInformationConfig.uasset  C:/tmp/x.json  VER_UE5_6 Game
UAssetGUI fromjson C:/tmp/x.json  ./work/.../MOMenKeInformationConfig.uasset  Game

# ③ 只打包改过的资产（.uasset + .uexp 必须成对！）
"$RT" to-zen ./mod ./MenKeMod_P.utoc --version UE5_6
"$RT" verify ./MenKeMod_P.utoc

# ④ 安装
mkdir -p "$PAKS/~mods" && cp ./MenKeMod_P.* "$PAKS/~mods/"
```

详见 `09_Modding/示例模组_FengShaBalanceDemo/README.md` 与 `tools/asset_mod_roundtrip.sh`。

---

## 七、一句话总结

> **做新门客不需要骨骼绑定。**
> 立绘是 **StaticMesh**（无骨骼）；上阵单位**复用士兵骨骼 + 307 个现成动画**（`AnimFSMType=SoldierAnimFSM`）。
> 如果你只想做"数据上的新门客"，**连模型都不用碰**。
