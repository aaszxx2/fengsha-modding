--[[
================================================================================
  《烽沙》营造蓝图  FengShaBlueprint  v1.0
  纯 UE4SS Lua 模组 —— 不修改任何游戏文件

  功能：把玩家自己的建筑布局导出成「蓝图」，其他玩家导入后在各自存档里复现。

  快捷键
    Ctrl+B         导出蓝图（写 JSON + 分享码自动进剪贴板）
    Ctrl+Shift+B   导入蓝图（优先读剪贴板；读不到则用 blueprints 目录里最新的 .fscb.txt）
    Ctrl+Shift+Z   撤销上一次导入（拆掉刚生成的建筑）
    Ctrl+F12       开关面板（说明 + 状态 + 最近一次蓝图统计）
    Ctrl+F11       诊断（把环境信息写进 dumps\diag_*.txt）

  关键 API（均已在 8 月构建的 UHTHeaderDump 中确认存在）
    UBuildingSubsystem.AllBuildings            TArray<AMOBuildingBase*>   枚举建筑
    AInteractiveActorBase.ConfigID             int32                      建筑配置ID（含等级）
    AInteractiveActorBase.BuildingFactionType  EMOFactionType             阵营
    AMOBuildingBase.BuildingState              EMOBuildingState           0预览/1施工/2完工/3被拆
    UMOConstructSubsystem::FastConstructBuildingActor(ConfigID, FTransform, FactionType, bGround)
    UMOConstructSubsystem::TearDownBuilding(AActor*)
    UEMSFunctionLibrary::SetActorSaveProperties(WorldContext, bSkipSave, bPersistent, bSkipTransform, LoadedState)
    UMOBlueprintFunctionLibrary::GetCurLandscapeHeightAtLocation(WorldContext, X, Y, outHeight)

  安全规则（继承自 FengShaQoL / ZouYanMenKe 的踩坑清单）
    1. 所有 UObject 访问走 pcall；结构体绝不取长度（# 或 :Num() 会 native AV）
    2. 调 UFUNCTION 用 fn(obj, ...) 形式，且只判 nil 不判 type（CDO 上是 userdata）
    3. FName 用 FName(s,2)（AddUnique），FText 用 FText(s)；不用 KismetTextLibrary CDO
    4. 常驻循环走 ExecuteInGameThreadWithDelay 低频调度，热路径不做 UObject 查询
    5. 主菜单世界跳过（无 PlayerController）
================================================================================
]]

local MOD = "[FengShaBP]"

-- Lua 5.1 有全局 unpack，5.2+ 挪到 table.unpack；UE4SS 各版本不一，统一兜一层
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
local BP_DIR = BASE_DIR .. "\\blueprints"
local TMP_DIR = BASE_DIR .. "\\tmp"
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
    InstantComplete   = CFG.InstantComplete ~= false,   -- 导入后直接完工（默认 true）
    -- 逆向结论（2026-10-17）：建造扣费不是"一次扣费"，而是
    -- 「需求清单 → 民夫搬运 → 到位消耗」。FastConstructBuildingActor 跳过需求清单阶段，
    -- 所以它本身不扣费。把 InstantComplete 设成 false（生成工地）时，
    -- 游戏自己的民夫搬运管线会自然消耗材料 —— 不需要单独实现扣费。
    ConsumeResources  = CFG.ConsumeResources == true,   -- 已废弃，仅兼容旧配置
    IncludeConstructing = CFG.IncludeConstructing == true, -- 导出时是否包含施工中的建筑
    ExportFaction     = CFG.ExportFaction or "auto",    -- auto / 数字(1..7 齐国..秦国)
    MaxBuildings      = tonumber(CFG.MaxBuildings) or 3000,
    ExportName        = CFG.ExportName or "",           -- 留空则用「基地_时间戳」
    UseClipboard      = CFG.UseClipboard ~= false,      -- 导出时把分享码写进剪贴板
    HudMs             = tonumber(CFG.HudMs) or 6000,
    Verbose           = CFG.Verbose == true,
    DryRun            = CFG.DryRun == true,             -- true=只解析不生成（调试用）
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
-- 调 UFUNCTION：CDO 上拿到的是 userdata（带 __call），只判 nil 不判 type
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

-- 同 callf，但把多个返回值（含 UE4SS 以返回值形式给出的 out 参数）都取回来
local function callfMulti(o, name, ...)
    if o == nil then return nil end
    local fn = prop(o, name)
    if fn == nil then return nil end
    local args = { ... }
    local ok, r1, r2, r3 = pcall(function() return fn(o, unpack(args)) end)
    if not ok then return nil end
    return r1, r2, r3
end

local function mkName(s)
    local ok, r = pcall(function() return FName(s, 2) end)
    if ok and r ~= nil then return r end
    local ok2, r2 = pcall(function() return FName(s) end)
    if ok2 and r2 ~= nil then return r2 end
    return nil
end

local function mkText(s)
    local ok, r = pcall(function() return FText(s) end)
    if ok and r ~= nil then return r end
    return nil
end

local function ensureDir(path)
    if path == "" then return end
    os.execute('cmd /c if not exist "' .. path .. '" mkdir "' .. path .. '"')
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

