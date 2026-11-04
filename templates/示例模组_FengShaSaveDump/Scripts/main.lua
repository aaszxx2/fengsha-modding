--[[
================================================================================
  《烽沙》存档结构导出  FengShaSaveDump  v1.0
  纯 UE4SS Lua 模组 —— 只读，不改任何游戏状态

  目的：存档文件（Level/Mass/Player.sav）的载荷是压缩过的，静态解不开。
        这里改成在**运行时**从已经反序列化好的 USaveGame 对象上读结构，
        拿到「哪个类、有哪些数组、每个数组多少条」—— 这是存档结构的骨架。

  逆向依据（UHTHeaderDump）
    UEMSCustomSaveGame : USaveGame  { SaveGameName:FString, bUseSaveSlot:bool }
    UEMSInfoSaveGame   : USaveGame  { SlotInfo:FSaveSlotInfo }
    UMOMassSaveGame    : USaveGame  {
        SoldierEntities / TeamEntities / MinFuEntities / WuEntities /
        ConstructEntities / BeastEntities / StagehandEntities : TArray<FEntitySaveData>
    }
    FEntitySaveData { DAConfigName:FString, SaveUniqueID:int32,
                      SaveTrans:FTransform, SaveSoldierType:EMOSoldierType,
                      EntityFragments:TArray<FInstancedStruct> }

  安全策略
    · 默认只读「数组条数」和 int32 字段 —— 这些在其它模组里已验证安全
    · FString / FText / FTransform 默认不读（本作读这些会崩），要读需开 DeepDump
    · 所有访问走 pcall

  快捷键
    Ctrl+F9   立即导出（扫描当前世界里所有 USaveGame 对象）
    Ctrl+F8   开关「读档/存档时自动导出」
================================================================================
]]

local MOD = "[FengShaSaveDump]"
local VERSION = "1.0"

local function GetScriptDir()
    local info = debug.getinfo(1, "S")
    local src = info.source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    local dir = src:match("^(.*[\\/])")
    if dir then
        dir = dir:gsub("[\\/]Scripts[\\/]$", ""):gsub("[\\/]Scripts$", "")
        return dir
    end
    return ""
end

local BASE_DIR = GetScriptDir()
local DUMP_DIR = BASE_DIR .. "\\dumps"

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
    AutoDumpOnLoad = CFG.AutoDumpOnLoad ~= false,   -- 读档时自动导出
    AutoDumpOnSave = CFG.AutoDumpOnSave == true,    -- 存档时也导出（默认关）
    DeepDump       = CFG.DeepDump == true,          -- 读结构体内部字段（有崩溃风险）
    MaxEntries     = tonumber(CFG.MaxEntries) or 5, -- 每个数组最多展开几条
}

local function log(msg)
    print(string.format("%s %s\n", MOD, tostring(msg)))
end

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

local function className(obj)
    local c = prop(obj, "Class") or nil
    local ok, n = pcall(function() return obj:GetClass():GetName() end)
    if ok and type(n) == "string" then return n end
    local fn = nil
    ok, fn = pcall(function() return obj:GetFullName() end)
    if ok and type(fn) == "string" then return fn end
    return "?"
end

local function arrayCount(arr)
    if arr == nil then return nil end
    local n = 0
    local ok = pcall(function() for _ in ipairs(arr) do n = n + 1 end end)
    if ok then return n end
    return nil
end

local function ensureDir(p)
    local f = io.open(p .. "\\.wtest", "w")
    if f then f:close() os.remove(p .. "\\.wtest") return true end
    return false
end

-- ---------------------------------------------------------------------------
-- 已知类的字段表（来自 UHTHeaderDump，按类名分组）
-- ---------------------------------------------------------------------------
local CLASS_LAYOUT = {
    MOMassSaveGame = {
        arrays = { "SoldierEntities", "TeamEntities", "MinFuEntities", "WuEntities",
                   "ConstructEntities", "BeastEntities", "StagehandEntities" },
    },
    EMSInfoSaveGame = { arrays = {}, structs = { "SlotInfo" } },
    EMSCustomSaveGame = { arrays = {} },
}

-- 展开 FEntitySaveData 的安全字段（只读 int32 / 枚举）
local ENTITY_SAFE_FIELDS = { "SaveUniqueID", "SaveSoldierType" }

