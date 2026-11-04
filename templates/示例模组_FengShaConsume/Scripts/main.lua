--[[
================================================================================
  《烽沙》消耗点调参  FengShaConsume  v1.0
  纯 UE4SS Lua 模组 —— 只写 int32 字段，不碰容器

  背景（逆向结论，2026-10-25）
    民居 / 伙房 / 水井 / 国社 的存储是 UConsumeStorageComponent：
        int32 Capacity;
        bool  bAllowUserSetReserve;
        int32 ReserveMax / ReserveMin / ReserveDefault;
        int32 CurrentReserve;              ← 当前实际保留量
        TSet<EMOItemType> DisableItemSet;  ← 逐物品禁用（本模组不写）
    这些建筑的「可调旋钮」是「保留多少」，不是「最多存多少」。
    所以本模组调的是 ReserveDefault / CurrentReserve，而不是配额。

  能做什么
    · 列出所有消耗型存储组件（民居食物/燃料/水、伙房燃料、国社祭祀…）
    · 逐条调整「默认保留量」，一键应用（写 CurrentReserve 并回读校验）
    · 记住设置，重进游戏自动恢复

  快捷键
    F7            开关面板
    ↑ / ↓         选择组件
    ← / →         保留量 -1 / +1（按住 Shift 为 ±10）
    Enter         应用（写入并回读）
    Backspace     把当前项恢复成组件自带默认
    Ctrl+F7       立即重扫
================================================================================
]]

local MOD = "[FengShaConsume]"
local VERSION = "1.0"

local function GetScriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    local dir = src:match("^(.*[\\/])")
    if dir then
        dir = dir:gsub("[\\/]Scripts[\\/]$", ""):gsub("[\\/]Scripts$", "")
        return dir
    end
    return ""
end

local BASE_DIR = GetScriptDir()
local DATA_DIR = BASE_DIR .. "\\data"
local DATA_FILE = DATA_DIR .. "\\consume.txt"

-- 消耗型建筑的 BP 生成类名（QoL 真机验证过：按类名 FindAllOf 有界可靠）
local CONSUME_CLASSES = {
    "BP_Building_CivilianTent_C",  "BP_Building_CivilianTent_E_C",
    "BP_Building_MinJu_LV1_C",     "BP_Building_MinJu_LV2_C", "BP_Building_MinJu_LV3_C",
    "BP_Building_Kitchen_C",       "BP_Building_Well_C",
    "BP_Building_Altar_C",         "BP_Building_Hospital_C",
}
local DUMP_DIR  = BASE_DIR .. "\\dumps"

local function ParseConfig(path)
    local cfg = {}
    local f = io.open(path, "r")
    if not f then return cfg end
    for line in f:lines() do
        local s = line:gsub("#.*$", "")
        local k, v = s:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v ~= "" then
            if v == "true" then cfg[k] = true
            elseif v == "false" then cfg[k] = false
            elseif tonumber(v) then cfg[k] = tonumber(v)
            else cfg[k] = v end
        end
    end
    f:close()
    return cfg
end

local CFG = ParseConfig(BASE_DIR .. "\\config.txt")
local C = {
    Enabled     = CFG.Enabled ~= false,
    AutoApply   = CFG.AutoApply ~= false,
    IntervalSec = tonumber(CFG.IntervalSec) or 10,
    IncludeEnemy = CFG.IncludeEnemy == true,
    Verbose     = CFG.Verbose == true,
}

local function log(m) print(string.format("%s %s\n", MOD, tostring(m))) end
local function isValid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function prop(o, n)
    if o == nil then return nil end
    local ok, v = pcall(function() return o[n] end)
    if ok then return v end
    return nil
end
local function toNum(v)
    if type(v) == "number" then return v end
    if type(v) == "table" and type(v.Value) == "number" then return v.Value end
    return nil
end
local function findFirst(cls)
    local ok, o = pcall(function() return FindFirstOf(cls) end)
    if ok then return o end
    return nil
