local MOD = "FengShaFirstPerson"
local UEHelpers = require("UEHelpers")

local WALK_MESH_PATH = "/Game/MO/Art/Character/Soldier/Garment/MinFu/SK_Soldier_MinFu_Garment_02.SK_Soldier_MinFu_Garment_02"
local WALK_ANIM_NAME = "A_Game_Soldier_ChangBing_Neu_Stand_Walk_Prudent_B_Loop_"
local IDLE_ANIM_NAME = "A_Game_Soldier_ChangBing_Neu_Stand_Idle_02"
local ANIM_ROOTS = {
    "/Game/MO/Art/Character/Soldier/Animation/",
    "/Game/MO/Art/Character/Soldier/Animations/",
    "/Game/MO/Art/Character/Animation/Soldier/",
    "/Game/MO/Art/Character/Soldier/Anim/",
}

local active = false
local busy = false
local walkPawn, oldPawn, oldViewTarget, oldControlRotation
local oldMouseVisible
local inputKeys = {}
local walkAnim, idleAnim, wasMoving = nil, nil, false
local lastLog = 0
local inputApiErrorLogged = false

local function log(message)
    print("[" .. MOD .. "] " .. tostring(message) .. "\n")
end

local function valid(obj)
    if obj == nil then return false end
    local ok, result = pcall(function() return obj:IsValid() end)
    return ok and result == true
end

local function makeInputKey(name)
    local ok, key = pcall(function() return FKey() end)
    if ok and key ~= nil then
        local assigned = pcall(function() key.KeyName = FName(name) end)
        if assigned then return key end
    end
    return { KeyName = FName(name) }
end

local function keyDown(pc, key)
    local ok, down = pcall(function() return pc:IsInputKeyDown(key) end)
    if not ok and not inputApiErrorLogged then
        inputApiErrorLogged = true
        log("PlayerController:IsInputKeyDown 调用失败: " .. tostring(down))
    end
    return ok and down == true
end

local function mouseDelta(pc)
    local ok, dx, dy = pcall(function() return pc:GetInputMouseDelta() end)
    if not ok then
        if not inputApiErrorLogged then
            inputApiErrorLogged = true
            log("PlayerController:GetInputMouseDelta 调用失败: " .. tostring(dx))
        end
        return 0, 0
    end
    return tonumber(dx) or 0, tonumber(dy) or 0
end

local function resolveAnim(shortName)
    for _, className in ipairs({ "AnimSequence", "AnimationSequence" }) do
        local list = FindAllOf(className) or {}
        for _, obj in ipairs(list) do
            if valid(obj) then
                local fullName = obj:GetFullName()
                if fullName and fullName:find(shortName, 1, true) then return obj end
            end
        end
    end
    for _, root in ipairs(ANIM_ROOTS) do
        local path = root .. shortName .. "." .. shortName
        local ok, asset = pcall(LoadAsset, path)
        if ok and valid(asset) then return asset end
    end
    return nil
end

local function groundHeight(world, x, y)
    local lib = StaticFindObject("/Script/MOProject.Default__MOBlueprintFunctionLibrary")
    if not valid(lib) then return nil end
    local ok, result, outHeight = pcall(function()
        return lib:GetCurLandscapeHeightAtLocation(world, x, y)
    end)
    if not ok then return nil end
    if type(outHeight) == "number" then return outHeight end
    if type(result) == "number" then return result end
    return nil
end

local function restore()
    local pc = UEHelpers.GetPlayerController()
    if valid(pc) then
        if valid(oldPawn) then
            pcall(function() pc:Possess(oldPawn) end)
        else
            pcall(function() pc:UnPossess() end)
        end
        if oldControlRotation ~= nil then
            pcall(function() pc:SetControlRotation(oldControlRotation) end)
        end
        if valid(oldViewTarget) then
            pcall(function() pc:SetViewTargetWithBlend(oldViewTarget, 0.6) end)
        end
        if oldMouseVisible ~= nil then
            pcall(function() pc.bShowMouseCursor = oldMouseVisible end)
        end
    end
    if valid(walkPawn) then pcall(function() walkPawn:K2_DestroyActor() end) end

    active = false
    walkPawn, oldPawn, oldViewTarget, oldControlRotation = nil, nil, nil, nil
    inputKeys = {}
    walkAnim, idleAnim, wasMoving = nil, nil, false
    log("已请求恢复原 Pawn 和建造视角")
end

