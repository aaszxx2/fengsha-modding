# 可制作模组评估（基于本次逆向的全部产出）

> 问题：这些逆向产出能帮到什么模组？能不能做联机模组？
> 结论先说：**联机模组"能做，但必须分层看"** —— 引擎的网络地基其实**很完整**
> （`?listen` / NetDriver / OnlineSubsystem+Steam / MassReplication 全在），
> 缺的是游戏层的复制实现；从"看到对方在动"到"完整合作战役"隔着几个数量级。
> 而**数值 / 逻辑 / 内容类模组非常可行**，而且你已经有 20+ 个先例。
> 日期：2026-10-13（第二节已更正）

---

## 一、先盘点：你现有的模组生态

从 `ue4ss\Mods_backup_*` 里看到的（**全是 Lua 模组，无一 pak 模组**）：

| 类别 | 模组 |
|------|------|
| **资源/经济** | `DoubleResource`、`InfiniteSupplies`、`NoCostBuild` |
| **信息显示** | `FengShaBuildingLabels`、`MenKeProbe`、`GlobalProbe`、`ZouYanMenKeProbe` |
| **单位/光环** | `YiZhanHalo`（驿站光环，改 `MOHaloConfig.HaloRadius`）、`ZouYan`、`ZouYanMenKe` |
| **战斗辅助** | `FengShaAlignAssist`、`FengShaArmyTrigger` |
| **调试/控制台** | `CheatManagerEnablerMod`、`ConsoleCommandsMod`、`ConsoleEnablerMod` |
| **QoL 整合包** | `FengShaQoL`（`main.lua` / `menu.lua` / `logistics.lua` / `storage.lua`） |
| **框架** | **`BPModLoaderMod`** ← 蓝图模组加载器（加载 `Mods/BPModLoaderMod/BPMods/*.pak` 里的 `ModActor_C`） |