-- ============================================================================
-- 2. base64（自实现，避免依赖引擎里未暴露的库）
-- ============================================================================

local B64CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64LOOKUP = {}
for i = 1, #B64CHARS do
    B64LOOKUP[B64CHARS:sub(i, i)] = i - 1
end

local function b64encode(data)
    local out = {}
    local i = 1
    local n = #data
    while i <= n do
        local b1 = data:byte(i) or 0
        local b2 = data:byte(i + 1)
        local b3 = data:byte(i + 2)
        local c1 = math.floor(b1 / 4)
        local c2 = (b1 % 4) * 16 + math.floor((b2 or 0) / 16)
        local c3 = b2 and ((b2 % 16) * 4 + math.floor((b3 or 0) / 64)) or 64
        local c4 = b3 and (b3 % 64) or 64
        out[#out + 1] = B64CHARS:sub(c1 + 1, c1 + 1)
        out[#out + 1] = B64CHARS:sub(c2 + 1, c2 + 1)
        out[#out + 1] = c3 < 64 and B64CHARS:sub(c3 + 1, c3 + 1) or "="
        out[#out + 1] = c4 < 64 and B64CHARS:sub(c4 + 1, c4 + 1) or "="
        i = i + 3
    end
    return table.concat(out)
end

local function b64decode(s)
    if not s then return nil end
    s = s:gsub("[^A-Za-z0-9+/=]", "")
    local out = {}
    local i = 1
    while i <= #s do
        local c1 = B64LOOKUP[s:sub(i, i)]
        local c2 = B64LOOKUP[s:sub(i + 1, i + 1)]
        local ch3 = s:sub(i + 2, i + 2)
        local ch4 = s:sub(i + 3, i + 3)
        local c3 = B64LOOKUP[ch3]
        local c4 = B64LOOKUP[ch4]
        if c1 == nil or c2 == nil then break end
        out[#out + 1] = string.char(c1 * 4 + math.floor(c2 / 16))
        if c3 ~= nil then
            out[#out + 1] = string.char((c2 % 16) * 16 + math.floor(c3 / 4))
        end
        if c4 ~= nil then
            out[#out + 1] = string.char((c3 % 4) * 64 + c4)
        end
        i = i + 4
    end
    return table.concat(out)
end

-- ============================================================================
-- 3. 世界 / 玩家 / 子系统
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
    local pc = getPC()
    if pc then
        local pawn = prop(pc, "Pawn")
        if isValid(pawn) then return pawn end
    end
    return nil
end

local function findObj(path)
    local ok, o = pcall(function() return StaticFindObject(path) end)
    if ok and isValid(o) then return o end
    return nil
end

-- CDO 上的静态 UFUNCTION 入口
local function constructCDO() return findObj("/Script/MOProject.Default__MOConstructSubsystem") end
local function emsCDO()       return findObj("/Script/EasyMultiSave.Default__EMSFunctionLibrary") end
local function moBPLib()      return findObj("/Script/MOProject.Default__MOBlueprintFunctionLibrary") end

local function getBuildingSubsystem()
    local ok, bs = pcall(function() return FindFirstOf("BuildingSubsystem") end)
    if ok and isValid(bs) then return bs end
    local ok2, arr = pcall(function() return FindAllOf("BuildingSubsystem") end)
    if ok2 and arr then
        local found = nil
        pcall(function()
            for _, v in ipairs(arr) do
                if isValid(v) then found = v break end
            end
        end)
        if found then return found end
    end
    return nil
end

-- ============================================================================
-- 4. 建筑配置名表（ID -> 中文名），由逆向数据生成，纯读文件
-- ============================================================================

local NameMap = {}      -- id -> 名称
local CatMap = {}       -- id -> 分类

local function loadNameMap()
    local f = io.open(BASE_DIR .. "\\config_names.txt", "r")
    if not f then
        log("提示：没找到 config_names.txt，界面将只显示配置ID")
        return
    end
    for line in f:lines() do
        if line:sub(1, 1) ~= "#" then
            local id, name, cat = line:match("^(%d+)\t([^\t]*)\t?([^\t]*)")
            if id then
                NameMap[tonumber(id)] = name
                CatMap[tonumber(id)] = cat
            end
        end
    end
    f:close()
    local n = 0
    for _ in pairs(NameMap) do n = n + 1 end
    log(string.format("已载入建筑名表 %d 条", n))
end

local function nameOf(id)
    return NameMap[id] or ("配置#" .. tostring(id))
end

-- ============================================================================
-- 5. 建筑采集
-- ============================================================================

local function eachArray(arr, fn)
    if arr == nil then return 0 end
    local n = 0
    local ok, err = pcall(function()
        for i, v in ipairs(arr) do
            n = n + 1
            fn(i, v)
        end
    end)
    if not ok then
        log("遍历数组异常: " .. tostring(err))
    end
    return n
end

local function vecOf(actor)
    -- 优先 K2_GetActorLocation，退回 RootComponent.RelativeLocation
    local v = callf(actor, "K2_GetActorLocation")
    if v ~= nil then return v end
    v = callf(actor, "GetActorLocation")
    if v ~= nil then return v end
    local root = prop(actor, "RootComponent")
    if isValid(root) then
        local loc = prop(root, "RelativeLocation")
        if loc ~= nil then return loc end
    end
    return nil
end

local function rotOf(actor)
    local r = callf(actor, "K2_GetActorRotation")
    if r ~= nil then return r end
    r = callf(actor, "GetActorRotation")
    if r ~= nil then return r end
    return nil
end

local function num(v, key)
    if v == nil then return nil end
    local ok, n = pcall(function() return v[key] end)
    if ok and type(n) == "number" then return n end
    return nil
end

-- 采集建筑列表；返回 table of {actor, id, faction, x, y, z, yaw, state}
local function collectBuildings()
    local bs = getBuildingSubsystem()
    if not isValid(bs) then
        log("采集失败：找不到 UBuildingSubsystem")
        return nil, "找不到 BuildingSubsystem"
    end

    local arr = prop(bs, "AllBuildings")
    if arr == nil then
        arr = prop(bs, "AllPlayerBuildings")
    end
    if arr == nil then
        log("采集失败：AllBuildings 属性读取为 nil")
        return nil, "AllBuildings 读不到"
    end

    local list = {}
    local skippedNoLoc = 0
    eachArray(arr, function(_, b)
        if not isValid(b) then return end
        local loc = vecOf(b)
        if loc == nil then skippedNoLoc = skippedNoLoc + 1 return end
        local x, y, z = num(loc, "X"), num(loc, "Y"), num(loc, "Z")
        if x == nil or y == nil or z == nil then skippedNoLoc = skippedNoLoc + 1 return end
        local rot = rotOf(b)
        local yaw = num(rot, "Yaw") or 0
        local id = prop(b, "ConfigID")
        if type(id) ~= "number" then return end
        local faction = prop(b, "BuildingFactionType")
        if type(faction) ~= "number" then faction = -1 end
        local state = prop(b, "BuildingState")
        if type(state) ~= "number" then state = 2 end
        list[#list + 1] = {
            actor = b, id = id, faction = faction,
            x = x, y = y, z = z, yaw = yaw, state = state,
        }
    end)

    log(string.format("采集完成：共 %d 座（无坐标跳过 %d）", #list, skippedNoLoc))
    return list
end

-- 玩家阵营：取「拥有建筑最多」的阵营；也可用配置强制指定
local function resolveFaction(list)
    if type(C.ExportFaction) == "number" then return C.ExportFaction end
    local counts = {}
    for _, b in ipairs(list) do
        counts[b.faction] = (counts[b.faction] or 0) + 1
    end
    local best, bestN = nil, -1
    for f, n in pairs(counts) do
        if n > bestN then best, bestN = f, n end
    end
    return best
end

-- ============================================================================
-- 6. 蓝图序列化 / 分享码
--    分享码： "FSBP1:" .. base64("v1|<名称>|<n>|<id,dx,dy,dz,yaw;...>")
--    dx/dy/dz 单位 cm（整数，相对锚点）；yaw 单位 0.1 度（整数）
-- ============================================================================

local function encodeShareCode(name, items)
    local safe = tostring(name):gsub("[|\r\n;]", "_")
    local parts = {}
    for _, it in ipairs(items) do
        parts[#parts + 1] = string.format("%d,%d,%d,%d,%d",
            it.id, math.floor(it.dx + 0.5), math.floor(it.dy + 0.5), math.floor(it.dz + 0.5),
            math.floor(it.yaw * 10 + 0.5))
    end
    local payload = string.format("v1|%s|%d|%s", safe, #items, table.concat(parts, ";"))
    return "FSBP1:" .. b64encode(payload)
end

local function decodeShareCode(code)
    if type(code) ~= "string" then return nil, "不是字符串" end
    code = code:gsub("%s", "")
    local idx = code:find("FSBP1:")
    if not idx then return nil, "找不到 FSBP1 前缀（可能剪贴板里不是蓝图分享码）" end
    local b64 = code:sub(idx + 6)
    local payload = b64decode(b64)
    if not payload or payload == "" then return nil, "base64 解码失败" end

    local ver, name, cnt, body = payload:match("^(v%d+)|([^|]*)|(%d+)|(.*)$")
    if not ver then return nil, "载荷格式不对" end
    cnt = tonumber(cnt) or 0

    local items = {}
    for seg in body:gmatch("[^;]+") do
        local id, dx, dy, dz, yaw = seg:match("^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$")
        if id then
            items[#items + 1] = {
                id = tonumber(id), dx = tonumber(dx), dy = tonumber(dy), dz = tonumber(dz),
                yaw = (tonumber(yaw) or 0) / 10.0,
            }
        end
    end
    if #items == 0 then return nil, "没有解析出任何建筑" end
    return { version = ver, name = name, declaredCount = cnt, items = items }
end

-- ============================================================================
-- 7. 剪贴板（Windows：写用 clip.exe，读用 powershell Get-Clipboard）
-- ============================================================================

local function clipboardWrite(text)
    ensureDir(TMP_DIR)
    local tmp = TMP_DIR .. "\\clip_out.txt"
    if not writeFile(tmp, text) then return false end
    os.execute('cmd /c clip < "' .. tmp .. '"')
    return true
end

local function clipboardRead()
    ensureDir(TMP_DIR)
    local tmp = TMP_DIR .. "\\clip_in.txt"
    os.execute('cmd /c del "' .. tmp .. '" 2>nul')
    os.execute('cmd /c powershell -NoProfile -Command "Get-Clipboard -Raw | Out-File -Encoding ascii \\"' .. tmp .. '\\""')
    local s = readFile(tmp)
    if s == nil or s == "" then
        -- 退回更简单的写法
        os.execute('cmd /c powershell -NoProfile -Command Get-Clipboard -Raw > "' .. tmp .. '"')
        s = readFile(tmp)
    end
    return s
end

-- ============================================================================
-- 8. 变换构造（多路径兜底，全部 pcall 保护）
-- ============================================================================

local makeTransformPath = "none"

local function makeTransform(x, y, z, yawDeg, templateActor)
    -- 路径 A：UE4SS 自带构造器
    if type(FTransform) == "function" then
        local ok, t = pcall(function() return FTransform() end)
        if ok and t ~= nil then
            local okA = pcall(function()
                t.Translation = { X = x, Y = y, Z = z }
                t.Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 }
            end)
            if okA then
                local half = math.rad(yawDeg) / 2
                pcall(function()
                    t.Rotation = { X = 0, Y = 0, Z = math.sin(half), W = math.cos(half) }
                end)
                makeTransformPath = "FTransform()"
                return t
            end
        end
    end

    -- 路径 B：借一个已存在的 Transform 改成员（成员写已验证可用）
    if isValid(templateActor) then
        local ok, t = pcall(function() return templateActor:K2_GetActorTransform() end)
        if ok and t ~= nil then
            local okB = pcall(function()
                t.Translation = { X = x, Y = y, Z = z }
            end)
            if okB then
                local half = math.rad(yawDeg) / 2
                pcall(function()
                    t.Rotation = { X = 0, Y = 0, Z = math.sin(half), W = math.cos(half) }
                end)
                makeTransformPath = "template"
                return t
            end
        end
    end

    -- 路径 C：直接给 Lua table（UE4SS 会把 table 转成结构体参数）
    makeTransformPath = "table"
    return {
        Translation = { X = x, Y = y, Z = z },
        Rotation = { X = 0, Y = 0, Z = math.sin(math.rad(yawDeg) / 2), W = math.cos(math.rad(yawDeg) / 2) },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
end

-- 地面高度（拿不到就返回 nil）
local function landscapeZ(x, y)
    local lib = moBPLib()
    if lib == nil then return nil end
    local world = getWorld()
    if world == nil then return nil end
    -- out 参数在 UE4SS 里通常以追加返回值形式给出：callfMulti 能取到
    local r1, r2 = callfMulti(lib, "GetCurLandscapeHeightAtLocation", world, x, y)
    if type(r2) == "number" then return r2 end
    if type(r1) == "number" then return r1 end
    return nil
end

-- 导入锚点：光标落点 → 玩家角色位置
local function placementAnchor()
    local pc = getPC()
    if pc ~= nil then
        local r1, r2 = callfMulti(pc, "GetHitResultUnderCursor", 0, false)
        local hit = r2 ~= nil and r2 or (type(r1) ~= "boolean" and r1 or nil)
        if hit ~= nil then
            local loc = prop(hit, "Location")
            if loc == nil then loc = prop(hit, "ImpactPoint") end
            if loc ~= nil then
                local x, y, z = num(loc, "X"), num(loc, "Y"), num(loc, "Z")
                if x and y and z then
                    return x, y, z, "光标落点"
                end
            end
        end
    end
    local pawn = getPawn()
    if pawn ~= nil then
        local loc = vecOf(pawn)
        local x, y, z = num(loc, "X"), num(loc, "Y"), num(loc, "Z")
        if x and y then
            local zz = landscapeZ(x, y)
            return x, y, zz or z or 0, "角色位置"
        end
    end
    return nil, nil, nil, "无"
end

-- ============================================================================
-- 9. 导出
-- ============================================================================

local LastExport = nil   -- {name, count, code, file}

local function doExport()
    local world = getWorld()
    if world == nil then
        log("导出中止：不在游戏世界里（主菜单无法导出）")
        return false
    end

    local list = collectBuildings()
    if list == nil then return false end

    local faction = resolveFaction(list)
    if faction == nil or faction < 0 then
        log("导出中止：无法判定玩家阵营")
        return false
    end

    -- 过滤：本阵营 + 状态
    local picked = {}
    local stat = {}
    for _, b in ipairs(list) do
        stat[b.state] = (stat[b.state] or 0) + 1
        local okFaction = (b.faction == faction)
        local okState = (b.state == 2) or (C.IncludeConstructing and b.state == 1)
        if okFaction and okState then picked[#picked + 1] = b end
    end
    log(string.format("阵营 %d：采集 %d 座，过滤后 %d 座（状态分布 预览%d/施工%d/完工%d/被拆%d）",
        faction, #list, #picked,
        stat[0] or 0, stat[1] or 0, stat[2] or 0, stat[3] or 0))

    if #picked == 0 then
        log("导出中止：没有符合条件的建筑")
        return false
    end
    if #picked > C.MaxBuildings then
        log(string.format("导出中止：%d 座超过上限 %d（可改 config.txt 的 MaxBuildings）", #picked, C.MaxBuildings))
        return false
    end

    -- 锚点 = 质心
    local sx, sy, sz = 0, 0, 0
    for _, b in ipairs(picked) do sx = sx + b.x sy = sy + b.y sz = sz + b.z end
    local n = #picked
    local ax, ay, az = sx / n, sy / n, sz / n

    -- 相对坐标
    local items = {}
    for _, b in ipairs(picked) do
        items[#items + 1] = {
            id = b.id, name = nameOf(b.id),
            dx = b.x - ax, dy = b.y - ay, dz = b.z - az, yaw = b.yaw,
        }
    end
    table.sort(items, function(a, b)
        if a.id ~= b.id then return a.id < b.id end
        return a.dx < b.dx
    end)

    -- 统计（按种类）
    local byId = {}
    for _, it in ipairs(items) do byId[it.id] = (byId[it.id] or 0) + 1 end
    local idList = {}
    for id, cnt in pairs(byId) do idList[#idList + 1] = { id = id, cnt = cnt } end
    table.sort(idList, function(a, b) return a.cnt > b.cnt end)

    local bname = C.ExportName
    if bname == "" then bname = "基地_" .. os.date("%Y%m%d_%H%M%S") end

    -- JSON
    local jl = {}
    jl[#jl + 1] = "{"
    jl[#jl + 1] = string.format('  "format": "FengShaBlueprint",')
    jl[#jl + 1] = string.format('  "version": 1,')
    jl[#jl + 1] = string.format('  "exportedAt": "%s",', os.date("%Y-%m-%d %H:%M:%S"))
    jl[#jl + 1] = string.format('  "name": "%s",', bname)
    jl[#jl + 1] = string.format('  "faction": %d,', faction)
    jl[#jl + 1] = string.format('  "count": %d,', #items)
    jl[#jl + 1] = string.format('  "anchor": [%.1f, %.1f, %.1f],', ax, ay, az)
    jl[#jl + 1] = '  "buildings": ['
    for i, it in ipairs(items) do
        jl[#jl + 1] = string.format('    {"id": %d, "name": "%s", "dx": %d, "dy": %d, "dz": %d, "yaw": %.1f}%s',
            it.id, it.name, math.floor(it.dx + 0.5), math.floor(it.dy + 0.5), math.floor(it.dz + 0.5), it.yaw,
            (i < #items) and "," or "")
    end
    jl[#jl + 1] = '  ]'
    jl[#jl + 1] = "}"

    ensureDir(BP_DIR)
    local safeName = bname:gsub("[\\/:*?\"<>|]", "_")
    local jsonPath = BP_DIR .. "\\" .. safeName .. ".json"
    writeFile(jsonPath, table.concat(jl, "\n"))

    local code = encodeShareCode(bname, items)
    local codePath = BP_DIR .. "\\" .. safeName .. ".fscb.txt"
    writeFile(codePath, code .. "\n")

    local clipOK = false
    if C.UseClipboard then clipOK = clipboardWrite(code) end

    LastExport = { name = bname, count = #items, code = code, file = jsonPath }

    log(string.format("=== 导出完成 ==="))
    log(string.format("  名称: %s   建筑: %d 座   阵营: %d", bname, #items, faction))
    log(string.format("  JSON: %s", jsonPath))
    log(string.format("  分享码: %d 字符%s", #code, clipOK and "（已复制到剪贴板，直接粘贴给朋友）" or "（见 .fscb.txt）"))
    local top = {}
    for i = 1, math.min(6, #idList) do
        top[#top + 1] = string.format("%s×%d", nameOf(idList[i].id), idList[i].cnt)
    end
    log("  主要构成: " .. table.concat(top, "  "))

    HUD(string.format("蓝图已导出：%s\n%d 座建筑%s", bname, #items,
        clipOK and "\n分享码已进剪贴板，可直接粘贴" or "\n分享码见 blueprints 目录"))
    return true
end

-- ============================================================================
-- 10. 导入
-- ============================================================================

local LastSpawned = {}   -- 上一次导入生成的 actor，用于撤销

local function postProcess(actor, faction)
    -- 阵营
    pcall(function() actor.BuildingFactionType = faction end)
    -- 立即完工
    if C.InstantComplete then
        pcall(function() actor.BuildingState = 2 end)                       -- EMOBuildingState::Normal
        pcall(function() actor.CurConstructProgress = 1.0 end)
        pcall(function() actor.CurCompletedConstructRequirementProgress = 1.0 end)
        pcall(function() actor.ConstructHPAppliedProgress = 1.0 end)
        callf(actor, "OnConstructCompletedBP")                              -- 有实现才会生效
    end
    -- 让 EasyMultiSave 持久化该 Actor
    local ems = emsCDO()
    local world = getWorld()
    if ems ~= nil and world ~= nil then
        callf(ems, "SetActorSaveProperties", world, false, true, false, 0)
    end
end

local function doImport(source)
    local world = getWorld()
    if world == nil then
        log("导入中止：不在游戏世界里")
        return false
    end

    local raw = source
    if raw == nil then
        raw = clipboardRead()
        if raw == nil or raw == "" then
            -- 退回 blueprints 目录里最新的 .fscb.txt
            local newest, newestTime = nil, nil
            os.execute('cmd /c dir /b /o-d "' .. BP_DIR .. '\\*.fscb.txt" > "' .. TMP_DIR .. '\\ls.txt" 2>nul')
            local ls = readFile(TMP_DIR .. "\\ls.txt")
            if ls then
                for line in ls:gmatch("[^\r\n]+") do
                    if line:match("%.fscb%.txt$") then newest = line break end
                end
            end
            if newest then
                raw = readFile(BP_DIR .. "\\" .. newest)
                log("剪贴板没有分享码，改用文件: " .. newest)
            end
        end
    end
    if raw == nil or raw == "" then
        log("导入中止：剪贴板里没有分享码，blueprints 目录也没有 .fscb.txt")
        HUD("导入失败：没有找到蓝图分享码")
        return false
    end

    local bp, err = decodeShareCode(raw)
    if bp == nil then
        log("导入中止：" .. tostring(err))
        HUD("导入失败：" .. tostring(err))
        return false
    end

    local ax, ay, az, how = placementAnchor()
    if ax == nil then
        log("导入中止：拿不到放置位置（需要在游戏世界里）")
        HUD("导入失败：拿不到放置位置")
        return false
    end
    log(string.format("导入「%s」%d 座，锚点 %.0f/%.0f/%.0f（来源：%s）", bp.name, #bp.items, ax, ay, az, how))

    local cdo = constructCDO()
    if cdo == nil then
        log("导入中止：找不到 MOConstructSubsystem")
        HUD("导入失败：找不到建造子系统")
        return false
    end

    if C.DryRun then
        log("DryRun=true：只解析不生成")
        HUD(string.format("（演练）%s：%d 座，可放置在 %.0f/%.0f", bp.name, #bp.items, ax, ay))
        return true
    end

    local tmpl = getPawn()
    local okCount, failCount = 0, 0
    local failReasons = {}
    local spawned = {}

    for _, it in ipairs(bp.items) do
        local x = ax + it.dx
        local y = ay + it.dy
        local z = az + it.dz
        local tf = makeTransform(x, y, z, it.yaw, tmpl)
        local ok, actor = pcall(function()
            return callf(cdo, "FastConstructBuildingActor", it.id, tf, 1, true)
        end)
        if ok and isValid(actor) then
            okCount = okCount + 1
            spawned[#spawned + 1] = actor
            postProcess(actor, 1)
        else
            failCount = failCount + 1
            local why = tostring(actor)
            failReasons[why] = (failReasons[why] or 0) + 1
        end
    end

    LastSpawned = spawned

    log(string.format("=== 导入完成 ===  成功 %d / 失败 %d（变换路径 %s）", okCount, failCount, makeTransformPath))
    if failCount > 0 then
        local i = 0
        for why, cnt in pairs(failReasons) do
            i = i + 1
            if i <= 3 then log(string.format("  失败样例: ×%d  %s", cnt, why)) end
        end
    end
    log("  按 Ctrl+Shift+Z 可撤销本次导入")

    HUD(string.format("蓝图已导入：%s\n成功 %d 座%s", bp.name, okCount,
        failCount > 0 and ("，失败 " .. failCount) or ""))
    return true
end

local function doUndo()
    if #LastSpawned == 0 then
        log("没有可撤销的导入记录")
        HUD("没有可撤销的导入")
        return
    end
    local cdo = constructCDO()
    if cdo == nil then return end
    local n = 0
    for _, actor in ipairs(LastSpawned) do
        if isValid(actor) then
            local ok = pcall(function() callf(cdo, "TearDownBuilding", actor) end)
            if ok then n = n + 1 end
        end
    end
    LastSpawned = {}
    log(string.format("已撤销导入：拆除 %d 座", n))
    HUD(string.format("已撤销导入，拆除 %d 座", n))
end

-- ============================================================================
-- 11. 诊断
-- ============================================================================

local function diagnostics()
    ensureDir(DUMP_DIR)
    local lines = {}
    local function w(s) lines[#lines + 1] = tostring(s) end

    w("FengShaBlueprint 诊断 " .. os.date("%Y-%m-%d %H:%M:%S"))
    w("MOD 目录: " .. BASE_DIR)
    w("引擎版本: " .. tostring(UEHelpers.GetEngineVersion and UEHelpers.GetEngineVersion() or "?"))
    w("")
    local world = getWorld()
    w("World: " .. (isValid(world) and "有效" or "无效（可能在主菜单）"))
    local pc = getPC()
    w("PlayerController: " .. (isValid(pc) and "有效" or "无效"))
    w("Pawn: " .. (isValid(getPawn()) and "有效" or "无效"))

    local bs = getBuildingSubsystem()
    w("BuildingSubsystem: " .. (isValid(bs) and "有效" or "无效"))
    if isValid(bs) then
        local arr = prop(bs, "AllBuildings")
        local n = 0
        if arr ~= nil then
            pcall(function() for _ in ipairs(arr) do n = n + 1 end end)
        end
        w("  AllBuildings 数量(枚举): " .. tostring(n))
        local list = collectBuildings()
        w("  采集结果: " .. tostring(list and #list or -1))
        if list then
            local fac = resolveFaction(list)
            w("  判定阵营: " .. tostring(fac))
            local shown = 0
            for _, b in ipairs(list) do
                if shown < 8 then
                    w(string.format("    id=%d(%s) 阵营=%d 状态=%d 位置=%.0f/%.0f/%.0f yaw=%.1f",
                        b.id, nameOf(b.id), b.faction, b.state, b.x, b.y, b.z, b.yaw))
                    shown = shown + 1
                end
            end
        end
    end

    w("")
    w("MOConstructSubsystem CDO: " .. (constructCDO() and "找到" or "缺失"))
    w("EMSFunctionLibrary CDO:   " .. (emsCDO() and "找到" or "缺失"))
    w("MOBlueprintFunctionLibrary CDO: " .. (moBPLib() and "找到" or "缺失"))
    w("FTransform 构造器: " .. tostring(type(FTransform)))
    w("名表条目: " .. tostring((function() local c = 0 for _ in pairs(NameMap) do c = c + 1 end return c end)()))

    local path = DUMP_DIR .. "\\diag_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
    writeFile(path, table.concat(lines, "\n") .. "\n")
    for _, s in ipairs(lines) do log(s) end
    log("诊断已写入 " .. path)
    HUD("诊断已写入 dumps 目录")
end

-- ============================================================================
-- 12. HUD（懒加载 UMG，仿 FengShaQoL 的已验证写法）
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

    hudOverlay = SafeConstructObject("/Script/UMG.UserWidget", gi, "FengShaBPHud")
    if not isValid(hudOverlay) then return end
    hudOverlay.WidgetTree = SafeConstructObject("/Script/UMG.WidgetTree", hudOverlay, "FengShaBPHudTree")
    hudCanvas = SafeConstructObject("/Script/UMG.CanvasPanel", hudOverlay.WidgetTree, "FengShaBPHudCanvas")
    hudOverlay.WidgetTree.RootWidget = hudCanvas

    hudBorder = SafeConstructObject("/Script/UMG.Border", hudCanvas, "FengShaBPHudBorder")
    pcall(function() hudBorder:SetBrushColor({ R = 0.03, G = 0.05, B = 0.10, A = 0.90 }) end)
    pcall(function() hudBorder:SetPadding({ Left = 16, Top = 12, Right = 16, Bottom = 12 }) end)

    hudText = SafeConstructObject("/Script/UMG.TextBlock", hudBorder, "FengShaBPHudText")
    if isValid(hudText) then
        pcall(function() hudText.Font.Size = 16 end)
        pcall(function() hudText:SetColorAndOpacity({ SpecifiedColor = { R = 0.95, G = 0.93, B = 0.85, A = 1 }, ColorUseRule = 0 }) end)
        pcall(function() hudText:SetShadowOffset({ X = 1, Y = 1 }) end)
    end
    pcall(function() hudBorder:SetContent(hudText) end)

    local slot = nil
    local okSlot, s = pcall(function() return hudCanvas:AddChildToCanvas(hudBorder) end)
    if okSlot then slot = s end
    if slot then
        pcall(function() slot:SetAutoSize(true) end)
        pcall(function() slot:SetAnchors({ Minimum = { X = 0.5, Y = 0 }, Maximum = { X = 0.5, Y = 0 } }) end)
        pcall(function() slot:SetAlignment({ X = 0.5, Y = 0 }) end)
        pcall(function() slot:SetPosition({ X = 0, Y = 90 }) end)
    end
    pcall(function() hudOverlay:AddToViewport(94) end)
end

function HUD(msg, seconds)
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
-- 13. 面板
-- ============================================================================

local function panelText()
    local L = {}
    table.insert(L, "==========================================")
    table.insert(L, "   烽沙 · 营造蓝图   v1.0")
    table.insert(L, "==========================================")
    table.insert(L, "")
    table.insert(L, "Ctrl+B        导出蓝图（自己的全部建筑）")
    table.insert(L, "Ctrl+Shift+B  导入蓝图（读剪贴板）")
    table.insert(L, "Ctrl+Shift+Z  撤销上一次导入")
    table.insert(L, "Ctrl+F11      诊断")
    table.insert(L, "")
    table.insert(L, "[当前设置]")
    table.insert(L, string.format("  导入后立即完工: %s", C.InstantComplete and "是（不扣材料）" or "否（生成工地，由民夫搬料施工，会自动扣材料）"))
    table.insert(L, string.format("  导出含施工中:   %s", C.IncludeConstructing and "是" or "否"))
    table.insert(L, string.format("  导出阵营:       %s", tostring(C.ExportFaction)))
    table.insert(L, string.format("  建筑上限:       %d", C.MaxBuildings))
    table.insert(L, string.format("  演练模式:       %s", C.DryRun and "是（只解析不生成）" or "否"))
    table.insert(L, "")
    local bs = getBuildingSubsystem()
    local n = 0
    if isValid(bs) then
        local arr = prop(bs, "AllBuildings")
        if arr ~= nil then pcall(function() for _ in ipairs(arr) do n = n + 1 end end) end
    end
    table.insert(L, string.format("[状态] 世界建筑 %d 座", n))
    if LastExport then
        table.insert(L, string.format("[最近导出] %s  共 %d 座", LastExport.name, LastExport.count))
        table.insert(L, string.format("  文件: %s", LastExport.file))
    end
    if #LastSpawned > 0 then
        table.insert(L, string.format("[可撤销] 上次导入 %d 座（Ctrl+Shift+Z）", #LastSpawned))
    end
    return table.concat(L, "\n")
end

local panelOverlay, panelCanvas, panelBorder, panelText_ = nil, nil, nil, nil
local panelVisible = false

local function buildPanel()
    if isValid(panelText_) then return true end
    local ok, gi = pcall(function() return UEHelpers.GetGameInstance() end)
    if not ok or not isValid(gi) then return false end
    panelOverlay = SafeConstructObject("/Script/UMG.UserWidget", gi, "FengShaBPPanel")
    if not isValid(panelOverlay) then return false end
    panelOverlay.WidgetTree = SafeConstructObject("/Script/UMG.WidgetTree", panelOverlay, "FengShaBPPanelTree")
    panelCanvas = SafeConstructObject("/Script/UMG.CanvasPanel", panelOverlay.WidgetTree, "FengShaBPPanelCanvas")
    panelOverlay.WidgetTree.RootWidget = panelCanvas
    panelBorder = SafeConstructObject("/Script/UMG.Border", panelCanvas, "FengShaBPPanelBorder")
    pcall(function() panelBorder:SetBrushColor({ R = 0.02, G = 0.025, B = 0.05, A = 0.92 }) end)
    pcall(function() panelBorder:SetPadding({ Left = 18, Top = 14, Right = 18, Bottom = 14 }) end)
    panelText_ = SafeConstructObject("/Script/UMG.TextBlock", panelBorder, "FengShaBPPanelText")
    if isValid(panelText_) then
        pcall(function() panelText_.Font.Size = 15 end)
        pcall(function() panelText_:SetColorAndOpacity({ SpecifiedColor = { R = 0.92, G = 0.92, B = 0.97, A = 1 }, ColorUseRule = 0 }) end)
    end
    pcall(function() panelBorder:SetContent(panelText_) end)
    local okSlot, slot = pcall(function() return panelCanvas:AddChildToCanvas(panelBorder) end)
    if okSlot and slot then
        pcall(function() slot:SetAutoSize(true) end)
        pcall(function() slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } }) end)
        pcall(function() slot:SetAlignment({ X = 0, Y = 0 }) end)
        pcall(function() slot:SetPosition({ X = 20, Y = 60 }) end)
    end
    pcall(function() panelOverlay:AddToViewport(95) end)
    return true
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
        local t = mkText(panelText())
        if t then pcall(function() panelText_:SetText(t) end) end
    end
    log("面板: " .. (v and "显示" or "隐藏"))
end

-- ============================================================================
-- 14. 启动
-- ============================================================================

loadNameMap()
ensureDir(BP_DIR)
ensureDir(TMP_DIR)
ensureDir(DUMP_DIR)

log(string.format("已加载 v1.1  立即完工=%s 含施工中=%s 上限=%d 演练=%s",
    tostring(C.InstantComplete),
    tostring(C.IncludeConstructing), C.MaxBuildings, tostring(C.DryRun)))
log("Ctrl+B 导出 / Ctrl+Shift+B 导入 / Ctrl+Shift+Z 撤销 / Ctrl+F12 面板 / Ctrl+F11 诊断")

-- HUD 自动隐藏
local function hudLoop()
    ExecuteInGameThreadWithDelay(500, function()
        if hudUntil > 0 and os.time() > hudUntil then
            hudUntil = 0
            if isValid(hudBorder) then
                pcall(function() hudBorder:SetVisibility(2) end)
            end
        end
        hudLoop()
    end)
end
hudLoop()

-- 主菜单世界跳过：拿不到 PlayerController 就不干活
local function ready()
    return getPC() ~= nil and getWorld() ~= nil
end

RegisterKeyBind(Key.B, { ModifierKey.CONTROL }, function()
    log("[键] Ctrl+B 导出")
    if not ready() then log("跳过：当前不在游戏世界（主菜单）") return end
    doExport()
end)

RegisterKeyBind(Key.B, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    log("[键] Ctrl+Shift+B 导入")
    if not ready() then log("跳过：当前不在游戏世界（主菜单）") return end
    doImport(nil)
end)

RegisterKeyBind(Key.Z, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    log("[键] Ctrl+Shift+Z 撤销")
    if not ready() then log("跳过：当前不在游戏世界（主菜单）") return end
    doUndo()
end)

RegisterKeyBind(Key.F12, { ModifierKey.CONTROL }, function()
    log("[键] Ctrl+F12 面板")
    setPanelVisible(not panelVisible)
end)

RegisterKeyBind(Key.F11, { ModifierKey.CONTROL }, function()
    log("[键] Ctrl+F11 诊断")
    diagnostics()
end)

-- ============================================================================
-- 15. 单元测试钩子（宿主设置 _G.__FSBP_TEST = true 时导出内部纯函数，供离线测试）
-- ============================================================================
if _G.__FSBP_TEST then
    _G.FSBP_TEST = {
        b64encode = b64encode,
        b64decode = b64decode,
        encodeShareCode = encodeShareCode,
        decodeShareCode = decodeShareCode,
        nameOf = nameOf,
        resolveFaction = resolveFaction,
        C = C,
    }
    print("[FengShaBP] 测试钩子已导出\n")
end
