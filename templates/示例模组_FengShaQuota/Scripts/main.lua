--[[
================================================================================
  《烽沙》辎重配额  FengShaQuota  v1.0
  纯 UE4SS Lua 模组 —— 不修改任何游戏文件，不生成/销毁任何资源

  目标：让玩家控制每座辎重库「存多少、优先存什么」。

  逆向依据（全部来自 8 月构建 UHTHeaderDump + 新版 exe 符号校验）
    辎重库 = BP_Building_Storehouse，ConfigID 2 / 40022(LV2) / 40023(LV3) / 40024
    UWarehouseStorageComponent : UStorageMaxItemsBaseComponent : UStorageBaseComponent
      TotalItemNumList      FMOItemNumList  当前库存（SaveGame）
      StorageMaxItems       FMOItemNumList  每物品上限（SaveGame）  ← 游戏自带「最大存储」
      RemoteDemandEntries   TArray<FWarehouseRemoteItemEntry{ItemType,ItemNum,bEnabled}>
                                            每物品需求量（SaveGame）← 游戏自带「需求」
      GetItemNum(EMOItemType) / GetCapacity() / GetTotalItemNum() / SetCapacity(int32)
    UBuildingSubsystem.AllBuildings / AllPlayerBuildings
    ULogisticsSubsystem.GetInTransitIncomingAmount(Warehouse, ItemType)  在途数量
    EMOItemType 共 102 项（1..101 为真实物资，98..101 为伪物品，界面里剔除）

  三种执行模式（config.txt 的 EnforceMode）
    off       只读：总览 / 缺口 / 提醒 / 复制，完全不改游戏状态
    capacity  容量闸门：当某座库「所有设了配额的物资都达标」时，把该库容量压到当前总量
              → 游戏自己的「仓库已满」逻辑会拒绝再送入。库存下降后自动恢复。
              （SetCapacity 是 BlueprintCallable，实测存在；容量不是 SaveGame，退出即还原）
    native    写原生每物品上限 StorageMaxItems（实验性，需先用 Ctrl+Shift+V 自检）

  快捷键
    Ctrl+Q            开关配额面板
    Ctrl+Shift+Q      切换辎重库
    Ctrl+Shift+W      切换物资
    Ctrl+Shift+E      目标 +步长
    Ctrl+Shift+D      目标 -步长
    Ctrl+Shift+F      禁止存入 / 取消
    Ctrl+Shift+C      复制配额到下一座辎重库
    Ctrl+Shift+T      套用模板（循环：均衡→粮食优先→建造储备→备战储备）
    Ctrl+Shift+X      重置当前库为游戏默认
    Ctrl+Shift+V      诊断（写 dumps\diag_*.txt）

  安全规则（沿用 FengShaQoL / ZouYanMenKe 的踩坑清单）
    1. 所有 UObject 访问走 pcall；结构体绝不取长度（# / :Num() 会 native AV）
    2. 调 UFUNCTION 用 fn(obj, ...)；只判 nil 不判 type
    3. 永不删除 / 出售 / 搬运库存；容量闸门永不把容量压到低于当前库存
    4. 常驻循环低频（默认 3s），主菜单（无 PlayerController）直接跳过
================================================================================
]]

local MOD = "[FengShaQuota]"
local VERSION = "1.0"
local unpack = unpack or table.unpack

-- ============================================================================
-- 0. 目录与配置
-- ============================================================================

local function GetScriptDir()
    local info = debug.getinfo(1, "S")
    local source = info.source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local dir = source:match("^(.*[\\/])")
    if dir then
        dir = dir:gsub("[\\/]Scripts[\\/]$", "")
        dir = dir:gsub("[\\/]Scripts$", "")
        return dir
    end
    return ""
end

local BASE_DIR = GetScriptDir()
local DATA_DIR = BASE_DIR .. "\\data"
local DUMP_DIR = BASE_DIR .. "\\dumps"