end

-- ============================================================================
-- 1. 组件识别
-- ============================================================================

-- 逆向自 BP 的组件节点名（ConsumeXxxStorage / IdleStorage 等）
local CONSUME_PREFIX = { "Consume", "IdleStorage", "MaterialStorage" }

local function isConsumeName(n)
    for _, p in ipairs(CONSUME_PREFIX) do
        if n:sub(1, #p) == p then return true end
    end
    return false
end

-- 已知节点名（从 BP 里扫出来的），用于直接按属性名取
local KNOWN_NODES = {
    "ConsumeFoodStorage", "ConsumeFuelStorage", "ConsumeWaterStorage",
    "ConsumeRitualStorage", "ConsumeMenKeStorage", "ConsumeTitleUpgradeStorage",
    "IdleStorage", "MaterialStorage", "HospitalStorage",
}

local function collectComponents(actor)
    local out = {}
    for _, n in ipairs(KNOWN_NODES) do
        local c = prop(actor, n)
        if isValid(c) then
            if toNum(prop(c, "ReserveMax")) ~= nil or toNum(prop(c, "Capacity")) ~= nil then
                out[#out + 1] = { node = n, comp = c }
            end
        end
    end
    -- 带后缀的（IdleStorage_ZongMen17011 这类）走 GetStorageComponents
    local arr = nil
    local ok = pcall(function() arr = actor:GetStorageComponents() end)
    if ok and arr ~= nil then
        pcall(function()
            for _, c in ipairs(arr) do
                local fn = nil
                pcall(function() fn = c:GetName() end)
                if type(fn) == "string" and isConsumeName(fn) then
                    local dup = false
                    for _, e in ipairs(out) do
                        if e.comp == c then dup = true break end
                    end
                    if not dup and toNum(prop(c, "ReserveMax")) ~= nil then
                        out[#out + 1] = { node = fn, comp = c }
                    end
                end
            end
        end)
    end
    return out
end

-- ============================================================================
-- 2. 扫描
-- ============================================================================

local SysCache = { bs = nil, bsAt = 0 }
local function getBuildingSubsystem()
    if isValid(SysCache.bs) then return SysCache.bs end
    if SysCache.bsAt > 0 and os.time() - SysCache.bsAt < 30 then return nil end
    SysCache.bs = findFirst("BuildingSubsystem")
    SysCache.bsAt = os.time()
    return SysCache.bs
end

local function nameOf(actor)
    local ok, n = pcall(function() return actor:GetName() end)
    if ok and type(n) == "string" then return n end
    return nil
end

local Rows = {}          -- { key, actor, node, comp, cap, rmin, rmax, rdef, rcur }
local Sel = { idx = 1 }
local ScanAt = 0
local Applied = 0

local function readRow(actor, node, comp)
    local cap = toNum(prop(comp, "Capacity"))
    local rmin = toNum(prop(comp, "ReserveMin"))
    local rmax = toNum(prop(comp, "ReserveMax"))
    local rdef = toNum(prop(comp, "ReserveDefault"))
    local rcur = toNum(prop(comp, "CurrentReserve"))
    if rmax == nil and cap == nil then return nil end
    return {
        actor = actor, node = node, comp = comp,
        name = nameOf(actor) or "?",
        cap = cap, rmin = rmin, rmax = rmax, rdef = rdef, rcur = rcur,
    }
end

local function scan()
    Rows = {}
    local seen = {}
    local function pass(arr, tag)
        if arr == nil then return 0 end
        local n = 0
        pcall(function()
            for _, a in ipairs(arr) do
                if isValid(a) then
                    n = n + 1
                    local nm = nameOf(a) or "?"
                    for _, e in ipairs(collectComponents(a)) do
                        local key = nm .. "|" .. e.node
                        if not seen[key] then
                            seen[key] = true
                            local r = readRow(a, e.node, e.comp)
                            if r then r.key = key Rows[#Rows + 1] = r end
                        end
                    end
                end
            end
        end)
        if C.Verbose then log(string.format("%s: %d 个建筑", tag, n)) end
        return n
    end

    local bs = getBuildingSubsystem()
    local pa = isValid(bs) and prop(bs, "AllPlayerBuildings") or nil
    local ab = isValid(bs) and prop(bs, "AllBuildings") or nil
    local n = pass(pa, "AllPlayerBuildings")
    if n == 0 then n = pass(ab, "AllBuildings") end
    -- 子系统读不到 / 数组为空 → 按类名逐个枚举（有界，非全对象扫描）
    if n == 0 then
        local n2 = 0
        for _, cls in ipairs(CONSUME_CLASSES) do
            local ok, arr = pcall(function() return FindAllOf(cls) end)
            if ok and arr ~= nil then n2 = n2 + pass(arr, "类名:" .. cls) end
        end
        if C.Verbose then log(string.format("按类名枚举: %d 个建筑", n2)) end
    end
    -- 不再用 FindAllOf 兜底：全对象枚举会长时间占用 Lua 线程，
    -- 实测会让加载阶段卡死、其它模组的按键全部失效。

    table.sort(Rows, function(a, b) return a.key < b.key end)
    ScanAt = os.time()
    if Sel.idx > #Rows then Sel.idx = math.max(1, #Rows) end
    if C.Verbose then log(string.format("扫描完成：%d 个消耗型组件", #Rows)) end
end

-- ============================================================================
-- 3. 写入
-- ============================================================================

local function clamp(v, lo, hi)
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

local function writeInt(comp, field, value)
    local ok = pcall(function() comp[field] = value end)
    if not ok then return false, "写入异常" end
    local got = toNum(prop(comp, field))
    if got ~= value then return false, string.format("回读不一致(%s≠%s)", tostring(got), tostring(value)) end
    return true
end

-- 应用一项：把 ReserveDefault 设为 want，并把 CurrentReserve 同步过去
local function applyRow(r, want)
    if not isValid(r.comp) then return false, "组件失效" end
    if not toNum(prop(r.comp, "bAllowUserSetReserve")) and
       prop(r.comp, "bAllowUserSetReserve") == false then
        return false, "该组件不允许玩家设置保留量"
    end
    want = clamp(want, r.rmin, r.rmax)
    local ok1, m1 = writeInt(r.comp, "ReserveDefault", want)
    if not ok1 then return false, "默认值写入失败: " .. tostring(m1) end
    local ok2, m2 = writeInt(r.comp, "CurrentReserve", want)
    if not ok2 then return false, "当前值写入失败: " .. tostring(m2) end
    r.rdef, r.rcur = want, want
    Applied = Applied + 1
    return true
end

-- ============================================================================
-- 4. 持久化
-- ============================================================================

local Desired = {}   -- key -> number

local function loadDesired()
    local f = io.open(DATA_FILE, "r")
    if not f then return end
    for line in f:lines() do
        if line:sub(1, 1) ~= "#" then
            local k, v = line:match("^(.+)\t(-?%d+)$")
            if k then Desired[k] = tonumber(v) end
        end
    end
    f:close()
end

local function saveDesired()
    pcall(function() os.execute('mkdir "' .. DATA_DIR .. '" 2>nul') end)
    local f = io.open(DATA_FILE, "w")
    if not f then log("写盘失败: " .. DATA_FILE) return end
    f:write("# 消耗点保留量  key<TAB>数值\n")
    local keys = {}
    for k in pairs(Desired) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        f:write(string.format("%s\t%d\n", k, Desired[k]))
    end
    f:close()
end

local function applyAllDesired()
    if not C.Enabled then return end
    for _, r in ipairs(Rows) do
        local want = Desired[r.key]
        if want and want ~= r.rdef then
            local ok, msg = applyRow(r, want)
            if ok and C.Verbose then
                log(string.format("已应用 %s → %d", r.key, want))
            elseif not ok and C.Verbose then
                log(string.format("应用失败 %s: %s", r.key, tostring(msg)))
            end
        end
    end
end

-- ============================================================================
-- 5. 面板
-- ============================================================================

local Open = false

local function panelText()
    local L = {}
    local w = function(s) L[#L + 1] = s end
    w("===== 消耗点调参  v" .. VERSION .. " =====")
    w(string.format("组件 %d 个   已写入 %d 次   扫描 %ds 前",
        #Rows, Applied, os.time() - ScanAt))
    w("")
    if #Rows == 0 then
        w("没有找到消耗型存储组件。")
        w("说明：民居/伙房/水井/国社 才有；Ctrl+F7 重扫。")
        return table.concat(L, "\n")
    end

    local start = math.max(1, Sel.idx - 6)
    local stop = math.min(#Rows, start + 12)
    for i = start, stop do
        local r = Rows[i]
        local mark = (i == Sel.idx) and "▶" or " "
        local rng = ""
        if r.rmin or r.rmax then
            rng = string.format("[%s-%s]", tostring(r.rmin or "?"), tostring(r.rmax or "?"))
        end
        w(string.format("%s %-26s %-24s 保留 %s/%s %s",
            mark, (r.name):sub(1, 26), r.node:sub(1, 24),
            tostring(r.rcur or "?"), tostring(r.rdef or "?"), rng))
    end
    w("")
    local cur = Rows[Sel.idx]
    if cur then
        w(string.format("当前：%s . %s", cur.name, cur.node))
        w(string.format("  容量=%s  保留 当前=%s 默认=%s 范围=[%s, %s]",
            tostring(cur.cap), tostring(cur.rcur), tostring(cur.rdef),
            tostring(cur.rmin or "-"), tostring(cur.rmax or "-")))
    end
    w("")
    w("↑↓ 选择   ←→ 调整(Shift±10)   Enter 应用   Backspace 恢复默认")
    w("F7 关闭   Ctrl+F7 重扫")
    return table.concat(L, "\n")
end

local function hud()
    if not Open then return end
    local txt = panelText()
    print(string.format("%s\n%s\n", MOD, txt))
    -- 游戏内 UMG 不可靠，同时落文件保证能看到
    pcall(function()
        os.execute('mkdir "' .. DUMP_DIR .. '" 2>nul')
    end)
    local path = string.format("%s\\panel_consume_%s.txt", DUMP_DIR, os.date("%Y%m%d_%H%M%S"))
    local f = io.open(path, "w")
    if f then
        f:write(txt .. "\n")
        f:close()
    end
end

-- 导出当前清单到 dumps\consume_*.txt（发给开发者排查用）
-- DUMP_DIR 已在文件头声明

local function dumpToFile()
    pcall(function() os.execute('mkdir "' .. DUMP_DIR .. '" 2>nul') end)
    local path = string.format("%s\\consume_%s.txt", DUMP_DIR, os.date("%Y%m%d_%H%M%S"))
    local f = io.open(path, "w")
    if not f then log("写盘失败: " .. path) return nil end
    f:write(string.format("FengShaConsume v%s  导出 %s\n", VERSION, os.date("%Y-%m-%d %H:%M:%S")))
    f:write(string.format("组件 %d 个  已写入 %d 次\n", #Rows, Applied))
    f:write(string.rep("-", 70) .. "\n")
    for _, r in ipairs(Rows) do
        f:write(string.format("%s\t%s\t容量=%s\t当前=%s\t默认=%s\t范围=[%s,%s]\t本地设置=%s\n",
            r.name, r.node, tostring(r.cap), tostring(r.rcur), tostring(r.rdef),
            tostring(r.rmin or "-"), tostring(r.rmax or "-"),
            tostring(Desired[r.key] or "-")))
    end
    f:close()
    log("已导出 " .. path)
    return path
end

-- ============================================================================
-- 6. 快捷键
-- ============================================================================

RegisterKeyBind(Key.F7, {}, function()
    Open = not Open
    if Open then
        if os.time() - ScanAt > 5 then scan() end
        hud()
    else
        log("面板已关闭")
    end
end)

RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, function()
    scan()
    log(string.format("重扫完成：%d 个组件", #Rows))
    if Open then hud() end
end)

RegisterKeyBind(Key.F8, { ModifierKey.CONTROL }, function()
    dumpToFile()
end)

RegisterKeyBind(Key.UP_ARROW, {}, function()
    if not Open or #Rows == 0 then return end
    Sel.idx = (Sel.idx - 2) % #Rows + 1
    hud()
end)

RegisterKeyBind(Key.DOWN_ARROW, {}, function()
    if not Open or #Rows == 0 then return end
    Sel.idx = Sel.idx % #Rows + 1
    hud()
end)

local function adjust(delta)
    if not Open or #Rows == 0 then return end
    local r = Rows[Sel.idx]
    if not r then return end
    local step = IsKeyDown(Key.SHIFT) and 10 or 1
    local want = clamp((r.rdef or r.rcur or 0) + delta * step, r.rmin, r.rmax)
    Desired[r.key] = want
    saveDesired()
    local ok, msg = applyRow(r, want)
    if ok then
        log(string.format("%s → %d", r.key, want))
    else
        log(string.format("应用失败 %s: %s", r.key, tostring(msg)))
    end
    hud()
end

RegisterKeyBind(Key.LEFT_ARROW, {}, function() adjust(-1) end)
RegisterKeyBind(Key.RIGHT_ARROW, {}, function() adjust(1) end)

RegisterKeyBind(Key.RETURN, {}, function()
    if not Open or #Rows == 0 then return end
    local r = Rows[Sel.idx]
    if not r then return end
    local want = Desired[r.key] or r.rdef or r.rcur
    if want == nil then return end
    local ok, msg = applyRow(r, want)
    log(ok and string.format("已应用 %s = %d", r.key, want)
        or string.format("失败 %s: %s", r.key, tostring(msg)))
    hud()
end)

RegisterKeyBind(Key.BACKSPACE, {}, function()
    if not Open or #Rows == 0 then return end
    local r = Rows[Sel.idx]
    if not r then return end
    Desired[r.key] = nil
    saveDesired()
    log("已清除 " .. r.key .. " 的本地设置（组件内默认值不受影响）")
    hud()
end)

-- ============================================================================
-- 7. 自动应用
-- ============================================================================

local function tick()
    if not C.Enabled then return end
    if os.time() - ScanAt > C.IntervalSec then
        scan()
        if C.AutoApply then applyAllDesired() end
    end
end

loadDesired()
-- 加载时不在主菜单硬扫（会卡住 Lua 线程），延迟到世界就绪后再扫
ExecuteWithDelay(3000, function()
    scan()
    applyAllDesired()
end)
LoopAsync(C.IntervalSec * 1000, function()
    tick()
    return false
end)

log(string.format("已加载 v%s  自动应用=%s（首次扫描已延迟 3 秒）",
    VERSION, tostring(C.AutoApply)))
log("F7 面板 / ↑↓ 选择 / ←→ 调整 / Enter 应用")

-- 离线单测钩子
if _G.__FSC_TEST then
    _G.FSC_TEST = {
        scan = scan,
        rows = function() return Rows end,
        panelText = panelText,
        applyRow = applyRow,
        adjustDesired = function(k, v) Desired[k] = v end,
        saveDesired = saveDesired,
        loadDesired = loadDesired,
        desired = function() return Desired end,
        C = C,
        sel = function() return Sel end,
        dumpToFile = dumpToFile,
    }
    print("[FengShaConsume] 测试钩子已导出\n")
end
