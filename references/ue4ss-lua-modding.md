# UE4SS Lua 模组开发（烽沙实测版）

适用场景：快捷键、游戏内面板、运行时改组件属性、读游戏状态。
复杂样板：`templates/示例模组_FengShaQuota/`（1200+ 行，含面板/扫描/闸门/持久化）；
简单样板：`templates/示例模组_FengShaConsume/`（500 行）。

## 一、模组骨架

```
<游戏>/Binaries/Win64/ue4ss/Mods/<模组名>/
├── Scripts/main.lua        # 必需
├── config.txt              # 可选（Enabled/Verbose/IntervalSec 等开关）
├── config_*.txt            # 可选数据文件（Tab 分隔）
├── data/                   # 持久化
└── dumps/                  # 诊断输出（预建目录，见坑 5）
```

`Mods/mods.txt` 里加 `<模组名> : 1`。
⚠️ 目录里有 `enabled.txt` 的模组**无视 mods.txt 的 0**，要停用必须移走目录或删 enabled.txt。

## 二、加载顺序规范（血泪教训）

```lua
-- main.lua 末尾的启动顺序必须这样：
loadConfig()
log("已加载 v" .. VERSION)          -- ① 日志放最前：卡死了至少知道死在哪
loadDesired()
ExecuteWithDelay(3000, function()    -- ② 重活延后：主菜单没有世界，scan 会白跑甚至堵死
    scan()
    applyAll()
end)
LoopAsync(C.IntervalSec * 1000, function() tick() return false end)
```

## 三、坑清单（每条都真实翻过车）

1. **方向键枚举名**：`Key.UP_ARROW / DOWN_ARROW / LEFT_ARROW / RIGHT_ARROW`。
   `Key.UP` 不存在 → RegisterKeyBind 找不到重载 → **整个脚本不加载**。
   修饰键判断用 `IsKeyDown(Key.SHIFT)`（不是 ModifierKey.SHIFT）。
2. **`FindAllOf` 全对象枚举会堵死 Lua 线程**（主菜单/世界未加载时必现）：
   所有模组的按键回调都会停摆。要枚举建筑用**按类名逐类**（见下）。
   确需要全扫描的，加开关默认关闭 + pcall。
3. **运行时 NewObject 拼的 UMG 面板不一定进视口**（`AddToViewport` 后
   `IsInViewport` 可能仍为 false）。凡展示内容**同时写 `dumps\panel_*.txt`**。
4. **读容器（TArray/FString/FText）要 pcall**；**写容器元素风险更高**
   （实测诊断脚本写 TArray 元素导致游戏瞬间退出）。只写 int32 最稳。
5. `os.execute('mkdir ...')` 可能被环境禁掉 → 目录用宿主侧预建，Lua 里只 `io.open`。
6. Lua 字符串里 `"dumps\panel"` 的 `\p` 是非法转义，解析直接报错 → 写 `\\`。
7. **UE4SS 运行时读枚举属性全是 0**（如 SubBuildingType 219 行全 0）。
   枚举真实值要看 UAssetGUI JSON（EnumPropertyData 带 EnumName）。
8. `ConfigID` 变化 = 建筑升级，记 `store.cfg`，变化时清掉缓存的 lastSet。
9. 同类模组会互相覆盖属性（如两个模组都 SetCapacity）——先确认没有别的模组在写同一字段。

## 四、已验证的访问模式

### 枚举建筑（安全模式，真机验证）
```lua
local STORAGE_CLASSES = {
    "BP_Building_ZiZhong_LV1_C", "BP_Building_ZiZhong_LV2_C", "BP_Building_ZiZhong_LV3_C",
    "BP_Building_Storehouse_C",  "BP_Building_Storehouse_T_C",
    "BP_Building_LiangCang_LV1_C", "BP_Building_LiangCang_LV2_C", "BP_Building_LiangCang_LV3_C",
    "BP_Building_Granary_C",     "BP_Building_Granary_T_C",
    "BP_Building_Armoury_C",     "BP_Building_SupplyDepot_C",
    "BP_Building_Hospital_C",    "BP_Building_PoliceDepartment_C",
}
for _, cls in ipairs(STORAGE_CLASSES) do
    local ok, arr = pcall(function() return FindAllOf(cls) end)
    if ok and arr ~= nil then
        for _, a in ipairs(arr) do ... end   -- a:ConfigID / a:GetName()
    end
end
```
优先走子系统（读得到就用）：`FindFirstOf("BuildingSubsystem")` →
`AllPlayerBuildings` / `AllBuildings` / `BuildingCenter`（城心，用于起方位名）。
子系统读不到时自动退到上面的类名枚举。

### 仓储组件能力矩阵（继承树决定能写什么）

| 组件属性 | 建筑 | Capacity | StorageMaxItems | 逐物品需求(RemoteDemand) |
|---|---|---|---|---|
| `WarehouseStorage` | 辎重库/粮仓/军械库/货栈 | ✔ | ✔ | ✔ |
| `HospitalStorage` | 医庐 | ✔ | ✔ | ✘ |
| `PoliceDepartmentStorage` | 乡亭 | **✘** | ✔ | ✘ |

写属性前先查这张表：对没有 Capacity 的组件调 SetCapacity 会直接报错。
逐物品上限字段：`StorageMaxItems : FMOItemNumList`（SaveGame）。
远端需求：`RemoteDemandEntries : TArray<FWarehouseRemoteItemEntry{ItemType,ItemNum,bEnabled}>`
（全 BlueprintReadWrite+SaveGame，静态可写前提成立；真机写入待验证，**TArray 只能改已有条目不能追加**）。

### 消耗型组件（是"消耗点"不是仓库）
`UConsumeStorageComponent`：`Capacity / ReserveMax / ReserveMin / ReserveDefault /
CurrentReserve / DisableItemSet(TSet)`；国社的 `ConsumeRitualStorage` 另有
`bNeedItem / NeedItemList`（这是"要消耗什么"，不是"能存多少"）。
实测基准：民居食物/燃料/水 ReserveDefault=2（Max 10）、伙房燃料 10/5、医庐容量 100。
更多见 `data/consume_storage.csv`。

## 五、诊断与持久化

- 诊断（Ctrl+Shift+V 之类）**渐进落盘**：一按键就写 `diag_*_RUNNING.txt`，每步 flush，
  完成后写正式文件并删临时文件——再卡死也能看到做到哪一步。
- 持久化用 Tab 分隔文本（`data/*.txt`），启动时载入、定时重放。
- 写属性后**立即回读校验**，不一致打日志（QoL 的"写%d 读回%s"模式）。

## 六、测试（宿主侧 lupa）

模组 main.lua 暴露 `FSQ_TEST` 钩子（getModel/lastScan/applyCapacityGate…），
用 Python lupa 加载 + mock Actor。已知坑：
- 遍历 LuaTable 直接 for 拿到的是 key，要用 `.values()`；Lua 侧遍历 hash 表用 `pairs` 不用 `ipairs`
- Python dict 赋给 Lua 字段会变 POBJECT，pairs() 会炸 → 用 Lua 助手函数赋值
- mock 的 BuildingSubsystem 必须有 `IsValid` 方法，否则缓存守卫判定失效
- 前面测试把数组置 nil 后，后续 mock 要能自愈重建
完整样例：仓库根 `tools/test_quota_runtime.py`、`tools/test_consume_mod.py`（不在本 skill 内，见完整逆向库）。