**两个重要事实**：
1. **游戏支持蓝图模组**（`BPModLoaderMod` 是标准 UE 蓝图模组加载器）—— 可以加**新内容**，不只是改数值
2. 目前 **`Content\Paks\` 下没有 `~mods` 目录** → **还没装过 pak 模组**，全是 UE4SS Lua

---

## 二、联机模组：**更正 —— 引擎有地基，游戏层没盖楼**

> ⚠️ **本节已更正**。原结论"架构上不存在网络层、基本不可行"**下得太绝对**
> —— 把"游戏层没实现复制"误判成了"引擎没有网络设施"。
> 完整分析见 `08_Network/联机模组可行性深度分析.md`。

### 2.1 原证据复核（哪些站得住，哪些不成立）

| 原证据 | 复核结果 |
|------|------|
| 游戏模块零 `Replicated` / RPC 标记 | ✅ **成立** —— 游戏层确实零复制实现 |
| 无专用服务器 exe | ✅ 成立 |
| `GlobalDefaultServerGameMode=None` | ✅ 成立，但**同一份 ini 里还有 `ServerDefaultMap=.../SimpleNetwork`** |
| ~~无 Steam 联机，Steam 只用于成就~~ | ❌ **不成立** —— `[OnlineSubsystem] DefaultPlatformService=Steam` + `[OnlineSubsystemSteam] bEnabled=true` + `AppId=1733690`，**Steam 在线子系统是启用的** |
| 资产层无联机内容 | ✅ 成立（`SimpleNetwork` 地图也没被 cook 进包） |
| ~~引擎网络设施未启用~~ | ❌ **不成立** —— 见 2.2 |

### 2.2 ★ 更正：引擎网络设施其实**很完整**

| 检查项 | 实测结果 |
|--------|---------|
| **`?listen` 字符串** | ✅ **UTF-16 命中 3**（"以监听服务器启动"路径在） |
| `GameNetDriver` / `NetDriverDefinitions` | ✅ 在 |
| `PostLogin` / `PreLogin` / `HandleStartingNewPlayer` | ✅ 在（玩家加入回调） |
| `ServerTravel` / `ClientTravel` / `NetConnection` / `PendingNetGame` / `MaxPlayers` | ✅ 在 |
| 引擎 `NetDriver.h` / `GameMode.h` / `PlayerController.h` / `GameStateBase.h` | ✅ 全部存在 |
| 游戏类继承 | `AMOProjectGameModeBase : AGameModeBase`、`AMOPlayerController : APlayerController` —— **标准骨架** |
| **`MassReplication` 模块** | ✅ **完整 20 个头文件**（`MassReplicationTrait` / `MassReplicationProcessor` / `MassNetworkIDFragment` / `MassClientBubbleInfoBase` …），exe 里类名全部命中 |
| `MassAIReplication` 模块 | ✅ 在 |

**所以真实情况是**：引擎给了**完整地基**，游戏层**一栋楼都没盖**。

### 2.3 MassReplication 能解决多少？（关键限制）

它**只同步位置和朝向**：
```cpp
FReplicatedAgentPositionYawData { FVector Position; float Yaw; }
```
这是为 **MassCrowd（城市人群）** 设计的视觉同步 —— "远处那 500 个路人在动"就够了。

- **它能给你**：看到对方单位在动
- **它不能给你**：战斗结果一致、资源一致、AI 一致

### 2.4 参考项目怎么做（骑砍2 / 环世界 / 上古卷轴5）

| 项目 | 同步模型 | patch 手段 |
|------|---------|-----------|
| **Bannerlord Coop** | 领域同步 + 权威服务器（8 人，有专用服务器） | NoHarmony |
| **RimWorld MP**（MIT 开源，674★） | 确定性锁步 + 指令队列 + **desync 检测** | Harmony + LiteNetLib |
| **Skyrim Together** | 自研协议 + 状态快照 | C++ hook |

**共同点（最关键）**：**它们都没有"启用引擎的复制层"，而是自研同步。**
原因是单机游戏的代码不满足引擎复制的假设（没有 `Replicated` 标记、没有权威性设计、
逻辑不确定）。

**烽沙比它们强的地方**：引擎复制层 + MassReplication 是**现成的**。
**烽沙比它们难的地方**：C++ 无符号二进制（无 PDB，函数靠逆向定位）、
**Mass 是多线程并行（确定性极难保证）**。

### 2.5 分阶段路线（务实版）

| 阶段 | 目标 | 难度 | 现实工作量 |
|------|------|------|-----------|
| **A. 验证网络栈** | `?listen` 能起服、客户端能连上、不崩 | ⭐⭐ | 数天 |
| **B. 实体位置同步** | 双方能看到对方单位在动（挂 `MassReplicationTrait`） | ⭐⭐⭐ | 数周 |
| **C. 玩家操作同步** | 指令走网络，各自指挥自己的部队 | ⭐⭐⭐⭐ | 数月 |
| **D. 完整合作战役** | 共享世界、战斗/经济/AI 一致、反同步 | ⭐⭐⭐⭐⭐ | 人年 |

> **修正后的建议**：
> **不要一上来就做 D**，但 **A 阶段值得先试** —— 成本最低、**零代码改动**，
> 且能一次性验证"引擎网络栈到底能不能在本作跑起来"。A 过不去，后面不用谈。
> 具体步骤见 `08_Network/联机模组可行性深度分析.md` 第六节。

### 2.6 不依赖网络的"准联机"方案（仍然有效）

| 方案 | 可行性 | 说明 |
|------|-------|------|
| **共享存档 / 云存档** | ⭐⭐⭐ | 游戏自带 `EasyMultiSave`（多存档槽）。可改造成 Steam 云 / 局域网共享目录 |
| **存档异步对战** | ⭐⭐ | 各玩各的，最后比指标（民心/疆域） |
| **观战 / 直播** | ⭐⭐⭐ | 不涉及状态同步，只是画面共享 |

---

## 三、能做什么模组（按可行性分级）

### 🥇 第一梯队：数值/平衡类（最容易，**我已有全套数据**）

| 模组想法 | 我手上的数据 | 改哪里 |
|---------|-------------|-------|
| **兵种平衡调整** | `实体能力表.csv`（79 实体 × 33 列：移速/加速度/推挤/避障） | `DA_*Config` 的 Trait 参数 |
| **"攻城器械不再碾压"** | 已知器械 `受推 0.05 / 施推 5.0` | 改 `MOCombatPushTrait` 参数 |
| **士兵属性重做** | `士兵属性表.csv`（血量/士气/攻击/护甲/移速）+ `士兵属性明细表.csv`（587 行五向阵型） | `BattleAttribute` DataTable |
| **经济/配方改造** | `加工配方表.csv`（**101 条完整配方含材料**）+ `资源清单.csv`（109 种物品价格） | `CraftFormulaConfig` |
| **门客门派强化** | 20 个门派配置 + 每个的 Trait 组合与参数 | `DA_MOMenKe*Config` |
| **建造无消耗/加速** | `建筑配置表.csv` + 配方耗时 | 已有 `NoCostBuild` 先例 |

### 🥈 第二梯队：逻辑/交互类（中等，写 Lua，有大量先例）

| 模组想法 | 我手上的数据 |
|---------|-------------|
| **AI 行为改造** | `StateTree任务清单.csv`（37 棵树 / **88 种任务·条件·求值器**）+ 每个实体用哪棵树 |
| **QoL 增强**（参照 `FengShaQoL`） | `Subsystem索引.csv`（124 个 Subsystem）+ `游戏模块API清单.csv`（**2,914 个可调用 API**） |
| **调试/可视化面板** | `Processor虚函数表.csv` + `结构体偏移表.csv`（990 结构体 / 3,897 字段）+ 94 个控制台命令 |
| **实体实时监控** | `Processor逻辑定位.md`（100 个处理器 / 295 lambda）+ Mass 实体清单 |
| **门客/军队探针** | 已有 `MenKeProbe`/`GlobalProbe` 先例 |

### 🥉 第三梯队：内容/资产类（较难，但**`retoc` 让这条路打开了**）

| 模组想法 | 需要什么 | 我有什么 |
|---------|---------|---------|
| **资产替换**（贴图/模型/音效） | 打包回 `.pak` | **`retoc` 有 `pack-raw` / `to-zen`** → 能打包！ |
| **蓝图模组**（加新建筑/新单位） | `BPModLoaderMod` + 打包 | 已有加载器；需要 UE 编辑器做蓝图 |
| **新地图** | UE 编辑器 | 游戏自带 **`ModularBuildingImporter`** 插件（官方模组支持！） |
| **本地化/文本改造** | 改本地化资源 | `Tolgee` 插件在，且有 `DefaultGameplayTags.ini` 等配置 |

> **本次最大的能力增量**：以前拿不到资产（Oodle 挡住），现在有
> **`retoc`（能解包也能打包）+ `FModelCLI`（列/导出）+ `usmap`（属性可读）**
> → **"改资产再打包回游戏"这条路通了**。

### 3.1 ✅ 资产模组的完整闭环（**已实测跑通，含改值验证**）

```bash
RT="D:/FengSha_UI_Upgrade/tools/retoc/retoc.exe"
UAG="D:/FengSha_UI_Upgrade/tools/UAssetGUI.exe"
PAKS="D:/STEAM/steamapps/common/mo/MOProject/Content/Paks"