local function dumpSaveObject(obj, L, depth)
    depth = depth or 0
    if not isValid(obj) then return end
    local cls = className(obj)
    local pad = string.rep("  ", depth)
    L[#L + 1] = string.format("%s对象: %s  [%s]", pad, cls, tostring(prop(obj, "Name") or "?"))

    local layout = CLASS_LAYOUT[cls]
    if layout == nil then
        L[#L + 1] = pad .. "  （未登记该类，跳过字段）"
        return
    end

    for _, arrName in ipairs(layout.arrays or {}) do
        local arr = prop(obj, arrName)
        local n = arrayCount(arr)
        L[#L + 1] = string.format("%s  %-22s %s 条", pad, arrName, n == nil and "?" or tostring(n))

        if C.DeepDump and arr ~= nil and n and n > 0 then
            local shown = 0
            pcall(function()
                for i, e in ipairs(arr) do
                    if shown >= C.MaxEntries then break end
                    local parts = {}
                    for _, f in ipairs(ENTITY_SAFE_FIELDS) do
                        local v = toNum(prop(e, f))
                        if v ~= nil then parts[#parts + 1] = f .. "=" .. tostring(v) end
                    end
                    local frags = prop(e, "EntityFragments")
                    local fn = arrayCount(frags)
                    if fn then parts[#parts + 1] = "Fragments=" .. fn end
                    L[#L + 1] = string.format("%s    [%d] %s", pad, i, table.concat(parts, "  "))
                    shown = shown + 1
                end
            end)
        end
    end

    for _, sName in ipairs(layout.structs or {}) do
        local s = prop(obj, sName)
        L[#L + 1] = string.format("%s  %-22s %s", pad, sName, s == nil and "读不到" or "已读到（结构体字段需 DeepDump）")
    end
end

local function writeDump(L, tag)
    if not ensureDir(DUMP_DIR) then
        log("dumps 目录不可写: " .. DUMP_DIR)
        return
    end
    local path = string.format("%s\\save_%s_%s.txt", DUMP_DIR,
        tag, os.date("%Y%m%d_%H%M%S"))
    local f = io.open(path, "w")
    if not f then log("写文件失败: " .. path) return end
    f:write(table.concat(L, "\n"))
    f:write("\n")
    f:close()
    log("已导出 " .. path)
end

-- ---------------------------------------------------------------------------
-- 扫描当前世界的存档对象
-- ---------------------------------------------------------------------------
local KNOWN_CLASSES = { "MOMassSaveGame", "EMSInfoSaveGame", "EMSCustomSaveGame" }

local function dumpAll(tag)
    local L = {}
    L[#L + 1] = "FengShaSaveDump v" .. VERSION .. "  " .. os.date("%Y-%m-%d %H:%M:%S")
    L[#L + 1] = "DeepDump=" .. tostring(C.DeepDump) .. "  MaxEntries=" .. C.MaxEntries
    L[#L + 1] = string.rep("-", 60)

    local found = 0
    for _, cls in ipairs(KNOWN_CLASSES) do
        local ok, arr = pcall(function() return FindAllOf(cls) end)
        if ok and arr ~= nil then
            local n = 0
            pcall(function()
                for _, o in ipairs(arr) do
                    if isValid(o) then
                        dumpSaveObject(o, L, 0)
                        found = found + 1
                    end
                end
            end)
            L[#L + 1] = string.format("[%s] %d 个实例", cls, n)
        else
            L[#L + 1] = string.format("[%s] FindAllOf 失败", cls)
        end
    end

    if found == 0 then
        L[#L + 1] = ""
        L[#L + 1] = "没有找到存档对象。"
        L[#L + 1] = "说明：USaveGame 对象通常只在读档/存档瞬间存在，之后会被释放。"
        L[#L + 1] = "请用 Ctrl+F8 打开自动导出，然后读一次档。"
    end
    writeDump(L, tag)
end

-- ---------------------------------------------------------------------------
-- Hook：读档 / 存档
-- ---------------------------------------------------------------------------
local function tryHook(path, isPost, handler)
    -- UE4SS 各版本对 post-hook 的写法不一致：先试三参数，再退两参数
    local ok, err = pcall(function()
        RegisterHook(path, handler, isPost)
    end)
    if ok then
        log("已挂接 " .. path .. (isPost and " (post)" or " (pre)"))
        return true
    end
    local ok2, err2 = pcall(function()
        RegisterHook(path, handler)
    end)
    if ok2 then
        log("已挂接 " .. path .. " (兼容写法)")
        return true
    end
    log("挂接失败 " .. path .. " : " .. tostring(err2 or err))
    return false
end

-- LoadGameFromSlot(SlotName, UserIndex) -> USaveGame*
tryHook("/Script/Engine.GameplayStatics:LoadGameFromSlot", true, function(Context)
    local ok, ret = pcall(function() return Context:GetReturnValue() end)
    if not ok or not isValid(ret) then return end
    log("LoadGameFromSlot 返回 " .. className(ret))
    if C.AutoDumpOnLoad then
        local L = {}
        L[#L + 1] = "读档导出 " .. os.date("%Y-%m-%d %H:%M:%S")
        L[#L + 1] = string.rep("-", 60)
        dumpSaveObject(ret, L, 0)
        writeDump(L, "load")
    end
end)

-- SaveGameToSlot(SaveGameObject, SlotName, UserIndex)
tryHook("/Script/Engine.GameplayStatics:SaveGameToSlot", false, function(Context)
    local ok, obj = pcall(function() return Context:GetParam(1) end)
    if not ok or not isValid(obj) then return end
    log("SaveGameToSlot 收到 " .. className(obj))
    if C.AutoDumpOnSave then
        local L = {}
        L[#L + 1] = "存档导出 " .. os.date("%Y-%m-%d %H:%M:%S")
        L[#L + 1] = string.rep("-", 60)
        dumpSaveObject(obj, L, 0)
        writeDump(L, "save")
    end
end)

-- ---------------------------------------------------------------------------
-- 快捷键
-- ---------------------------------------------------------------------------
RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, function()
    log("[键] Ctrl+F9 导出")
    dumpAll("manual")
end)

RegisterKeyBind(Key.F8, { ModifierKey.CONTROL }, function()
    C.AutoDumpOnLoad = not C.AutoDumpOnLoad
    log("[键] Ctrl+F8 自动导出 = " .. tostring(C.AutoDumpOnLoad))
end)

log(string.format("已加载 v%s  自动读档导出=%s 深度=%s",
    VERSION, tostring(C.AutoDumpOnLoad), tostring(C.DeepDump)))
log("Ctrl+F9 立即导出 / Ctrl+F8 开关自动导出")

-- 离线单测钩子
if _G.__FSD_TEST then
    _G.FSD_TEST = {
        dumpSaveObject = dumpSaveObject,
        dumpAll = dumpAll,
        arrayCount = arrayCount,
        className = className,
        C = C,
    }
    print("[FengShaSaveDump] 测试钩子已导出\n")
end