local function ParseConfig(path)
    local cfg = {}
    local f = io.open(path, "r")
    if not f then
        print(string.format("%s 找不到 config.txt，使用默认配置\n", MOD))
        return cfg
    end
    for line in f:lines() do
        local noComment = string.gsub(line, "#.*$", "")
        local key, value = string.match(noComment, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key and value ~= "" then
            if string.lower(value) == "true" then
                cfg[key] = true
            elseif string.lower(value) == "false" then
                cfg[key] = false
            elseif tonumber(value) then
                cfg[key] = tonumber(value)
            else
                cfg[key] = value
            end
        end
    end
    f:close()
    return cfg
end

local CFG = ParseConfig(BASE_DIR .. "\\config.txt")

local C = {
    Enabled        = CFG.Enabled ~= false,
    -- 默认 off：第一次装先只读，确认不卡再开 capacity
    EnforceMode    = CFG.EnforceMode or "off",        -- off | capacity | native
    ReadMode       = CFG.ReadMode or "getter",        -- getter（安全） | array（快，有风险）
    NativeMirror   = CFG.NativeMirror == true,        -- 额外把目标写进 RemoteDemandEntries
    DryRun         = CFG.DryRun == true,              -- true=只算不写（演练）
    ScanIntervalMs = tonumber(CFG.ScanIntervalMs) or 3000,
    PanelRefreshMs = tonumber(CFG.PanelRefreshMs) or 1000,
    HudMs          = tonumber(CFG.HudMs) or 5000,
    TargetStep     = tonumber(CFG.TargetStep) or 50,
    DefaultTarget  = tonumber(CFG.DefaultTarget) or 100,
    IncludeEnemy   = CFG.IncludeEnemy == true,
    Verbose        = CFG.Verbose == true,
    MaxStoresInList = tonumber(CFG.MaxStoresInList) or 12,
    ShowIncoming   = CFG.ShowIncoming ~= false,
    -- 只读模式 + 面板没开时，完全不扫描（零开销）。想随时有数据就设 false
    LazyWhenIdle   = CFG.LazyWhenIdle ~= false,
}

-- ============================================================================
-- 1. 基础工具
-- ============================================================================

local function log(msg)
    print(string.format("%s %s\n", MOD, tostring(msg)))
end

local function isValid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function prop(o, name)
    if o == nil then return nil end
    local ok, v = pcall(function() return o[name] end)
    if ok then return v end
    return nil
end

local lastCallErr = nil
local function callf(o, name, ...)
    if o == nil then return nil end
    local fn = prop(o, name)
    if fn == nil then
        lastCallErr = name .. ": 找不到该函数"
        return nil
    end
    local args = { ... }
    local ok, r = pcall(function() return fn(o, unpack(args)) end)
    if ok then
        lastCallErr = nil
        return r
    end
    lastCallErr = name .. ": " .. tostring(r)
    return nil
end

local function mkText(s)
    local ok, r = pcall(function() return FText(s) end)
    if ok and r ~= nil then return r end
    return nil
end

-- 目录探测（不 spawn 进程）
-- 旧版用 os.execute('cmd /c mkdir ...')：每次启动会阻塞游戏线程，
-- 实测在 UE4SS 里两次调用之间卡了 664ms。目录由安装脚本创建，这里只探测。
local function dirWritable(path)
    if path == "" then return false end
    local probe = path .. "\\.wtest"
    local f = io.open(probe, "w")
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
end

local function ensureDir(path)
    if path == "" then return end
    if not dirWritable(path) then
        log("目录不可写: " .. path .. "（请运行 install_quota_mod.sh，它会建 data/ 和 dumps/）")
    end
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

-- 枚举值可能是 number，也可能是 {Value=n} / "EMOItemType::X"
local function toNum(v)
    if type(v) == "number" then return v end
    if type(v) == "table" then
        local x = v.Value
        if type(x) == "number" then return x end
    end
    return nil
end

local function toNumF(v)
    local n = toNum(v)
    if n then return n end
    if type(v) == "number" then return v end
    return nil
end

local function round(v)
    if v >= 0 then return math.floor(v + 0.5) end
    return -math.floor(-v + 0.5)
end

-- 中英混排对齐：按 UTF-8 字节估算显示列宽（3 字节字符≈2 列）
local function dispWidth(s)
    local n = 0
    local i = 1
    while i <= #s do
        local c = s:byte(i)
        local len = 1
        if c >= 240 then len = 4
        elseif c >= 224 then len = 3
        elseif c >= 192 then len = 2 end
        n = n + (len >= 3 and 2 or 1)
        i = i + len
    end
    return n
end

local function pad(s, width)
    s = tostring(s or "")
    local w = dispWidth(s)
    if w >= width then return s end
    return s .. string.rep(" ", width - w)
end

-- ============================================================================
-- 2. 世界 / 子系统
-- ============================================================================

local UEHelpers = require("UEHelpers")

local function getWorld()
    local ok, w = pcall(function() return UEHelpers.GetWorld() end)
    if ok and isValid(w) then return w end
    return nil
end

local function getPC()
    local ok, p = pcall(function() return UEHelpers.GetPlayerController() end)
    if ok and isValid(p) then return p end
    return nil
end

local function getPawn()
    local ok, p = pcall(function() return UEHelpers.GetPlayerPawn() end)
    if ok and isValid(p) then return p end
    return nil
end

local function findObj(path)
    local ok, o = pcall(function() return StaticFindObject(path) end)
    if ok and isValid(o) then return o end
    return nil
end

local function findFirst(cls)
    local ok, o = pcall(function() return FindFirstOf(cls) end)
    if ok and isValid(o) then return o end
    return nil
end

-- 子系统缓存：FindFirstOf 会遍历整个 GUObjectArray，每帧/每轮调用是卡顿主因之一
local SysCache = { bs = nil, ls = nil, lsAt = 0, bsAt = 0 }
local FallbackCache = { arr = nil, kind = nil, at = 0 }

local function getBuildingSubsystem()
    if isValid(SysCache.bs) then return SysCache.bs end
    -- 找不到时不要每轮都全对象扫描（那是卡顿主因），30 秒内只试一次
    if SysCache.bsAt > 0 and os.time() - SysCache.bsAt < 30 then return nil end
    SysCache.bs = findFirst("BuildingSubsystem")
    SysCache.bsAt = os.time()
    return SysCache.bs
end

local function getLogisticsSubsystem()
    if isValid(SysCache.ls) then return SysCache.ls end
    if SysCache.lsAt > 0 and os.time() - SysCache.lsAt < 10 then return nil end
    SysCache.ls = findFirst("LogisticsSubsystem")
    SysCache.lsAt = os.time()
    return SysCache.ls
end

local function vecOf(actor)
    local v = callf(actor, "K2_GetActorLocation")
    if v ~= nil then return v end
    v = callf(actor, "GetActorLocation")
    if v ~= nil then return v end
    return nil
end

local function nameOfActor(actor)
    local n = callf(actor, "GetName")
    if type(n) == "string" and n ~= "" then return n end
    local fn = callf(actor, "GetFullName")
    if type(fn) == "string" then return fn end
    return nil
end

-- ============================================================================
-- 3. 物资表
-- ============================================================================

local Items = {}          -- 有序数组 {id=, name=, group=}
local ItemById = {}
local HIDDEN_ITEMS = { [98] = true, [99] = true, [100] = true, [101] = true }

local function loadItems()
    local f = io.open(BASE_DIR .. "\\config_items.txt", "r")
    if not f then
        log("找不到 config_items.txt，物资名将显示为 ID")
        return
    end
    for line in f:lines() do
        if line:sub(1, 1) ~= "#" then
            local id, name, grp = line:match("^(%d+)\t([^\t]*)\t([^\t]*)")
            if id then
                local it = { id = tonumber(id), name = name, group = grp or "其他" }
                if not HIDDEN_ITEMS[it.id] then
                    Items[#Items + 1] = it
                    ItemById[it.id] = it
                end
            end
        end
    end
    f:close()
    log(string.format("已载入物资表 %d 项", #Items))
end

local function itemName(id)
    local it = ItemById[id]
    if it then return it.name end
    return "物资#" .. tostring(id)
end

-- ============================================================================
-- 4. 配额模型（纯数据，可离线单测）
-- ============================================================================

-- store = { key, label, x, y, z, origCap, lastSet, items = { [id] = q } }
-- q     = { mode = "unlimited"|"target"|"block", target = n|nil, cap = n|nil }

local Model = { version = 1, stores = {}, order = {} }

local function newStore(key, label, x, y, z)
    local s = { key = key, label = label or "辎重库", x = x or 0, y = y or 0, z = z or 0,
                origCap = nil, lastSet = nil, items = {} }
    Model.stores[key] = s
    Model.order[#Model.order + 1] = key
    return s
end

-- 返回 (有效上限, 类型, 是否冲突)
local function limits(q)
    if q == nil then return nil, nil, false end
    if q.mode == "block" then return 0, "block", false end
    local t = nil
    if q.mode == "target" then t = q.target end
    local c = q.cap
    if t and c then
        if c < t then return c, "cap", true end
        return t, "target", false
    elseif t then
        return t, "target", false
    elseif c then
        return c, "cap", false
    end
    return nil, nil, false
end

-- 纯函数：给一个配额和当前库存，返回 (状态码, 文案)
local function statusOf(q, cur)
    cur = cur or 0
    if q == nil then return "orig", "原版" end
    if q.mode == "unlimited" and q.cap == nil then return "orig", "原版" end
    if q.mode == "block" then return "block", "禁止存入" end
    local lim, kind, conflict = limits(q)
    if lim == nil then return "orig", "原版" end
    if cur >= lim then
        if kind == "cap" then
            return "cap", (conflict and "达上限(冲突)" or "达上限")
        end
        return "target", "已达目标"
    end
    local gap = lim - cur
    if conflict then
        return "need", string.format("需补 %d(冲突)", gap)
    end
    return "need", string.format("需补 %d", gap)
end

-- 该库「所有设了配额的物资是否都已达标」
local function storeAllMet(store, cur)
    local has = false
    for id, q in pairs(store.items) do
        local lim = limits(q)
        if lim ~= nil then
            has = true
            if (cur[id] or 0) < lim then return false, true end
        end
    end
    return has, has
end

local function countQuota(store)
    local n = 0
    for _ in pairs(store.items) do n = n + 1 end
    return n
end

-- ---------- 序列化（纯函数） ----------

local function serializeModel(m)
    local L = { "V\t1" }
    for _, key in ipairs(m.order) do
        local s = m.stores[key]
        if s then
            L[#L + 1] = string.format("S\t%s\t%s\t%d\t%d\t%d\t%s",
                s.key, s.label or "", round(s.x or 0), round(s.y or 0), round(s.z or 0),
                tostring(s.origCap or ""))
            local ids = {}
            for id in pairs(s.items) do ids[#ids + 1] = id end
            table.sort(ids)
            for _, id in ipairs(ids) do
                local q = s.items[id]
                L[#L + 1] = string.format("Q\t%s\t%d\t%s\t%s\t%s",
                    s.key, id, q.mode or "target",
                    tostring(q.target or ""), tostring(q.cap or ""))
            end
        end
    end
    for name, tpl in pairs(m.templates or {}) do
        local ids = {}
        for id in pairs(tpl) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            L[#L + 1] = string.format("T\t%s\t%d\t%d", name, id, tpl[id])
        end
    end
    return table.concat(L, "\n") .. "\n"
end

local function parseModel(text)
    local m = { version = 1, stores = {}, order = {}, templates = {} }
    if not text then return m end
    for line in text:gmatch("[^\n]+") do
        if line:sub(1, 1) == "S" then
            local key, label, x, y, z, cap = line:match("^S\t([^\t]*)\t([^\t]*)\t(-?%d+)\t(-?%d+)\t(-?%d+)\t(.*)$")
            if key then
                local s = { key = key, label = label, x = tonumber(x), y = tonumber(y),
                            z = tonumber(z), origCap = tonumber(cap), items = {} }
                m.stores[key] = s
                m.order[#m.order + 1] = key
            end
        elseif line:sub(1, 1) == "Q" then
            local key, id, mode, target, cap = line:match("^Q\t([^\t]*)\t(%d+)\t([^\t]*)\t([^\t]*)\t(.*)$")
            local s = key and m.stores[key]
            if s and id then
                s.items[tonumber(id)] = {
                    mode = mode ~= "" and mode or "target",
                    target = tonumber(target),
                    cap = tonumber(cap),
                }
            end
        elseif line:sub(1, 1) == "T" then
            local name, id, target = line:match("^T\t([^\t]*)\t(%d+)\t(%d+)$")
            if name and id then
                m.templates[name] = m.templates[name] or {}
                m.templates[name][tonumber(id)] = tonumber(target)
            end
        end
    end
    return m
end

-- ---------- 持久化 ----------

local DataFile = DATA_DIR .. "\\quota.txt"

local function loadModel()
    local txt = readFile(DataFile)
    Model = parseModel(txt)
    local n = 0
    for _ in pairs(Model.stores) do n = n + 1 end
    log(string.format("已载入配额：%d 座库", n))
end

local function saveModel()
    ensureDir(DATA_DIR)
    local ok = writeFile(DataFile, serializeModel(Model))
    if not ok then log("保存配额失败：" .. DataFile) end
    return ok
end

-- ============================================================================
-- 5. 辎重库识别与库存读取
-- ============================================================================

-- 仓储类建筑（辎重库/粮仓/军械库）—— 由 config_buildings.txt 的「是否仓储」列填充
-- 依据：这三类的 BP 里都挂了 WarehouseStorageComponent（UAssetGUI 已确认）
local STORE_IDS = {}
local BuildingName = {}       -- ConfigID -> 中文名

-- 仓储建筑的 BP 生成类名（运行时类名带 _C 后缀）。
-- QoL 模组在真机上验证过：按类名逐个 FindAllOf 是有界扫描，可靠且快；
-- 而 BuildingSubsystem 数组在某些时机读不到，这里作为双保险。
local STORAGE_CLASSES = {
    "BP_Building_ZiZhong_LV1_C", "BP_Building_ZiZhong_LV2_C", "BP_Building_ZiZhong_LV3_C",
    "BP_Building_Storehouse_C",  "BP_Building_Storehouse_T_C",
    "BP_Building_LiangCang_LV1_C", "BP_Building_LiangCang_LV2_C", "BP_Building_LiangCang_LV3_C",
    "BP_Building_Granary_C",     "BP_Building_Granary_T_C",
    "BP_Building_Armoury_C",     "BP_Building_SupplyDepot_C",
    "BP_Building_Hospital_C",    "BP_Building_PoliceDepartment_C",
}

local function loadBuildings()
    local f = io.open(BASE_DIR .. "\\config_buildings.txt", "r")
    if not f then
        -- 兜底：内置 12 个仓储 ID
        for _, id in ipairs({ 2, 40022, 40023, 40024, 90002, 91002,
                              3, 40032, 40033, 90003, 71, 90071 }) do
            STORE_IDS[id] = true
        end
        log("没找到 config_buildings.txt，用内置仓储 ID 表")
        return
    end
    local n = 0
    for line in f:lines() do
        if line:sub(1, 1) ~= "#" then
            local id, name, st = line:match("^(%d+)\t([^\t]*)\t?(%d*)")
            if id then
                id = tonumber(id)
                BuildingName[id] = name
                if st == "1" then STORE_IDS[id] = true end
                n = n + 1
            end
        end
    end
    f:close()
    local m = 0
    for _ in pairs(STORE_IDS) do m = m + 1 end
    log(string.format("已载入建筑表 %d 条（其中仓储 %d 条）", n, m))
end

-- 基准容量表（逆向自 BP 的 WarehouseStorage.Capacity）
-- 有了它就不用「从当前 cap 猜基准」，建筑升级时不会把封口后的值误当基准
local BaseCap = {}

local function loadBaseCaps()
    local f = io.open(BASE_DIR .. "\\config_capacities.txt", "r")
    if not f then
        log("没找到 config_capacities.txt，基准容量将靠运行时推断")
        return
    end
    local n = 0
    for line in f:lines() do
        if line:sub(1, 1) ~= "#" then
            local id, cap = line:match("^(%d+)\t(%d+)")
            if id then
                BaseCap[tonumber(id)] = tonumber(cap)
                n = n + 1
            end
        end
    end
    f:close()
    log(string.format("已载入基准容量 %d 条", n))
end

local function buildingName(id)
    return BuildingName[id] or ("建筑#" .. tostring(id))
end

local ScanCounter = 0
local KnownItems = {}         -- key -> { [itemId]=true }  上一轮有货的物资

local LastScan = {
    at = 0,
    stores = {},          -- 有序数组 {key, actor, comp, cur, cap, total, label, itemList}
    byKey = {},
    invSource = "?",
    playerSet = false,
    errors = {},
    hist = {},            -- ConfigID -> 数量（诊断用）
    totalBuildings = 0,
    source = "?",
    hasBS = false,
}

local function actorConfigId(actor)
    return toNum(prop(actor, "ConfigID"))
end

-- 物流站组件（逆向 2026-10-18：只有模块化辎重库/粮仓带 V4，货栈是 V2，军械库没有）
-- V4 的两个属性：LogisticsMode(ELogisticsStationMode: SendOnly/ReceiveOnly/Both)、ReceiveSlotTag
local LOGI_PROPS = { "BuildingLogisticsStationV4", "BuildingLogisticsStationV2",
                     "BuildingLogisticsStation" }

local function getLogisticsComp(actor)
    for _, n in ipairs(LOGI_PROPS) do
        local c = prop(actor, n)
        if isValid(c) then return c, n end
    end
    return nil, nil
end

local MODE_NAMES = { [0] = "SendOnly", [1] = "ReceiveOnly", [2] = "Both" }
local MODE_CN = { SendOnly = "只发货", ReceiveOnly = "只收货", Both = "收发" }

local function readLogisticsMode(actor)
    local lc, lname = getLogisticsComp(actor)
    if not isValid(lc) then return nil, nil end
    local m = prop(lc, "LogisticsMode")
    if m == nil then return nil, lname end
    if type(m) == "table" then m = m.Value end
    if type(m) == "number" then m = MODE_NAMES[m] or tostring(m) end
    return m, lname
end

-- 拿仓储组件
-- ★ 关键：BP 里的 SCS 节点名才是 Actor 上的属性名。逆向全部 359 个建筑蓝图后确认：
--   节点名是 `WarehouseStorage`（不是 WarehouseStorageComponent，后者是「类名」）
--   15 个建筑带这个节点：辎重库(ZiZhong/Storehouse)、粮仓(LiangCang/Granary)、军械库(Armoury)、货栈(SupplyDepot)
-- 各类仓储组件的能力矩阵（逆向自 UHTHeaderDump 的继承关系）
--   UStorageMaxItemsBaseComponent : Capacity + StorageMaxItems
--     ├ WarehouseStorage         + RemoteDemandEntries / RemoteSupplyEntries
--     └ HospitalStorage          （无额外字段）
--   UPoliceDepartmentStorageComponent : 只有 StorageMaxItems，**没有 Capacity**
--   UConsumeStorageComponent : Capacity + Reserve + DisableItemSet（消费型，语义不同）
local STORAGE_DEFS = {
    { prop = "WarehouseStorage",        cn = "辎重类", cap = true,  maxItems = true,  demand = true  },
    { prop = "HospitalStorage",         cn = "医馆",   cap = true,  maxItems = true,  demand = false },
    { prop = "PoliceDepartmentStorage", cn = "乡亭",   cap = false, maxItems = true,  demand = false },
}

local function getStorageComp(actor)
    for _, d in ipairs(STORAGE_DEFS) do
        local c = prop(actor, d.prop)
        if isValid(c) then return c, d, "属性:" .. d.prop end
    end

    -- 兜底：按组件类名在全名里找
    local arr = callf(actor, "GetStorageComponents")
    if arr ~= nil then
        local found, fdef = nil, nil
        pcall(function()
            for _, sc in ipairs(arr) do
                local fn = callf(sc, "GetFullName")
                if type(fn) == "string" then
                    for _, d in ipairs(STORAGE_DEFS) do
                        if fn:find(d.prop .. "Component") then
                            found, fdef = sc, d
                            break
                        end
                    end
                end
                if found then break end
            end
        end)
        if isValid(found) then return found, fdef, "GetStorageComponents" end
    end
    return nil, nil, nil
end

-- 方位名（相对城心），让面板里能区分「哪一座辎重库」
local function dirLabel(dx, dy)
    if math.abs(dx) < 300 and math.abs(dy) < 300 then return "中" end
    local ax, ay = math.abs(dx), math.abs(dy)
    if ax > ay * 2 then return dx > 0 and "东" or "西" end
    if ay > ax * 2 then return dy > 0 and "北" or "南" end
    if dx > 0 then return dy > 0 and "东北" or "东南" end
    return dy > 0 and "西北" or "西南"
end

-- 库存读取
--   ReadMode = "getter"（默认）：只用 BlueprintPure 的 GetItemNum()，只读 int32，最安全
--   ReadMode = "array" ：迭代 TotalItemNumList.Items 一次拿全，但「读 TArray<USTRUCT>」
--                        在本作里是已知的风险路径（容器遍历），确认稳定后再开
local function readInventory(comp, want)
    local out = {}
    if C.ReadMode == "array" then
        local lst = prop(comp, "TotalItemNumList")
        if lst ~= nil then
            local arr = prop(lst, "Items")
            if arr ~= nil then
                local ok = pcall(function()
                    for _, p in ipairs(arr) do
                        local t = toNum(prop(p, "ItemType"))
                        local n = toNum(prop(p, "ItemNum"))
                        if t and n then out[t] = (out[t] or 0) + n end
                    end
                end)
                if ok then return out, "TotalItemNumList" end
            end
        end
    end
    for _, it in ipairs(Items) do
        if want == nil or want[it.id] then
            local n = toNum(callf(comp, "GetItemNum", it.id))
            if n and n > 0 then out[it.id] = n end
        end
    end
    return out, "GetItemNum"
end

local function buildItemList(store, cur)
    local seen, list = {}, {}
    for id in pairs(store.items) do
        if not seen[id] then seen[id] = true; list[#list + 1] = id end
    end
    for id, n in pairs(cur) do
        if n > 0 and not seen[id] and ItemById[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    table.sort(list, function(a, b)
        local na, nb = itemName(a), itemName(b)
        if na == nb then return a < b end
        return na < nb
    end)
    return list
end

local function scan()
    LastScan.errors = {}
    ScanCounter = ScanCounter + 1
    -- 逐项查询模式下，不必每轮都问 101 种物资：每 5 轮做一次全量，其余轮只问已知有货的
    local fullScan = (C.ReadMode == "array") or (ScanCounter % 5 == 1)
    local bs = getBuildingSubsystem()
    if not isValid(bs) then
        -- 不直接放弃：下面还有按类名枚举的兜底路径
        LastScan.errors[#LastScan.errors + 1] = "找不到 BuildingSubsystem（改用按类名枚举）"
    end

    -- 建筑列表来源：优先子系统数组；读不到就退到 FindAllOf（不依赖子系统）
    local pa = prop(bs, "AllPlayerBuildings")
    local ab = prop(bs, "AllBuildings")
    LastScan.playerSet = (pa ~= nil and not C.IncludeEnemy)

    -- 城心（用于给仓储建筑起方位名）
    local center = prop(bs, "BuildingCenter")
    local cx, cy = nil, nil
    if center ~= nil then
        cx = toNum(prop(center, "X"))
        cy = toNum(prop(center, "Y"))
    end

    local stores, byKey = {}, {}
    local invSource = "?"

    local function handle(actor, cfg)
        local nm = nameOfActor(actor)

        local comp, def, how = getStorageComp(actor)
        if not isValid(comp) then
            LastScan.errors[#LastScan.errors + 1] =
                buildingName(cfg) .. " 无仓储组件: " .. tostring(nm)
            return
        end

        local cap = toNum(callf(comp, "GetCapacity"))
        local total = toNum(callf(comp, "GetTotalItemNum"))

        local key = nm or string.format("pos_%d_%d", round((vecOf(actor) or {}).X or 0), 0)
        local store = Model.stores[key]

        -- 决定这轮要查哪些物资
        local want = nil
        if not fullScan then
            want = {}
            for id in pairs(KnownItems[key] or {}) do want[id] = true end
            if store then
                for id in pairs(store.items) do want[id] = true end
            end
        end
        local cur, src = readInventory(comp, want)
        invSource = src
        if total == nil then
            local t = 0
            for _, n in pairs(cur) do t = t + n end
            total = t
        end
        if fullScan then
            local s = {}
            for id in pairs(cur) do s[id] = true end
            KnownItems[key] = s
        end

        if not store then
            local v = vecOf(actor)
            store = newStore(key, buildingName(cfg), v and toNum(v.X) or 0,
                             v and toNum(v.Y) or 0, v and toNum(v.Z) or 0)
        end
        -- 坐标可能首次没取到，每轮补一次；并据城心生成方位名
        local v = vecOf(actor)
        if v ~= nil then
            store.x = toNum(prop(v, "X")) or store.x
            store.y = toNum(prop(v, "Y")) or store.y
            store.z = toNum(prop(v, "Z")) or store.z
        end
        if cx and cy and store.x and store.y then
            store.label = buildingName(cfg) .. dirLabel(store.x - cx, store.y - cy)
        elseif not store.label then
            store.label = buildingName(cfg)
        end
        -- 基准容量：表里有就以表为准（升级后也不会把封口值误当基准）
        local tableCap = BaseCap[cfg]
        if tableCap then
            if store.origCap ~= tableCap then
                if C.Verbose and store.origCap then
                    log(string.format("%s 基准容量 %s → %d（按表校正）",
                        tostring(store.label), tostring(store.origCap), tableCap))
                end
                store.origCap = tableCap
            end
        else
            if store.origCap == nil and cap then store.origCap = cap end
            -- 无表可查时才靠推断：容量变大且不是我们设的，视为升级
            if cap and store.origCap and store.lastSet ~= cap and cap > store.origCap then
                store.origCap = cap
            end
        end
        -- 记录 ConfigID，便于发现升级（日志/诊断用）
        if store.cfg == nil then store.cfg = cfg
        elseif store.cfg ~= cfg then
            log(string.format("%s 检测到建筑升级 %d → %d", tostring(store.label), store.cfg, cfg))
            store.cfg = cfg
            store.lastSet = nil
        end

        local rec = {
            key = key, actor = actor, comp = comp, cur = cur, cap = cap, total = total,
            label = store.label, cfg = cfg, how = how,
            mode = (readLogisticsMode(actor)),
            def = def,
            itemList = buildItemList(store, cur),
        }
        stores[#stores + 1] = rec
        byKey[key] = rec
    end

    -- 单次遍历：读一次 ConfigID，顺手统计建筑构成（面板「找不到」时用来诊断）
    local hist, totalBuildings, source = {}, 0, "无"

    local function passArray(arr, label)
        local n = 0
        pcall(function()
            for _, a in ipairs(arr) do
                local cfg = toNum(prop(a, "ConfigID"))
                if cfg then
                    n = n + 1
                    hist[cfg] = (hist[cfg] or 0) + 1
                    if STORE_IDS[cfg] then handle(a, cfg) end
                end
            end
        end)
        if n > 0 then source = label end
        return n
    end

    local done = false
    if pa ~= nil and not C.IncludeEnemy then
        totalBuildings = passArray(pa, "AllPlayerBuildings")
        done = totalBuildings > 0
    end
    if not done and ab ~= nil then
        totalBuildings = passArray(ab, "AllBuildings")
        done = totalBuildings > 0
    end
    -- 兜底：不依赖 BuildingSubsystem，直接按类名枚举 Actor
    -- ★ FindAllOf 是全对象扫描，主菜单/世界未加载时会遍历全部 UObject，
    --   实测会把 Lua 线程堵死（所有模组按键失灵）。默认关闭，需要时在 config 里开。
    -- 按类名逐个枚举（默认开启）：每个类一次 FindAllOf，只返回该类实例，
    -- 与全对象扫描是两回事。QoL 模组真机验证过此模式可用。
    if not done and not C.DisableClassScan then
        local n2 = 0
        for _, cls in ipairs(STORAGE_CLASSES) do
            local ok, arr = pcall(function() return FindAllOf(cls) end)
            if ok and arr ~= nil then
                n2 = n2 + passArray(arr, "类名:" .. cls)
            end
        end
        totalBuildings = n2
        done = n2 > 0
    end
    if not done and not C.AllowFullScan then
        LastScan.errors[#LastScan.errors + 1] =
            "BuildingSubsystem 数组为空，按类名枚举也未命中（AllowFullScan=false）"
    end
    if not done and C.AllowFullScan then
        if FallbackCache.arr ~= nil and (os.time() - FallbackCache.at) < 10 then
            totalBuildings = passArray(FallbackCache.arr, FallbackCache.kind)
            done = totalBuildings > 0
        else
            local ok1, a1 = pcall(function() return FindAllOf("MOBuildingBase") end)
            if ok1 and a1 ~= nil then
                totalBuildings = passArray(a1, "FindAllOf(MOBuildingBase)")
                if totalBuildings > 0 then
                    FallbackCache = { arr = a1, kind = "FindAllOf(MOBuildingBase)", at = os.time() }
                    done = true
                end
            end
            if not done then
                local ok2, a2 = pcall(function() return FindAllOf("InteractiveActorBase") end)
                if ok2 and a2 ~= nil then
                    totalBuildings = passArray(a2, "FindAllOf(InteractiveActorBase)")
                    if totalBuildings > 0 then
                        FallbackCache = { arr = a2, kind = "FindAllOf(InteractiveActorBase)", at = os.time() }
                        done = true
                    end
                end
            end
        end
    end

    LastScan.hist = hist
    LastScan.totalBuildings = totalBuildings
    LastScan.source = source
    LastScan.hasBS = isValid(bs)

    -- 按到玩家的距离排序（近的在前），便于选中
    local pawn = getPawn()
    local px, py = 0, 0
    if isValid(pawn) then
        local v = vecOf(pawn)
        if v then px, py = toNum(v.X) or 0, toNum(v.Y) or 0 end
    end
    local function dist(rec)
        local s = Model.stores[rec.key]
        if not s then return 1e18 end
        local dx, dy = (s.x or 0) - px, (s.y or 0) - py
        return dx * dx + dy * dy
    end
    table.sort(stores, function(a, b) return dist(a) < dist(b) end)

    LastScan.at = os.time()
    LastScan.stores = stores
    LastScan.byKey = byKey
    LastScan.invSource = invSource
    LastScan.playerSet = havePlayerSet
    return true
end

-- ============================================================================
-- 6. 执行器：容量闸门 / 原生镜像
-- ============================================================================

local EnforceStats = { gateSet = 0, gateRestore = 0, lastMsg = "", fails = 0 }

local function applyCapacityGate(rec)
    if not C.Enabled or C.DryRun then return end
    if C.EnforceMode ~= "capacity" then return end
    local comp, store = rec.comp, Model.stores[rec.key]
    if not isValid(comp) or not store then return end
    if countQuota(store) == 0 then return end
    if rec.def and not rec.def.cap then return end   -- 乡亭这类没有 Capacity 字段
    if rec.cap == nil or rec.total == nil then return end

    local allMet = storeAllMet(store, rec.cur)
    local want
    if allMet then
        want = rec.total                       -- 压到当前总量 = 游戏判定「已满」
    else
        want = store.origCap or rec.cap
    end
    if want == nil then return end
    if want < rec.total then want = rec.total end   -- 绝不低于现有库存

    if want ~= rec.cap then
        -- 注意：SetCapacity 是 void UFUNCTION，成功时返回 nil，
        -- 所以只能用 lastCallErr 判断成败，不能看返回值
        callf(comp, "SetCapacity", want)
        if lastCallErr == nil then
            store.lastSet = want
            if want == rec.total then
                EnforceStats.gateSet = EnforceStats.gateSet + 1
                EnforceStats.lastMsg = string.format("%s 已达标→封口(%d)", store.label or "辎重库", want)
            else
                EnforceStats.gateRestore = EnforceStats.gateRestore + 1
                EnforceStats.lastMsg = string.format("%s 恢复容量(%d)", store.label or "辎重库", want)
            end
            if C.Verbose then
                log(string.format("容量闸门 %s: %s → %d (total=%d)",
                    rec.key, tostring(rec.cap), want, rec.total))
            end
        else
            EnforceStats.fails = EnforceStats.fails + 1
            if C.Verbose then log("SetCapacity 失败: " .. tostring(lastCallErr)) end
        end
    end
end

-- ============================================================================
-- 6b. 原生写入：StorageMaxItems（每物品上限）+ RemoteDemandEntries（每物品需求/开关）
--     逆向依据（2026-10-18）
--       UStorageMaxItemsBaseComponent.StorageMaxItems : FMOItemNumList
--            { Items = [ { ItemType, ItemNum } ] }
--       UWarehouseStorageComponent.RemoteDemandEntries :
--            TArray<FWarehouseRemoteItemEntry{ ItemType, ItemNum, bEnabled }>
--     两者都是 BlueprintReadWrite + SaveGame，理论上可写。
--     限制：TArray 无法从 Lua 追加元素，只能改「已存在」的条目 —— 返回值会明说。
-- ============================================================================

local NativeState = { ok = nil, msg = "未尝试", maxOk = nil, demandOk = nil }

-- 在 FMOItemNumList.Items 里按 ItemType 找元素并写 ItemNum，写完回读校验
local function writePairArray(arr, id, value)
    local hit = false
    pcall(function()
        for _, p in ipairs(arr) do
            if toNum(prop(p, "ItemType")) == id then
                p.ItemNum = value
                hit = true
                break
            end
        end
    end)
    if not hit then return false end
    local got = nil
    pcall(function()
        for _, p in ipairs(arr) do
            if toNum(prop(p, "ItemType")) == id then
                got = toNum(prop(p, "ItemNum"))
                break
            end
        end
    end)
    return got == value
end

local function setMaxItems(rec, id, value)
    local lst = prop(rec.comp, "StorageMaxItems")
    if lst == nil then return false, "无 StorageMaxItems" end
    local arr = prop(lst, "Items")
    if arr == nil then return false, "无 StorageMaxItems.Items" end
    if writePairArray(arr, id, value) then return true end
    return false, "该物品无上限条目"
end

-- 在 RemoteDemandEntries 里写 ItemNum + bEnabled，写完回读校验
local function setDemand(rec, id, num, enabled)
    local arr = prop(rec.comp, "RemoteDemandEntries")
    if arr == nil then return false, "无 RemoteDemandEntries" end
    local hit = false
    pcall(function()
        for _, e in ipairs(arr) do
            if toNum(prop(e, "ItemType")) == id then
                e.ItemNum = num
                e.bEnabled = enabled
                hit = true
                break
            end
        end
    end)
    if not hit then return false, "该物品无需求条目" end
    local okNum, okEn = false, false
    pcall(function()
        for _, e in ipairs(arr) do
            if toNum(prop(e, "ItemType")) == id then
                okNum = (toNum(prop(e, "ItemNum")) == num)
                okEn = (prop(e, "bEnabled") == enabled)
                break
            end
        end
    end)
    return (okNum and okEn), (okNum and "" or "回读不一致")
end

local function applyNativeMirror(rec)
    if not C.Enabled or C.DryRun then return end
    if C.EnforceMode ~= "native" and not C.NativeMirror then return end
    local store = Model.stores[rec.key]
    if not store or countQuota(store) == 0 then return end

    local maxOk, maxFail, demOk, demFail = 0, 0, 0, 0
    local firstErr = nil
    for id, q in pairs(store.items) do
        local lim = limits(q)
        if lim ~= nil and (rec.def == nil or rec.def.maxItems) then
            local ok, msg = setMaxItems(rec, id, lim)
            if ok then maxOk = maxOk + 1 else maxFail = maxFail + 1; firstErr = firstErr or msg end
        end
        if q.mode == "block" and (rec.def == nil or rec.def.demand) then
            local ok, msg = setDemand(rec, id, 0, false)
            if ok then demOk = demOk + 1 else demFail = demFail + 1; firstErr = firstErr or msg end
        elseif q.mode == "target" and q.target and (rec.def == nil or rec.def.demand) then
            local ok, msg = setDemand(rec, id, q.target, true)
            if ok then demOk = demOk + 1 else demFail = demFail + 1; firstErr = firstErr or msg end
        end
    end

    NativeState.maxOk = (maxFail == 0)
    NativeState.demandOk = (demFail == 0)
    NativeState.ok = (maxFail == 0 and demFail == 0 and (maxOk + demOk) > 0)
    local parts = {}
    if maxOk + maxFail > 0 then
        parts[#parts + 1] = string.format("上限 %d/%d", maxOk, maxOk + maxFail)
    end
    if demOk + demFail > 0 then
        parts[#parts + 1] = string.format("需求 %d/%d", demOk, demOk + demFail)
    end
    NativeState.msg = (#parts > 0 and table.concat(parts, "  ") or "无配额")
    if firstErr then NativeState.msg = NativeState.msg .. "  (" .. firstErr .. ")" end
end

-- 写回自检：把原值写回去，验证这两个数组到底能不能写（不改变数据）
local function nativeSelfTest(rec, out)
    local function countOf(arr)
        local n = 0
        pcall(function() for _ in ipairs(arr) do n = n + 1 end end)
        return n
    end

    local lst = prop(rec.comp, "StorageMaxItems")
    local arr1 = lst and prop(lst, "Items")
    if arr1 == nil then
        out[#out + 1] = "StorageMaxItems.Items: ✘ 不可读"
    else
        out[#out + 1] = string.format("StorageMaxItems.Items: %d 条", countOf(arr1))
        local first = nil
        pcall(function() for _, p in ipairs(arr1) do first = p break end end)
        if first then
            local id = toNum(prop(first, "ItemType"))
            local cur = toNum(prop(first, "ItemNum"))
            if id and cur then
                local ok = writePairArray(arr1, id, cur)
                out[#out + 1] = string.format("  写回自检 item=%d 值=%d → %s",
                    id, cur, ok and "可写 ✔" or "只读/失败 ✘")
            end
        end
    end

    local supply = prop(rec.comp, "RemoteSupplyEntries")
    if supply ~= nil then
        out[#out + 1] = string.format("RemoteSupplyEntries: %d 条", countOf(supply))
    end

    local arr2 = prop(rec.comp, "RemoteDemandEntries")
    if arr2 == nil then
        out[#out + 1] = "RemoteDemandEntries: ✘ 不可读"
    else
        out[#out + 1] = string.format("RemoteDemandEntries: %d 条", countOf(arr2))
        local first = nil
        pcall(function() for _, e in ipairs(arr2) do first = e break end end)
        if first then
            local id = toNum(prop(first, "ItemType"))
            local num = toNum(prop(first, "ItemNum"))
            local en = prop(first, "bEnabled")
            if id and num ~= nil then
                local ok = setDemand(rec, id, num, en == true)
                out[#out + 1] = string.format("  写回自检 item=%d num=%d enabled=%s → %s",
                    id, num, tostring(en), ok and "可写 ✔" or "只读/失败 ✘")
            end
        end
        out[#out + 1] = "  说明：TArray 无法从 Lua 追加，只能改已有条目；" ..
            "某物品若没配过需求，需先在游戏面板加一条"
    end
end

-- ============================================================================
-- 7. 路线/在途审计（尽力而为）
-- ============================================================================

local function incomingOf(rec, id)
    local ls = getLogisticsSubsystem()
    if not isValid(ls) then return nil end
    local n = callf(ls, "GetInTransitIncomingAmount", rec.actor, id)
    return toNum(n)
end

-- ============================================================================
-- 8. HUD
-- ============================================================================

local hudOverlay, hudCanvas, hudBorder, hudText = nil, nil, nil, nil
local hudUntil = 0

local function SafeConstructObject(className, outer, name)
    local cls = StaticFindObject(className)
    if not isValid(cls) then return CreateInvalidObject() end
    local ok, o = pcall(function() return StaticConstructObject(cls, outer, FName(name)) end)
    if ok and o ~= nil then return o end
    return CreateInvalidObject()
end

local function buildHud()
    if isValid(hudText) then return end
    local ok, gi = pcall(function() return UEHelpers.GetGameInstance() end)
    if not ok or not isValid(gi) then return end

    hudOverlay = SafeConstructObject("/Script/UMG.UserWidget", gi, "FengShaQuotaHud")
    if not isValid(hudOverlay) then return end
    hudOverlay.WidgetTree = SafeConstructObject("/Script/UMG.WidgetTree", hudOverlay, "FengShaQuotaHudTree")
    hudCanvas = SafeConstructObject("/Script/UMG.CanvasPanel", hudOverlay.WidgetTree, "FengShaQuotaHudCanvas")
    hudOverlay.WidgetTree.RootWidget = hudCanvas

    hudBorder = SafeConstructObject("/Script/UMG.Border", hudCanvas, "FengShaQuotaHudBorder")
    pcall(function() hudBorder:SetBrushColor({ R = 0.03, G = 0.05, B = 0.10, A = 0.90 }) end)
    pcall(function() hudBorder:SetPadding({ Left = 16, Top = 12, Right = 16, Bottom = 12 }) end)

    hudText = SafeConstructObject("/Script/UMG.TextBlock", hudBorder, "FengShaQuotaHudText")
    if isValid(hudText) then
        pcall(function() hudText.Font.Size = 16 end)
        pcall(function() hudText:SetColorAndOpacity({ SpecifiedColor = { R = 0.95, G = 0.93, B = 0.85, A = 1 }, ColorUseRule = 0 }) end)
    end
    pcall(function() hudBorder:SetContent(hudText) end)

    local okSlot, slot = pcall(function() return hudCanvas:AddChildToCanvas(hudBorder) end)
    if okSlot and slot then
        pcall(function() slot:SetAutoSize(true) end)
        pcall(function() slot:SetAnchors({ Minimum = { X = 0.5, Y = 0 }, Maximum = { X = 0.5, Y = 0 } }) end)
        pcall(function() slot:SetAlignment({ X = 0.5, Y = 0 }) end)
        pcall(function() slot:SetPosition({ X = 0, Y = 90 }) end)
    end
    pcall(function() hudOverlay:AddToViewport(94) end)
end

local function HUD(msg, seconds)
    buildHud()
    if not isValid(hudText) then
        log(msg)
        return
    end
    local t = mkText(msg)
    if t == nil then log(msg) return end
    pcall(function() hudText:SetText(t) end)
    pcall(function() hudBorder:SetVisibility(4) end)
    hudUntil = os.time() + (seconds or math.floor(C.HudMs / 1000))
end

-- ============================================================================
-- 9. 面板
-- ============================================================================

local Sel = { storeIdx = 1, itemIdx = 1, tplIdx = 1, view = 1 }

local TEMPLATE_ORDER = { "均衡", "粮食优先", "建造储备", "备战储备" }

local function builtinTemplates()
    return {
        ["均衡"] = {
            [1] = 300, [2] = 200, [3] = 300, [14] = 200, [16] = 150, [17] = 150,
            [8] = 100, [9] = 60, [4] = 200, [5] = 100, [41] = 200, [42] = 100,
            [30] = 300, [32] = 300, [33] = 300, [34] = 200, [44] = 150, [90] = 80,
            [66] = 80, [84] = 80, [80] = 80, [81] = 80, [82] = 80,
        },
        ["粮食优先"] = {
            [30] = 600, [32] = 600, [33] = 600, [34] = 400, [44] = 300, [46] = 100,
            [54] = 100, [55] = 100, [90] = 150, [47] = 100, [72] = 80,
            [1] = 120, [3] = 120, [14] = 120,
        },
        ["建造储备"] = {
            [1] = 600, [2] = 400, [3] = 500, [14] = 500, [16] = 300, [17] = 400,
            [82] = 300, [81] = 300, [80] = 200, [84] = 200, [51] = 100, [42] = 200,
        },
        ["备战储备"] = {
            [18] = 100, [19] = 100, [20] = 100, [21] = 100, [57] = 500, [58] = 300,
            [25] = 80, [26] = 80, [27] = 80, [28] = 60, [29] = 60, [51] = 80,
            [52] = 200, [50] = 80, [62] = 30, [63] = 20, [64] = 10, [65] = 10,
            [8] = 200, [10] = 150, [44] = 300, [30] = 400, [32] = 400, [33] = 400,
        },
    }
end

local Templates = nil
local function getTemplates()
    if Templates == nil then
        Templates = builtinTemplates()
        -- 用户自定义模板从数据文件合并
        for name, tpl in pairs(Model.templates or {}) do
            Templates[name] = tpl
        end
    end
    return Templates
end

local function currentStore()
    local s = LastScan.stores[Sel.storeIdx]
    return s, (s and Model.stores[s.key]) or nil
end

local VIEW_NAMES = { "按库", "按物资", "异常" }

local function panelText()
    local L = {}
    local function w(s) L[#L + 1] = s end

    w("==============================================")
    w(string.format("   烽沙 · 辎重配额   v%s", VERSION))
    w("==============================================")

    local stores = LastScan.stores
    if #stores == 0 then
        w("")
        if ScanPending then
            w("扫描中…")
        else
            w("没有找到仓储建筑（辎重库 / 粮仓 / 军械库）")
            w("")
            if not LastScan.hasBS then
                w("BuildingSubsystem: ✘ 找不到")
                w("")
                w("★ 最常见原因：还在主菜单 / 读档没完成。")
                w("  这个模组只在『已经进入游戏世界』时才能读到建筑。")
                w("  请先载入一个存档，看到自己的城之后再按 Ctrl+Q。")
            else
                w("BuildingSubsystem: OK")
            end
            w(string.format("建筑总数 %d   来源=%s", LastScan.totalBuildings or 0,
                tostring(LastScan.source or "?")))
            if (LastScan.totalBuildings or 0) == 0 then
                w("")
                w("（读不到建筑列表 —— 把 Ctrl+Shift+V 的 diag 发我）")
            end
            if LastScan.errors and #LastScan.errors > 0 then
                w("")
                w("[错误]")
                for i = 1, math.min(#LastScan.errors, 3) do
                    w("  " .. LastScan.errors[i])
                end
            end
            local ids = {}
            for id in pairs(LastScan.hist or {}) do ids[#ids + 1] = id end
            table.sort(ids, function(a, b)
                return (LastScan.hist[a] or 0) > (LastScan.hist[b] or 0)
            end)
            if #ids > 0 then
                w("")
                w("[存档里的建筑]")
                for i = 1, math.min(#ids, 10) do
                    w(string.format("  %s ×%d", pad(buildingName(ids[i]), 12), LastScan.hist[ids[i]]))
                end
            end
            w("")
            w("上面没有辎重库/粮仓/军械库 → 先建一座再来")
            w("明明有却没列出来 → Ctrl+Shift+V 诊断")
        end
        return table.concat(L, "\n")
    end

    if Sel.storeIdx > #stores then Sel.storeIdx = 1 end
    local rec, store = currentStore()

    w(string.format("[%s] 共 %d 座   模式:%s%s",
        VIEW_NAMES[Sel.view] or "按库", #stores,
        C.EnforceMode, C.DryRun and " 演练" or ""))

    local function shortLabel(i, r)
        return pad(string.format("%s#%d", r.label or "辎重库", i), 12)
    end

    if Sel.view == 2 then
        ---------------------------------------------------------------- 按物资
        local id = rec and rec.itemList and rec.itemList[Sel.itemIdx]
        if not id then
            w("  该库没有可显示的物资")
        else
            w(string.format("物资：%s   （Ctrl+Shift+W 换物资）", itemName(id)))
            w("")
            local n = 0
            for i, r in ipairs(stores) do
                local s = Model.stores[r.key]
                local cur = r.cur[id] or 0
                local q = s and s.items[id]
                if cur > 0 or q then
                    local code, text = statusOf(q, cur)
                    local tgt = "-"
                    if q then
                        if q.mode == "block" then tgt = "禁止"
                        elseif q.mode == "target" then tgt = tostring(q.target or "-")
                        elseif q.cap then tgt = "上限" .. tostring(q.cap) end
                    end
                    w(string.format("%s %5d / %-6s %s", shortLabel(i, r), cur, tgt, text))
                    n = n + 1
                end
            end
            if n == 0 then w("  所有辎重库都没有这种物资，也没设配额") end
            w("")
            w(string.format("合计 %d 座有库存/配额", n))
        end

    elseif Sel.view == 3 then
        ---------------------------------------------------------------- 异常
        local n = 0
        for i, r in ipairs(stores) do
            local s = Model.stores[r.key]
            if s then
                local ids = {}
                for id in pairs(s.items) do ids[#ids + 1] = id end
                table.sort(ids)
                for _, id in ipairs(ids) do
                    local cur = r.cur[id] or 0
                    local code, text = statusOf(s.items[id], cur)
                    if code ~= "target" then          -- 已达目标不算异常
                        w(string.format("  %s %s %5d  %s",
                            shortLabel(i, r), pad(itemName(id), 10), cur, text))
                        n = n + 1
                        if n >= 20 then break end
                    end
                end
            end
            if n >= 20 then break end
        end
        if n == 0 then
            w("")
            w("  没有需要关注的条目（禁止存入 / 达上限 / 缺口 / 冲突 会出现在这里）")
        elseif n >= 20 then
            w("  … 只显示前 20 条")
        end

    else
        ---------------------------------------------------------------- 按库
        for i, r in ipairs(stores) do
            if i > C.MaxStoresInList then
                w(string.format("  … 另有 %d 座", #stores - C.MaxStoresInList))
                break
            end
            local s = Model.stores[r.key]
            local qn = s and countQuota(s) or 0
            local met = s and storeAllMet(s, r.cur) or false
            w(string.format("%s #%d %s %d/%s  %s",
                (i == Sel.storeIdx) and "▶" or " ",
                i,
                pad((r.label or "辎重库") .. (r.cfg == 2 and "" or ("·" .. tostring(r.cfg))), 14),
                r.total or 0,
                tostring(r.cap or "?"),
                qn > 0 and (met and "配额全达标" or string.format("配额%d项", qn)) or "无配额"))
        end

        if not rec or not store then return table.concat(L, "\n") end

        w("")
        local modeTxt = ""
        if rec.mode ~= nil then
            modeTxt = "   物流=" .. tostring(rec.mode) ..
                (MODE_CN[tostring(rec.mode)] and ("(" .. MODE_CN[tostring(rec.mode)] .. ")") or "")
        end
        local typeTxt = (rec.def and rec.def.cn) and ("   [" .. rec.def.cn .. "]") or ""
        local noCap = rec.def and rec.def.cap == false
        if noCap then
            -- 乡亭这类组件没有 Capacity 字段：不显示容量，明确提示能力边界
            w(string.format("[明细] %s%s   库存 %d%s", store.label or rec.key,
                typeTxt, rec.total or 0, modeTxt))
            w("   ⚠ 该建筑仓储组件无 Capacity 字段：容量闸门不可用")
            w("     只支持「逐物品上限」（EnforceMode = native）")
        else
            w(string.format("[明细] %s%s   库存 %d / %s%s", store.label or rec.key,
                typeTxt, rec.total or 0, tostring(rec.cap or "?"), modeTxt))
        end

        local list = rec.itemList or {}
        if #list == 0 then
            w("  该库为空，且没有设置任何配额")
        end
        if #list > 0 then
            local startIdx = math.max(1, Sel.itemIdx - 6)
            local endIdx = math.min(#list, startIdx + 12)
            if startIdx > 1 then w("  …") end
            for i = startIdx, endIdx do
                local id = list[i]
                local q = store.items[id]
                local cur = rec.cur[id] or 0
                local code, text = statusOf(q, cur)
                local tgt = "-"
                if q then
                    if q.mode == "block" then tgt = "禁止"
                    elseif q.mode == "target" then tgt = tostring(q.target or "-")
                    elseif q.cap then tgt = "上限" .. tostring(q.cap) end
                end
                local line = string.format("%s %s %5d / %-6s %s",
                    (i == Sel.itemIdx) and "▶" or " ", pad(itemName(id), 10),
                    cur, tgt, text)
                if C.ShowIncoming and i == Sel.itemIdx then
                    local inc = incomingOf(rec, id)
                    if inc and inc > 0 then line = line .. string.format("  在途%d", inc) end
                end
                w(line)
            end
            if endIdx < #list then
                w(string.format("  … 共 %d 项物资（Ctrl+Shift+W 切换）", #list))
            end
        end
    end

    w("")
    w("Ctrl+Shift+Q 换库  W 换物资  G 换视图  E/D 目标±" .. C.TargetStep)
    w("F 禁止存入  C 复制到下一座  T 套模板  X 重置")
    w("Ctrl+Q 关闭    Ctrl+Shift+V 诊断")
    if EnforceStats.lastMsg ~= "" then
        w("[最近] " .. EnforceStats.lastMsg)
    end
    if C.EnforceMode == "native" or C.NativeMirror then
        w("[原生] " .. tostring(NativeState.msg))
    end
    return table.concat(L, "\n")
end

local panelOverlay, panelCanvas, panelBorder, panelText_ = nil, nil, nil, nil
local panelVisible = false
local ScanPending = false

local function buildPanel()
    if isValid(panelText_) then return true end
    local ok, gi = pcall(function() return UEHelpers.GetGameInstance() end)
    if not ok or not isValid(gi) then return false end
    panelOverlay = SafeConstructObject("/Script/UMG.UserWidget", gi, "FengShaQuotaPanel")
    if not isValid(panelOverlay) then return false end
    panelOverlay.WidgetTree = SafeConstructObject("/Script/UMG.WidgetTree", panelOverlay, "FengShaQuotaPanelTree")
    panelCanvas = SafeConstructObject("/Script/UMG.CanvasPanel", panelOverlay.WidgetTree, "FengShaQuotaPanelCanvas")
    panelOverlay.WidgetTree.RootWidget = panelCanvas
    panelBorder = SafeConstructObject("/Script/UMG.Border", panelCanvas, "FengShaQuotaPanelBorder")
    pcall(function() panelBorder:SetBrushColor({ R = 0.02, G = 0.025, B = 0.05, A = 0.92 }) end)
    pcall(function() panelBorder:SetPadding({ Left = 18, Top = 14, Right = 18, Bottom = 14 }) end)
    panelText_ = SafeConstructObject("/Script/UMG.TextBlock", panelBorder, "FengShaQuotaPanelText")
    if isValid(panelText_) then
        pcall(function() panelText_.Font.Size = 14 end)
        pcall(function() panelText_:SetColorAndOpacity({ SpecifiedColor = { R = 0.92, G = 0.92, B = 0.97, A = 1 }, ColorUseRule = 0 }) end)
    end
    pcall(function() panelBorder:SetContent(panelText_) end)
    local okSlot, slot = pcall(function() return panelCanvas:AddChildToCanvas(panelBorder) end)
    if okSlot and slot then
        pcall(function() slot:SetAutoSize(true) end)
        pcall(function() slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } }) end)
        pcall(function() slot:SetAlignment({ X = 0, Y = 0 }) end)
        pcall(function() slot:SetPosition({ X = 24, Y = 60 }) end)
    end
    pcall(function() panelOverlay:AddToViewport(95) end)
    -- 探针：运行时构造的 UMG 经常 AddToViewport 后仍不在视口里
    local inVp = nil
    pcall(function() inVp = panelOverlay:IsInViewport() end)
    log("面板 widget 已创建，IsInViewport = " .. tostring(inVp) ..
        (inVp == false and "（不进视口 → 请用 dumps\\panel_*.txt 看内容）" or ""))
    return true
end

local LastPanelText = nil

local function refreshPanel()
    if not panelVisible then return end
    if not buildPanel() then return end
    local s = panelText()
    if s == LastPanelText then return end          -- 内容没变就不重设文本（省掉一次 UMG 布局）
    LastPanelText = s
    local t = mkText(s)
    if t then pcall(function() panelText_:SetText(t) end) end
end

local function setPanelVisible(v)
    panelVisible = v
    if not buildPanel() then
        log("面板创建失败（可能不在游戏世界）")
        return
    end
    if isValid(panelBorder) then
        pcall(function() panelBorder:SetVisibility(v and 4 or 2) end)
    end
    if v then
        -- 先用现有数据把面板画出来，扫描放到下一个 tick 去做（避免按键瞬间卡一下）
        if #LastScan.stores == 0 then ScanPending = true end
        refreshPanel()
        -- ★ 运行时构造的 UMG 不一定能进视口，所以同时落到文件 + 控制台，
        --   保证「按了键一定看得到内容」
        local okW, txt = pcall(panelText)
        if okW and type(txt) == "string" then
            local path = DUMP_DIR .. "\\panel_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
            writeFile(path, txt .. "\n")
            log("面板内容已写入 " .. path)
            print("\n" .. txt .. "\n")
        end
        ExecuteInGameThreadWithDelay(30, function()
            local ok, err = pcall(function() scan() end)
            ScanPending = false
            if not ok then log("面板扫描异常: " .. tostring(err)) end
            refreshPanel()
        end)
    end
    log("面板: " .. (v and "显示" or "隐藏"))
end

-- ============================================================================
-- 10. 操作
-- ============================================================================

local function ensureScanned()
    if os.time() - LastScan.at >= 2 or #LastScan.stores == 0 then scan() end
    return #LastScan.stores > 0
end

local function curSel()
    if not ensureScanned() then return nil, nil, nil end
    local rec, store = currentStore()
    return rec, store, (rec and rec.itemList and rec.itemList[Sel.itemIdx]) or nil
end

local function opNextStore()
    local n = #LastScan.stores
    if n == 0 then return end
    Sel.storeIdx = Sel.storeIdx % n + 1
    Sel.itemIdx = 1
    refreshPanel()
    local rec, store = currentStore()
    local hudType = (rec.def and rec.def.cn) and ("·" .. rec.def.cn) or ""
    if rec.def and rec.def.cap == false then
        HUD(string.format("选中 #%d %s%s（库存 %d，无容量闸门）", Sel.storeIdx,
            (store and store.label) or "仓储", hudType, rec.total or 0))
    else
        HUD(string.format("选中 #%d %s%s（库存 %d/%s）", Sel.storeIdx,
            (store and store.label) or "仓储", hudType, rec.total or 0, tostring(rec.cap or "?")))
    end
end

local function opNextItem()
    local rec, store = curSel()
    if not rec then return end
    local n = #(rec.itemList or {})
    if n == 0 then HUD("该库没有可设置的物资") return end
    Sel.itemIdx = Sel.itemIdx % n + 1
    refreshPanel()
    local id = rec.itemList[Sel.itemIdx]
    HUD(string.format("%s：当前 %d", itemName(id), rec.cur[id] or 0))
end

local function opAdjust(delta)
    local rec, store, id = curSel()
    if not rec or not store or not id then HUD("先选中一座辎重库") return end
    local cur = rec.cur[id] or 0
    local q = store.items[id]
    if q == nil or q.mode == "unlimited" then
        q = { mode = "target", target = cur + C.TargetStep, cap = nil }
        store.items[id] = q
    elseif q.mode == "block" then
        q = { mode = "target", target = cur + C.TargetStep, cap = q.cap }
        store.items[id] = q
    else
        q.target = math.max(0, (q.target or 0) + delta)
        if q.target <= 0 and q.cap == nil then
            store.items[id] = nil
            q = nil
        end
    end
    saveModel()
    if q then
        local _, text = statusOf(q, cur)
        HUD(string.format("%s 目标 %d（%s）", itemName(id), q.target, text))
    else
        HUD(string.format("%s 已恢复为游戏默认", itemName(id)))
    end
    scan(); refreshPanel()
end

local function opToggleBlock()
    local rec, store, id = curSel()
    if not rec or not store or not id then HUD("先选中一座辎重库") return end
    local q = store.items[id]
    if q and q.mode == "block" then
        store.items[id] = nil
        HUD(string.format("%s 取消禁止存入", itemName(id)))
    else
        store.items[id] = { mode = "block", target = nil, cap = q and q.cap or nil }
        HUD(string.format("%s 已设为禁止存入", itemName(id)))
    end
    saveModel(); scan(); refreshPanel()
end

local function opCopy()
    local rec, store = curSel()
    if not rec or not store then HUD("先选中一座辎重库") return end
    local n = #LastScan.stores
    if n < 2 then HUD("只有一座辎重库，无可复制目标") return end
    local tgtRec = LastScan.stores[Sel.storeIdx % n + 1]
    local tgt = Model.stores[tgtRec.key]
    if not tgt then HUD("目标库数据缺失") return end
    local cnt = 0
    for id, q in pairs(store.items) do
        tgt.items[id] = { mode = q.mode, target = q.target, cap = q.cap }
        cnt = cnt + 1
    end
    saveModel(); scan(); refreshPanel()
    HUD(string.format("已把 %d 项配额复制到 %s", cnt, tgt.label or tgtRec.key))
end

local function opTemplate()
    local rec, store = curSel()
    if not rec or not store then HUD("先选中一座辎重库") return end
    local tpls = getTemplates()
    local name = TEMPLATE_ORDER[Sel.tplIdx]
    Sel.tplIdx = Sel.tplIdx % #TEMPLATE_ORDER + 1
    local tpl = tpls[name]
    if not tpl then HUD("模板缺失: " .. tostring(name)) return end
    store.items = {}
    local cnt = 0
    for id, target in pairs(tpl) do
        if ItemById[id] then
            store.items[id] = { mode = "target", target = target, cap = nil }
            cnt = cnt + 1
        end
    end
    saveModel(); scan(); refreshPanel()
    HUD(string.format("已套用模板「%s」：%d 项", name, cnt))
end

local function opReset()
    local rec, store = curSel()
    if not rec or not store then HUD("先选中一座辎重库") return end
    local n = countQuota(store)
    store.items = {}
    saveModel()
    -- 立刻恢复容量
    if isValid(rec.comp) and store.origCap then
        callf(rec.comp, "SetCapacity", math.max(store.origCap, rec.total or 0))
        store.lastSet = nil
    end
    scan(); refreshPanel()
    HUD(string.format("已重置 %s（清掉 %d 项配额）", store.label or rec.key, n))
end

-- ============================================================================
-- 11. 诊断
-- ============================================================================

local function diagnostics()
    ensureDir(DUMP_DIR)
    local L = {}
    local function w(s) L[#L + 1] = s end
    -- 先落一个「正在进行」的文件：即使后面卡住/崩溃，也能看到做到哪一步
    local earlyPath = DUMP_DIR .. "\\diag_" .. os.date("%Y%m%d_%H%M%S") .. "_RUNNING.txt"
    local function flush()
        writeFile(earlyPath, table.concat(L, "\n") .. "\n")
    end
    w("FengShaQuota v" .. VERSION .. "  诊断 " .. os.date("%Y-%m-%d %H:%M:%S"))
    w(string.format("配置: Enabled=%s EnforceMode=%s DryRun=%s Step=%d",
        tostring(C.Enabled), tostring(C.EnforceMode), tostring(C.DryRun), C.TargetStep))
    w("")

    local bs = getBuildingSubsystem()
    w("BuildingSubsystem: " .. (isValid(bs) and "OK" or "缺失"))
    local ls = getLogisticsSubsystem()
    w("LogisticsSubsystem: " .. (isValid(ls) and "OK" or "缺失"))
    w("")

    -- 逐条探测枚举路径（每条都写清「有没有 / 多少个」）
    w("=== 建筑枚举路径探测 ===")
    local function probe(label, fn)
        local ok, v = pcall(fn)
        if not ok then
            w(string.format("  %-34s 抛异常: %s", label, tostring(v):sub(1, 60)))
            return
        end
        if v == nil then
            w(string.format("  %-34s nil（读不到）", label))
            return
        end
        local n = 0
        pcall(function() for _ in ipairs(v) do n = n + 1 end end)
        w(string.format("  %-34s %d 个", label, n))
        flush()
    end
    probe("bs.AllPlayerBuildings", function() return prop(bs, "AllPlayerBuildings") end)
    probe("bs.AllBuildings",        function() return prop(bs, "AllBuildings") end)
    if C.AllowFullScan then
        probe("FindAllOf(MOBuildingBase)",        function() return FindAllOf("MOBuildingBase") end)
        probe("FindAllOf(InteractiveActorBase)",  function() return FindAllOf("InteractiveActorBase") end)
        probe("FindAllOf(MOBuildingBaseV2)",      function() return FindAllOf("MOBuildingBaseV2") end)
    else
        w("  FindAllOf 探针已跳过（全对象扫描会堵死线程，AllowFullScan=false）")
    end
    w("")

    scan()
    flush()
    w(string.format("扫描结果: %d 座仓储建筑（来源=%s，建筑总数=%d，库存来源=%s）",
        #LastScan.stores, tostring(LastScan.source), LastScan.totalBuildings or 0,
        LastScan.invSource))
    for i, r in ipairs(LastScan.stores) do
        local s = Model.stores[r.key]
        w(string.format("  #%d key=%s cfg=%d 组件=%s 库存=%d 容量=%s 配额=%d 基准容量=%s 物流=%s",
            i, r.key, r.cfg, tostring(r.how), r.total or -1, tostring(r.cap),
            s and countQuota(s) or 0, tostring(s and s.origCap), tostring(r.mode)))
        -- 前 6 项库存明细
        local ids = {}
        for id, n in pairs(r.cur) do ids[#ids + 1] = id end
        table.sort(ids)
        local parts = {}
        for k = 1, math.min(#ids, 8) do
            parts[#parts + 1] = string.format("%s=%d", itemName(ids[k]), r.cur[ids[k]])
        end
        if #parts > 0 then w("      " .. table.concat(parts, " ")) end
    end
    w("")

    -- 原生字段可写性自检：把原值写回去，验证是否可写（不改变数据）
    local rec = LastScan.stores[Sel.storeIdx]
    if rec then
        if C.SelfTestWriteback then
            w("=== 原生字段写回自检（会写数组元素，崩溃风险）===")
            local ok = pcall(function() nativeSelfTest(rec, L) end)
            if not ok then w("  自检执行异常（已拦截）") end
        else
            w("=== 原生字段写回自检：已跳过 ===")
            w("  上次开启时游戏在诊断瞬间退出，怀疑是写数组元素导致")
            w("  确认要试：config.txt 里设 SelfTestWriteback = true")
        end
        w("")
        w("RemoteSupplyEntries: " ..
            (prop(rec.comp, "RemoteSupplyEntries") ~= nil and "可读" or "不可读"))
        local inc = incomingOf(rec, 1)
        w("GetInTransitIncomingAmount(木板): " .. tostring(inc))
        w("")
    end

    if #LastScan.errors > 0 then
        w("=== 错误 ===")
        for i = 1, math.min(#LastScan.errors, 20) do w("  " .. LastScan.errors[i]) end
    end

    local path = DUMP_DIR .. "\\diag_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
    writeFile(path, table.concat(L, "\n") .. "\n")
    pcall(function() os.remove(earlyPath) end)
    log("诊断已写入 " .. path)
    HUD("诊断已写入 dumps\\" .. path:match("[^\\]+$"))
end

-- ============================================================================
-- 12. 主循环
-- ============================================================================

local SlowScans = 0

-- 只读模式（EnforceMode=off）且面板没开时，完全不做扫描：
-- 让「第一次装、只想看看」这件事对帧率零开销
local function idleSkip()
    if C.LazyWhenIdle and C.EnforceMode == "off" and not panelVisible then
        return true
    end
    return false
end

local FirstScanDone = false

local function tick()
    -- 整轮用 pcall 兜住：任何一次异常都不能让循环断掉，更不能把游戏线程带崩
    local t0 = os.clock()
    local ok, err = pcall(function()
        if not C.Enabled then return end
        if idleSkip() then return end
        if getPC() == nil then return end
        -- 只读模式下数据变化不急，5 秒刷一次就够，进一步降低开销
        if C.EnforceMode == "off" and panelVisible and (os.time() - (LastScan.at or 0)) < 5 then
            refreshPanel()
            return
        end
        local scanned = scan()
        if scanned then
            for _, rec in ipairs(LastScan.stores) do
                applyCapacityGate(rec)
                applyNativeMirror(rec)
            end
            refreshPanel()
            -- 只打一次：确认「扫描跑完了」而不是「卡在扫描里」
            if not FirstScanDone then
                FirstScanDone = true
                log(string.format("首次扫描完成：%d 座辎重库，库存来源=%s，耗时 %.0f ms",
                    #LastScan.stores, tostring(LastScan.invSource), (os.clock() - t0) * 1000))
            end
        end
    end)
    local dt = os.clock() - t0
    if not ok then
        log("本轮扫描异常（已跳过）: " .. tostring(err))
    elseif dt > 0.08 then
        -- 单轮超过 80ms 就会明显掉帧：自动降频
        SlowScans = SlowScans + 1
        if SlowScans <= 3 then
            log(string.format("扫描耗时 %.0f ms，自动降频到 %d ms", dt * 1000,
                math.max(C.ScanIntervalMs * 2, 6000)))
        end
        C.ScanIntervalMs = math.max(C.ScanIntervalMs * 2, 6000)
    end

    -- HUD 自动隐藏
    if hudUntil > 0 and os.time() > hudUntil then
        hudUntil = 0
        if isValid(hudBorder) then pcall(function() hudBorder:SetVisibility(2) end) end
    end
    ExecuteInGameThreadWithDelay(C.ScanIntervalMs, tick)
end

-- ============================================================================
-- 13. 启动
-- ============================================================================

loadItems()
loadBuildings()
loadBaseCaps()
ensureDir(DATA_DIR)
ensureDir(DUMP_DIR)
loadModel()

log(string.format("已加载 v%s  启用=%s 模式=%s 演练=%s 步长=%d",
    VERSION, tostring(C.Enabled), C.EnforceMode, tostring(C.DryRun), C.TargetStep))
log("Ctrl+Q 面板 / Ctrl+Shift+Q 换库 / Ctrl+Shift+W 换物资 / Ctrl+Shift+E·D 调目标")
log("Ctrl+Shift+F 禁止存入 / C 复制 / T 模板 / X 重置 / V 诊断")

RegisterKeyBind(Key.Q, { ModifierKey.CONTROL }, function()
    log("[键] Ctrl+Q 面板")
    setPanelVisible(not panelVisible)
end)

RegisterKeyBind(Key.Q, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    log("[键] Ctrl+Shift+Q 换库")
    if not ensureScanned() then HUD("没找到辎重库") return end
    opNextStore()
end)

RegisterKeyBind(Key.W, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    log("[键] Ctrl+Shift+W 换物资")
    opNextItem()
end)

RegisterKeyBind(Key.E, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    log("[键] Ctrl+Shift+E 目标+")
    opAdjust(C.TargetStep)
end)

RegisterKeyBind(Key.D, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    log("[键] Ctrl+Shift+D 目标-")
    opAdjust(-C.TargetStep)
end)

RegisterKeyBind(Key.F, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    log("[键] Ctrl+Shift+F 禁止存入")
    opToggleBlock()
end)

RegisterKeyBind(Key.C, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    log("[键] Ctrl+Shift+C 复制配额")
    opCopy()
end)

RegisterKeyBind(Key.T, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    log("[键] Ctrl+Shift+T 套模板")
    opTemplate()
end)

RegisterKeyBind(Key.X, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    log("[键] Ctrl+Shift+X 重置")
    opReset()
end)

RegisterKeyBind(Key.G, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    log("[键] Ctrl+Shift+G 换视图")
    Sel.view = (Sel.view or 1) % 3 + 1
    refreshPanel()
    HUD("视图：" .. (VIEW_NAMES[Sel.view] or "按库"))
end)

RegisterKeyBind(Key.V, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    log("[键] Ctrl+Shift+V 诊断")
    diagnostics()
end)

ExecuteInGameThreadWithDelay(C.ScanIntervalMs, tick)

-- ============================================================================
-- 14. 离线单测钩子
-- ============================================================================
if _G.__FSQ_TEST then
    _G.FSQ_TEST = {
        statusOf = statusOf,
        limits = limits,
        storeAllMet = storeAllMet,
        serializeModel = serializeModel,
        parseModel = parseModel,
        newStore = function(key, label) return newStore(key, label, 0, 0, 0) end,
        getModel = function() return Model end,
        setModel = function(m) Model = m end,
        builtinTemplates = builtinTemplates,
        C = C,
        -- 运行时（mock 引擎用）
        scan = scan,
        panelText = panelText,
        applyCapacityGate = applyCapacityGate,
        opAdjust = opAdjust,
        opToggleBlock = opToggleBlock,
        opCopy = opCopy,
        opTemplate = opTemplate,
        opReset = opReset,
        applyNativeMirror = applyNativeMirror,
        setMaxItems = setMaxItems,
        setDemand = setDemand,
        nativeSelfTest = nativeSelfTest,
        lastScan = function() return LastScan end,
        sel = function() return Sel end,
        resetSel = function() Sel.storeIdx = 1; Sel.itemIdx = 1; Sel.view = 1 end,
    }
    print("[FengShaQuota] 测试钩子已导出\n")
end