KEY="0xcf6e4b651d5b94bb234cc485b9977ca6ff1467ecdb52d7a7c1047b6749f5398b"  # 从 FModel 配置取

# ① 解包：IoStore → legacy 目录（可编辑的 .uasset + .uexp）
#    ⚠️ 加密 pak 必须带 -a <AES key>，否则报 "missing encryption key"
"$RT" -a "$KEY" to-legacy "$PAKS" ./work --version UE5_6 -f "DA_MOArcher*"
#    ↑ INPUT 必须是 .utoc 或含 .utoc 的目录；OUTPUT 是"目录 或 .pak"

# ② 改：.uasset → JSON（必须带 usmap 才看得见属性）→ 编辑 → 回写
"$UAG" tojson   work/.../DA_MOArcherConfig.uasset  C:/tmp/x.json  VER_UE5_6 Game
#    （编辑 x.json 里的数值）
#    ⚠️ fromjson 语法 = <json> <uasset> [mappings]，**没有 engine version 参数**！
"$UAG" fromjson C:/tmp/x.json  work/.../DA_MOArcherConfig.uasset  Game

# ③ 只挑出改过的资产，保持相对路径，打包（Legacy → Zen）
mkdir -p ./mod/MOProject/Content/MO/Core/MOMass/MOMassEntity
cp ./work/MOProject/Content/MO/Core/MOMass/MOMassEntity/DA_MOArcherConfig.{uasset,uexp} \
   ./mod/MOProject/Content/MO/Core/MOMass/MOMassEntity/
"$RT" to-zen ./mod ./MyMod_P.utoc --version UE5_6   # → .utoc + .ucas + .pak