local function enter()
    local pc = UEHelpers.GetPlayerController()
    local world = UEHelpers.GetWorld()
    if not valid(pc) or not valid(world) then
        log("当前没有可用的领地 PlayerController/World；请先读档进入领地")
        return
    end

    local source = pc.Pawn
    if not valid(source) then
        log("当前没有原 Pawn，取消切换")
        return
    end

    inputKeys = {
        w = makeInputKey("W"), a = makeInputKey("A"),
        s = makeInputKey("S"), d = makeInputKey("D"),
        shift = makeInputKey("LeftShift"),
    }

    local characterClass = StaticFindObject("/Script/Engine.Character")
    if not valid(characterClass) or not characterClass:IsClass() then
        log("找不到引擎 ACharacter 类")
        return
    end

    local mesh = LoadAsset(WALK_MESH_PATH)
    if not valid(mesh) then
        log("村民骨骼网格加载失败: " .. WALK_MESH_PATH)
        return
    end

    local sourceView = pc:GetViewTarget()
    if not valid(sourceView) then sourceView = source end
    local sourceLoc = sourceView:K2_GetActorLocation()
    local sourceRot = sourceView:K2_GetActorRotation()
    local floorZ = groundHeight(world, sourceLoc.X, sourceLoc.Y)
    if floorZ == nil then
        log("游戏地形高度查询失败；没有生成 Pawn")
        return
    end

    local spawnLoc = { X = sourceLoc.X, Y = sourceLoc.Y, Z = floorZ + 320.0 }
    local spawnRot = { Pitch = 0.0, Yaw = sourceRot.Yaw, Roll = 0.0 }
    walkPawn = world:SpawnActor(characterClass, spawnLoc, spawnRot)
    if not valid(walkPawn) then
        log("ACharacter SpawnActor 失败")
        return
    end

    local configured, configureError = pcall(function()
        walkPawn.Mesh:SetSkeletalMeshAsset(mesh)
        walkPawn.Mesh:SetAnimationMode(1, true) -- EAnimationMode::AnimationSingleNode
        walkPawn.bUseControllerRotationYaw = true
        walkPawn.bUseControllerRotationPitch = false
        walkPawn.bUseControllerRotationRoll = false
        walkPawn.CharacterMovement.bOrientRotationToMovement = false
        walkPawn.CharacterMovement.MaxWalkSpeed = 340.0
        walkPawn.BaseEyeHeight = 64.0
    end)
    if not configured then
        log("角色/网格初始化失败: " .. tostring(configureError))
        pcall(function() walkPawn:K2_DestroyActor() end)
        walkPawn = nil
        return
    end

    walkAnim = resolveAnim(WALK_ANIM_NAME)
    idleAnim = resolveAnim(IDLE_ANIM_NAME)
    if idleAnim ~= nil then
        pcall(function() walkPawn.Mesh:PlayAnimation(idleAnim, true) end)
    end
    if walkAnim == nil then
        log("未找到士兵走路序列；移动可用，但角色可能保持站姿")
    end

    oldPawn = source
    oldViewTarget = pc:GetViewTarget()
    oldControlRotation = pc:GetControlRotation()
    oldMouseVisible = pc.bShowMouseCursor

    pc:Possess(walkPawn)
    pc:SetControlRotation(spawnRot)
    pc.bShowMouseCursor = false
    pc:SetViewTargetWithBlend(walkPawn, 0.6)
    active = true
    wasMoving = false
    log("已进入第一人称步行：WASD 移动、鼠标转向；Ctrl+Alt+F8 返回")
end

local function toggle()
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if active then restore() else enter() end
        end)
        if not ok then
            if valid(oldPawn) then
                pcall(restore)
            elseif valid(walkPawn) then
                pcall(function() walkPawn:K2_DestroyActor() end)
            end
            active, walkPawn = false, nil
            log("切换异常，已尝试清理并回退: " .. tostring(err))
        end
    end)
end

local function applyInput(input)
    if not active or not valid(walkPawn) then return end

    local x = (input.w and 1 or 0) - (input.s and 1 or 0)
    local y = (input.d and 1 or 0) - (input.a and 1 or 0)
    local moving = x ~= 0 or y ~= 0
    local norm = (moving and x ~= 0 and y ~= 0) and 0.70710678 or 1.0

    if x ~= 0 then
        walkPawn:AddMovementInput(walkPawn:K2_GetActorForwardVector(), x * norm, false)
    end
    if y ~= 0 then
        walkPawn:AddMovementInput(walkPawn:K2_GetActorRightVector(), y * norm, false)
    end
    if input.shift then
        walkPawn.CharacterMovement.MaxWalkSpeed = 520.0
    else
        walkPawn.CharacterMovement.MaxWalkSpeed = 340.0
    end
    if input.dx ~= 0 then walkPawn:AddControllerYawInput(input.dx * 0.075) end
    if input.dy ~= 0 then walkPawn:AddControllerPitchInput(-input.dy * 0.075) end

    if moving ~= wasMoving then
        local anim = moving and walkAnim or idleAnim
        if valid(anim) then pcall(function() walkPawn.Mesh:PlayAnimation(anim, true) end) end
        wasMoving = moving
    end
end

RegisterKeyBind(Key.F8, { ModifierKey.CONTROL, ModifierKey.ALT }, toggle)
RegisterKeyBind(Key.F8, toggle)
RegisterKeyBind(Key.F9, { ModifierKey.CONTROL, ModifierKey.ALT }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function() if active then restore() end end)
        if not ok then log("紧急恢复异常: " .. tostring(err)) end
    end)
end)
RegisterConsoleCommandHandler("fsfp", function()
    toggle()
    return true
end)
RegisterConsoleCommandHandler("fsfp_return", function()
    ExecuteInGameThread(function()
        local ok, err = pcall(function() if active then restore() end end)
        if not ok then log("控制台恢复异常: " .. tostring(err)) end
    end)
    return true
end)

LoopAsync(16, function()
    if active and not busy then
        busy = true
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                local pc = UEHelpers.GetPlayerController()
                if not valid(pc) then return end
                local dx, dy = mouseDelta(pc)
                applyInput({
                    w = keyDown(pc, inputKeys.w), a = keyDown(pc, inputKeys.a),
                    s = keyDown(pc, inputKeys.s), d = keyDown(pc, inputKeys.d),
                    shift = keyDown(pc, inputKeys.shift), dx = dx, dy = dy,
                })
            end)
            busy = false
            if not ok then
                local now = os.clock()
                if now - lastLog > 3 then
                    log("输入更新失败: " .. tostring(err))
                    lastLog = now
                end
            end
        end)
    end
    return false
end)

log("已加载；F8/Ctrl+Alt+F8 或控制台 fsfp 切换；Ctrl+Alt+F9 或 fsfp_return 恢复")
