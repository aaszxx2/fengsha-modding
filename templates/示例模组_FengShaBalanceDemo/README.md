# FengShaBalanceDemo —— 资产模组模板（已实测跑通）

> 这是一个**最小可用的资产模组**，用来证明「改数值 → 打包 → 游戏加载」这条路是真的能走通。
> 生成日期：2026-10-13

---

## 这个模组改了什么

只改了一个字段：

| 资产 | 对象 | 字段 | 原值 | 改后 |
|------|------|------|------|------|
| `DA_MOArcherConfig`（弓箭手实体配置） | `MOCombatPushTrait_0` | `PushReceivedScale`（受推系数） | `0.75` | **`0.05`** |

**效果**：弓箭手被其他单位推挤时几乎不动（受推强度降到 1/15）。

完整字段对照见 `改动对照_修改后.json`（`MOCombatPushTrait_0` 的 14 个可调数值字段全列）。

---

## 文件说明

| 文件 | 大小 | 作用 |
|------|------|------|
| `ArcherBalance_P.utoc` | 509 B | IoStore 索引 |
| `ArcherBalance_P.ucas` | 4.3 KB | 资产数据（**只有 1 个资产**） |
| `ArcherBalance_P.pak` | 347 B | 空壳索引（只含 `../../../` mount point）—— **正常现象** |
| `改动对照_修改后.json` | — | 改后 `MOCombatPushTrait_0` 的全部数值字段 |

> ✅ **只打包改过的资产**才是正确做法 —— 模组体积极小，且**不会覆盖游戏原有的其他配置**。

> ⚠️ **`.uasset` 必须和 `.uexp` 成对出现**！UE 的 cooked 资产是 **split exports** 格式
> （`.uasset` 存头部/导入表，`.uexp` 存属性数据）。打包时少了 `.uexp`，
> `retoc to-zen` 会直接**静默跳过**该资产，报
> `Skipping ... because it does not have a split exports file`。

---

## 安装方式

```bash
PAKS="D:/STEAM/steamapps/common/mo/MOProject/Content/Paks"
mkdir -p "$PAKS/~mods"
cp ArcherBalance_P.utoc ArcherBalance_P.ucas ArcherBalance_P.pak "$PAKS/~mods/"
```

卸载：直接删掉 `~mods` 里的这三个文件即可（**不修改任何游戏原文件**）。

> 📌 `~mods` 目录目前不存在（说明这台机器还没装过 pak 模组），需要自己创建。

---

## 复现步骤（完整闭环，命令已逐条实测）

```bash
RT="D:/FengSha_UI_Upgrade/tools/retoc/retoc.exe"
UAG="D:/FengSha_UI_Upgrade/tools/UAssetGUI.exe"
PAKS="D:/STEAM/steamapps/common/mo/MOProject/Content/Paks"
KEY="0xcf6e4b651d5b94bb234cc485b9977ca6ff1467ecdb52d7a7c1047b6749f5398b"   # 从 FModel 配置拿到

# ① 解包（Zen → legacy 目录，会生成 .uasset + .uexp 成对文件）
#    ⚠️ 加密的 pak 必须带 -a <AES key>，否则报 "missing encryption key"
"$RT" -a "$KEY" to-legacy "$PAKS" ./work --version UE5_6 -f "DA_MOArcher*"

# ② uasset → JSON（必须带 usmap 才能看到属性）
cd "D:/FengSha_UI_Upgrade/tools"
./UAssetGUI.exe tojson "D:/.../work/.../DA_MOArcherConfig.uasset" "C:/tmp/x.json" VER_UE5_6 Game

# ③ 编辑 x.json：MOCombatPushTrait_0.PushReceivedScale  0.75 → 0.05
#    JSON → uasset
#    ⚠️ fromjson 语法是 <json> <uasset> [mappings]，**没有 engine version 参数**！
#       多传 VER_UE5_6 会被当成 mappings 名 → 静默失败（exit=0 但文件不写）。
./UAssetGUI.exe fromjson "C:/tmp/x.json" "D:/.../work/.../DA_MOArcherConfig.uasset" Game

# ④ 只挑出改过的资产，保持相对路径，打包（Legacy → Zen）
mkdir -p ./mod/MOProject/Content/MO/Core/MOMass/MOMassEntity
cp ./work/MOProject/Content/MO/Core/MOMass/MOMassEntity/DA_MOArcherConfig.{uasset,uexp} \
   ./mod/MOProject/Content/MO/Core/MOMass/MOMassEntity/
"$RT" to-zen ./mod ./ArcherBalance_P.utoc --version UE5_6
"$RT" verify ./ArcherBalance_P.utoc        # -> verified

# ⑤ 安装
mkdir -p "$PAKS/~mods" && cp ./ArcherBalance_P.* "$PAKS/~mods/"
```

也可以直接用归档脚本：`tools/asset_mod_roundtrip.sh`。

---

## 实测验证记录（字节级）

| 检查项 | 结果 |
|--------|------|
| `retoc verify` | ✅ verified |
| `retoc unpack` | ✅ 1 个文件，路径 `MOProject/Content/MO/Core/MOMass/MOMassEntity/DA_MOArcherConfig.uasset` |
| `fromjson` 是否写入 | ✅ uexp md5 `9e05e07e…` → `91876187…` |
| **改动是否进包** | ✅ 打包后 unpack 出的 chunk 与原始包**只差 4 个字节** |
| 4 字节差是否吻合 | ✅ `0.75`=0x3F400000 → `0.05`=0x3D4CCCCD，**4 字节全不同**，完全吻合 |

> ⚠️ **不要用容器 md5 判断改动是否生效**！`retoc to-zen` 打包**是非确定性的**
> （同一目录打两次，`.ucas` 的 md5 都不同）。唯一可靠的验证方式是
> **unpack 出 chunk 后做字节级对比**（差异字节数应等于改动字段的字节数）。

**尚未验证**：游戏内实际加载效果（需要启动游戏实测）。