# ④ 安装：三件套一起丢进 ~mods
mkdir -p "$PAKS/~mods"
cp MyMod_P.utoc MyMod_P.ucas MyMod_P.pak "$PAKS/~mods/"
```

**⚠️ 更正（原文档写错）**：`to-legacy` 的语义是 **Zen→Legacy（解包）**，
它的 `OUTPUT` 虽然可以写 `.pak`，但 `INPUT` 必须是 IoStore 容器，
**不能**用 `to-legacy <legacy目录> out.pak` 来打包。打包方向必须用 **`to-zen`**。

**实测验证记录（2026-10-13，逐条跑过，字节级核对）**：

| 步骤 | 命令 | 结果 |
|------|------|------|
| 解包 79 个 Mass 配置 | `to-legacy <游戏Paks> legacy_mass -f "DA_MO*"` | ✅ 79 个 `.uasset` + 79 个 `.uexp` |
| 导出 JSON | `UAssetGUI tojson DA_MOArcherConfig.uasset` | ✅ 75 KB JSON，21 个 Trait 导出对象 |
| **改值（DataAsset）** | `MOCombatPushTrait_0.PushReceivedScale` **0.75 → 0.05** | ✅ uexp md5 `9e05e07e…`→`91876187…` |
| **改值（DataTable）** | `BattleAttribute` 行「近战兵」：`Mass` 400→800、`RotateSpeed` 360→180 | ✅ uexp md5 变化 |
| 打包（整目录） | `to-zen ./work MyMod_P.utoc --version UE5_6` | ✅ `.utoc`(8.7KB) + `.ucas`(236KB) + `.pak`(347B) |
| **打包（单资产）** | `to-zen ./mod ArcherBalance_P.utoc` | ✅ `.utoc`(509B) + `.ucas`(4.3KB) |
| 容器校验 | `retoc verify X_P.utoc` | ✅ **verified** |
| 路径索引 | `retoc unpack X_P.utoc out/` | ✅ 文件名是**完整资产路径** |
| **改动进包（DataAsset）** | 打包后 unpack，与原始包 chunk 字节对比 | ✅ **只差 4 字节**，吻合 `0.75`=0x3F400000→`0.05`=0x3D4CCCCD |
| **改动进包（DataTable）** | 同上 | ✅ **只差 3 字节**，吻合 Mass(2 字节)+RotateSpeed(1 字节) |

> **`.pak` 只有 347 字节是正常的** —— UE5 IoStore 模组的形态就是
> `.utoc`（索引）+ `.ucas`（数据）+ `.pak`（只有 `../../../` mount point 的空壳索引）。
> 资产数据在 `.ucas` 里，不在 `.pak` 里。

> ⚠️ **六个坑（全是实测踩出来的，前两个会导致"以为成功了其实没改"）**：
> 1. **`fromjson` 没有 engine version 参数**！官方语法是
>    `UAssetGUI fromjson <source.json> <destination.uasset> [mappings name]`。
>    多传一个 `VER_UE5_6` 会被当成 mappings 名 → 找不到映射 →
>    **静默失败**（exit=0、无输出、**文件时间戳都不变**）。
>    （`tojson` 才需要 `<version> [mappings]`，两者语法不一样。）
> 2. **`retoc to-zen` 打包是非确定性的**：同一目录打两次，`.ucas` 的 md5 都不同。
>    所以**绝对不能用容器 md5 判断改动是否生效**。
>    唯一可靠方式：`unpack` 出 chunk 后**字节级对比**（差异字节数应等于改动字段的字节数）。
> 3. **加密 pak 必须带 AES key**（`retoc -a <key> to-legacy ...`），否则
>    `Error: missing encryption key`。key 可从 FModel 的 `AppSettings.json` 里取。
> 4. **`.uasset` 必须和 `.uexp` 成对出现**。UE 的 cooked 资产是 **split exports** 格式
>    （`.uasset` 存头部/导入表，`.uexp` 存属性数据）。打包时少了 `.uexp`，
>    `retoc to-zen` 会**静默跳过**该资产：
>    `Skipping ... because it does not have a split exports file`。
> 5. `retoc unpack` 取出的是 **Zen 格式原始 chunk**（不是 legacy uasset），
>    所以**不能**直接拿 unpack 产物去 `UAssetGUI tojson`（会静默失败，不报错）；
>    要读回必须用 `to-legacy`。
> 6. `UAssetGUI` **不认 Git Bash 的 `/tmp` 路径**（它按 Windows 路径解析），
>    传 `C:/...` 或 `D:/...` 绝对路径才有效。

> ✅ **最佳实践：只打包改过的资产。**
> 保持 `MOProject/Content/...` 相对路径，把**改动的那一个资产**（`.uasset`+`.uexp`）
> 单独放进一个目录再 `to-zen`。实测单资产包只有 **4.3 KB**（整目录版是 236 KB）。
> 直接把整个解包目录打包，会把 79 个 Mass 配置全部"固化"成当前版本，
> 游戏更新后会出问题。

**已验证的工具能力**：

| 工具 | 命令 | 作用 |
|------|------|------|
| `retoc` | `to-legacy <utoc/目录> <目录或.pak>` | 解包：Zen → Legacy |
| `retoc` | `to-zen <目录或.pak> <out.utoc> --version UE5_6` | **打包：Legacy → Zen** |
| `retoc` | `verify` / `list` / `unpack` / `unpack-raw` | 容器校验与解包 |
| `retoc` | `pack-raw` / `manifest` / `asset-registry` | 裸 chunk 打包 / 清单 / 资产注册表 |
| `UAssetGUI` | `tojson` / `fromjson` | **uasset ↔ JSON 双向**（需 usmap） |

> 📌 官方 README 佐证：retoc 对 **UE 5.3+ 支持良好**，"can convert entire games to .pak
> and have them run without issue" —— 本作是 5.6，属于受支持区间。

---

## 四、我这次的具体产出 → 能支撑什么模组（对照表）

| 产出 | 直接能做的模组 |
|------|--------------|
| **`实体能力表.csv`**（79 实体 × 33 列参数） | 兵种平衡、推挤手感、移动速度调整 |
| **`Mass实体配置属性.csv`**（完整属性路径=值） | 精确改任意 Trait 参数（有完整路径，改哪个字段一目了然） |
| **`加工配方表.csv`**（101 条含材料） | 经济重做、新配方 |
| **`士兵属性表/明细表`**（含五向阵型） | 战斗数值重做 |
| **`StateTree任务清单.csv`**（88 种任务） | AI 行为改造 |
| **`Processor逻辑定位.md`**（100 处理器 / 295 lambda / 函数 RVA） | 写 C++ 模组 hook 处理器逻辑 |
| **`结构体偏移表.csv`**（990 结构体 / 3,897 字段） | 运行时直接读写任意结构体字段 |
| **`Processor二进制符号表.csv`**（138 类函数 RVA + 类大小） | C++ 模组定位函数、hook |
| **`游戏模块API清单.csv`**（2,914 API）+ Subsystem 索引（124） | 找可调用的接口 |
| **`07_DataTable全量数据/`**（183 表 / 15,871 行） | 所有数值类模组的数据底稿 |
| **`03_Assets/资产总清单.csv`**（23,174）+ 未加载清单 | 找资产、做替换 |
| **`08_Network/`** | 说明为什么联机不可行（避免走弯路） |
| **`retoc` + `usmap` + `FModelCLI` 管线** | **资产解包/改/打包全流程** |

---

## 五、推荐的第一个模组（如果要做）

**`FengShaBalance`（烽沙平衡包）** —— 最容易见效、我有最全数据：

1. **改 `实体能力表.csv` 里想调的数值**（如把门客 150 → 250 移速）
2. 用 `usmap` 管线**反写回 `DA_*Config` 资产**（`UAssetGUI fromjson` 实测可行）
3. `retoc to-zen` 打包成 IoStore 三件套，放进 `Content\Paks\~mods\`（**已实测跑通**）
4. 或者更简单：**写成 Lua 模组运行时改**（像 `YiZhanHalo` 改 `MOHaloConfig` 那样）

> **已完成的实证**：本会话实际改了两类资产各一个字段 ——
> ① DataAsset：`DA_MOArcherConfig` 的 `MOCombatPushTrait.PushReceivedScale` `0.75 → 0.05`；
> ② DataTable：`BattleAttribute` 行「近战兵」的 `Mass` `400 → 800`、`RotateSpeed` `360 → 180`。
> 两者都走完「改 JSON → fromjson → to-zen 打包 → verify → **unpack 字节级比对**」全流程，
> 差异字节数（4 / 3）与改动完全吻合 —— **这条路不是理论可行，是已经能跑**。

> 第 4 条最简单 —— 你已有的 `YiZhanHalo` 就是"运行时改 DataTable 字段"的模板，
> 而我现在能提供**准确的字段名与当前值**，写起来会快很多。

---

## 六、一句话总结

| 问题 | 答案 |
|------|------|
| **能做联机模组吗？** | **分层看** —— 引擎有**完整地基**（`?listen` / NetDriver / OnlineSubsystem+Steam / **MassReplication 20 个头文件**），游戏层**零复制实现**。A 阶段（起服验证）数天可试；D 阶段（完整合作战役）人年级 |
| **MassReplication 能直接解决吗？** | **不能** —— 它只同步**位置/朝向**（`FReplicatedAgentPositionYawData`），是给 MassCrowd 用的视觉同步，不含战斗/经济/AI |
| **那能做什么？** | **数值/平衡模组（最容易）→ 逻辑/QoL 模组（中等）→ 资产/内容模组（retoc 打开了这条路）** |
| **这次逆向的最大价值** | 把"**能改什么**"从猜测变成**精确的字段名 + 当前值 + 改哪个文件**；打通了**资产解包→改→打包**全流程；并把联机从"不可行"细化为**四阶段路线** |
