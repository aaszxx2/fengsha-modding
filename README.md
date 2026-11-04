# fengsha-modding — 《烽沙》(MOProject) 模组开发 Skill

一个给 **AI 助手**用的技能包（Skill）：把《烽沙》的全量静态逆向成果浓缩成
可 greppable 的数据字典 + 实测工作流 + 踩坑清单 + 模组模板，
让任何接入了 Skill 机制的 AI（WorkBuddy / Claude 等）都能直接帮你做《烽沙》模组。

> ⚠️ 仅供学习研究与个人模组制作使用。使用本技能需要你**拥有正版游戏**。
> 请遵守游戏官方 MOD 政策，勿用于联机作弊或商业用途。

## 这个 Skill 让 AI 能做什么

| 任务 | 路线 | 成熟度 |
|---|---|---|
| 改数值/掉落/配方/战斗属性 | pak 闭环：retoc + UAssetGUI → `~mods` | ✅ 已实测（弓箭手数值样板） |
| UE4SS Lua 行为模组（快捷键/面板/内存改属性） | UE4SS + 已验证访问模式 | ✅ 6 个实测模板 |
| 仓储配额 / 容量 / 消耗点调参 | 组件能力矩阵 + 基准容量表 | ✅ 配额模组实测 |
| 查任何表/枚举/结构体/建筑的数据 | 15 张字典 CSV，直接 grep | ✅ 166/166 表全覆盖 |
| UI 文案 / 汉化 | StringTable 解析器（可读可写回） | ✅ |
| 新门客 / 新内容 | BPModLoaderMod 蓝图模组路线 | 📗 指南+评估 |
| 联机 | 分层评估（引擎有地基、游戏层没盖楼） | 📗 评估报告 |

## 数据规模

- **166 张 DataTable 全字段**（1,239 字段，100% 覆盖）
- **6,222 个 USTRUCT / 25,701 字段**（含 SaveGame 标记，存档逆向索引）
- **400 个枚举 / 2,308 取值**（含中文显示名）
- **796 条 UI 文案**（StringTable 原文）+ 引用关系
- **359 个建筑 BP 的组件清单**（11,422 组件）
- **377 个 BP/WBP 的 K2 字节码**索引

## 安装

### WorkBuddy / Claude Code（用户级）

把本仓库克隆（或下载解压）到技能目录：

```
Windows:  %USERPROFILE%\.workbuddy-ai\skills\fengsha-modding\
macOS:    ~/.claude/skills/fengsha-modding/
```

也可以直接下载 Release 里的 `fengsha-modding.skill` 包。

之后对 AI 说「给烽沙做个XX模组」即可自动触发。

### 外部工具（需自行安装）

| 工具 | 用途 |
|---|---|
| [retoc](https://github.com/Mordt/retoc) | IoStore(.utoc/.ucas) ↔ legacy 资产互转、打包 |
| [UAssetGUI](https://github.com/atenfyr/UAssetGUI) | uasset ↔ JSON 互转（改表核心） |
| [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) | Lua 模组运行时 |

## 目录结构

```
SKILL.md                  入口：路由 + 四条铁律 + 环境常量
references/               按任务加载的参考文档
  table-mod-pipeline.md     改表六步闭环（实测）
  ue4ss-lua-modding.md      9 条实测坑清单 + 安全访问模式
  data-cookbook.md          查询配方 + 已确认事实
  buildings-storage.md      建筑与仓储系统速查
  new-menke-guide.md        新门客制作指南
  mod-feasibility.md        可制作模组评估（含联机分层）
data/                     15 张字典 CSV（UTF-8 BOM，可 grep）
scripts/                  资产闭环 / StringTable 解析 / 字典推导等 5 个脚本
templates/                6 个实测模组（改表 / 配额 / 消耗点 / 布局 / 存档dump / 第一人称）
```

## 四条铁律（浓缩自真实翻车记录）

1. **改数据表走 pak 闭环**（retoc + UAssetGUI），不碰 UE4SS——最稳、游戏更新容忍度最高
2. **UE4SS 里禁止全对象 `FindAllOf` 兜底**——主菜单会堵死整个 Lua 线程；
   按 BP 生成类名逐类枚举（`FindAllOf("BP_Building_Granary_C")`）才是安全模式
3. **运行时拼的 UMG 面板不一定进视口**——展示内容必须同时落 `dumps\*.txt`
4. **不凭字段名猜语义**——先查 `data/` 字典；枚举在 UE4SS 运行时读出来全是 0，要用 UAssetGUI JSON

## 逆向方法（简述）

UHT 头文件解析（UE4SS 自动生成）→ UAssetGUI JSON 全量导出 → DataTable 字典构建 →
K2 字节码反汇编（377 个 BP）→ StringTable 二进制解析 → 资产闭环验证（改值→打包→游戏内生效）。
所有数据来自实际解析，无编造；推断项均标注置信度。

## License

MIT（代码与脚本）。游戏数据字典是《烽沙》衍生事实数据，归游戏开发商所有，仅供模组研究。
