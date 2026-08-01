-- ========================================================================= --
--                                  SERVICES                                  --
-- ========================================================================= --
local RunService          = game:GetService("RunService")
local Players             = game:GetService("Players")
local LocalPlayer         = Players.LocalPlayer
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local UserInputService    = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser         = game:GetService("VirtualUser")
local GuiService          = game:GetService("GuiService")

-- ========================================================================= --
--                                 DEV FLAGS                                   --
-- ========================================================================= --
local DEBUG_TAB_ENABLED   = true -- set to false before publishing

-- ========================================================================= --
--                                  REMOTES                                   --
-- ========================================================================= --
local RemotesServer       = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Server")
local CombatClientRemote  = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network"):WaitForChild(
    "CombatClientRemoteEvent")
local RemotesFolder       = ReplicatedStorage:WaitForChild("Remotes")
local SprintRemote        = RemotesFolder:FindFirstChild("Sprint")
local SprintUpdateRemote  = RemotesFolder:FindFirstChild("SprintUpdate")


-- ========================================================================= --
--                               AUTO PARRY STATE                             --
-- ========================================================================= --
local AutoParry            = {
    Enabled = false,
    PerfectEnabled = false,
    AnimationSyncEnabled = false,
    FacingEnabled = false,
    GrappleAwareEnabled = false,
    LastGrappleDodge = 0,
    AutoPunishEnabled = false,
    LastAutoPunish = 0,
    IsBlocking = false,
    BlockToken = 0,
    LastPerfectResult = 0,
    LastBlockResult = 0,
    FacingHumanoid = nil,
    PreviousAutoRotate = nil,
    DefaultImpactTime = 0.35,
    ImpactLead = 0.06,
    ParryDuration = 0.30,
    MinParryDelay = 0.01,
    MaxDistance = 6,
    ParryToken = 0,
    LastSwing = {},
    PendingParry = {},
    RecentAttackAnimations = {},
    LearnedImpactTime = {},
    Notification = false,
    TotalPerfectBlocks = 0,
    TotalBlocks = 0,
    TotalParries = 0,
    -- New features
    FaceLockEnabled = false,
    FaceTargetRange = 7,
    BlockM1Enabled = false,
    BlockM1Active = false,
    ComboHoldEnabled = false,
    ComboHoldExtra = 0.35,
    FacingCheckEnabled = false,
    PingAdjustPercent = 100,
    SmoothedPing = 0,
    LastPingSample = 0,
    -- Fallback safety block: hold block when parry isn't possible
    FallbackBlockEnabled = false,
    FallbackBlockDuration = 0.45,
    FallbackBlockRange = 12,
    LastFallbackBlock = 0,
    FaceLockConn = nil,
}

local PERFECT_PARRY_CONFIG = {
    MinDelay = 0.01,
    HoldTime = 0.30,
    MaxDistance = 18,
    M1ImpactTime = 0.42,
    M2ImpactTime = 0.61,
    InputLead = 0.09,
    MaxSyncCorrection = 0.12,
}

-- ── Per-combat-style impact timing ─────────────────────────────────────── --
-- Seconds from animation start to the hit actually landing, per style.
-- Key = lowercase style-folder fragment found in the registry path
-- (e.g. "boxing" matches ReplicatedStorage.Animations.Combat.BoxingAnims...).
-- `m1` = lead/reach attacks (1st/4th M1), `chain` = fast chain hits (2nd/3rd M1).
-- Tune these per style; faster styles need smaller values.
local STYLE_IMPACT_TIMES   = {
    boxing    = { m1 = 0.30, chain = 0.32 }, -- fast punches
    striker   = { m1 = 0.34, chain = 0.35 }, -- fast strikes
    kure      = { m1 = 0.34, chain = 0.36 }, -- fast assassination style
    karate    = { m1 = 0.38, chain = 0.39 }, -- disciplined, medium
    capoeira  = { m1 = 0.40, chain = 0.41 }, -- spinning kicks
    hakari    = { m1 = 0.40, chain = 0.42 }, -- medium
    basic     = { m1 = 0.42, chain = 0.40 }, -- baseline default
    muaythai  = { m1 = 0.45, chain = 0.44 }, -- heavy kicks / elbows
    wrestling = { m1 = 0.48, chain = 0.46 }, -- grappling, slow
    slugger   = { m1 = 0.50, chain = 0.48 }, -- heavy haymakers
}

-- Returns the style key for a registry path, or nil if unknown/base.
local function getCombatStyleFromPath(lowerPath)
    for style in STYLE_IMPACT_TIMES do
        if string.find(lowerPath, style, 1, true) then
            return style
        end
    end
    return nil
end

local function getPerfectDefaultImpactTime(registryPath)
    local lowerPath = string.lower(registryPath)
    if string.find(lowerPath, "m2", 1, true) then
        return PERFECT_PARRY_CONFIG.M2ImpactTime
    end
    local isChain = string.find(lowerPath, "2ndm1", 1, true)
        or string.find(lowerPath, "3rdm1", 1, true)

    -- Style-specific timing (covers Boxing, Karate, MuayThai, Slugger, etc.)
    local style = getCombatStyleFromPath(lowerPath)
    if style then
        local timing = STYLE_IMPACT_TIMES[style]
        return isChain and timing.chain or timing.m1
    end

    -- Unknown / base style fallback
    if isChain then
        return 0.40
    end
    if string.find(lowerPath, "1stm1", 1, true)
        or string.find(lowerPath, "4thm1", 1, true) then
        return 0.43
    end
    return PERFECT_PARRY_CONFIG.M1ImpactTime
end

local function isAnyAutoParryEnabled()
    return AutoParry.Enabled or AutoParry.PerfectEnabled
end

-- ── Mobile detection: auto-compensate for lower FPS / scheduler jitter ── --
-- Extra lead (seconds) added on mobile to counter task.delay granularity
local MOBILE_EXTRA_LEAD = (UserInputService.TouchEnabled
    and not UserInputService.MouseEnabled
    and not UserInputService.KeyboardEnabled) and 0.04 or 0

local function getNetworkOneWayTime()
    local now = os.clock()
    if now - AutoParry.LastPingSample > 0.5 then
        AutoParry.LastPingSample = now
        local success, ping = pcall(function()
            return LocalPlayer:GetNetworkPing()
        end)
        local raw = success and math.clamp(ping, 0, 0.5) or 0
        -- Smoothed ping (EMA) to avoid jitter
        AutoParry.SmoothedPing = AutoParry.SmoothedPing * 0.7 + raw * 0.3
    end
    -- Full round-trip * adjust%
    return AutoParry.SmoothedPing * (AutoParry.PingAdjustPercent / 100)
end

local function getAnimationSyncCorrection(track)
    local success, timePosition, speed = pcall(function()
        return track.TimePosition, track.Speed
    end)
    if not success or type(timePosition) ~= "number" or type(speed) ~= "number"
        or timePosition < 0 or speed <= 0.05 or speed > 4 then
        return 0, false
    end

    local correction = math.clamp(timePosition / speed,
        0, PERFECT_PARRY_CONFIG.MaxSyncCorrection)
    return correction, correction > 0.001
end

-- ========================================================================= --
--                               PARRY FUNCTION                               --
-- ========================================================================= --
local Dbg = {
    Events = false,
    CopyKey = Enum.KeyCode.F8,
    Timeline = {},
    StartedAt = os.clock(),
    StunEvents = false,
    StunTimeline = {},
    StunStartedAt = os.clock(),
    ArDebug = false,
    ArTimeline = {},
}

local function debugLog(...)
    local values = { ... }
    for index, value in values do
        values[index] = tostring(value)
    end

    local line = string.format("+%.6f | %s", os.clock() - Dbg.StartedAt,
        table.concat(values, " "))
    table.insert(Dbg.Timeline, line)
    if #Dbg.Timeline > 1500 then
        table.remove(Dbg.Timeline, 1)
    end
    print(line)
end

local function getAutoParryDebugOutput()
    local header = table.concat({
        "BagahHub Gakuran Auto Parry Debug",
        "Copied: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
        "ImpactLead: " .. tostring(AutoParry.ImpactLead),
        "ParryDuration: " .. tostring(AutoParry.ParryDuration),
        "MinParryDelay: " .. tostring(AutoParry.MinParryDelay),
        "MaxDistance: " .. tostring(AutoParry.MaxDistance),
        "PerfectBlocks: " .. tostring(AutoParry.TotalPerfectBlocks),
        "Blocks: " .. tostring(AutoParry.TotalBlocks),
        "ParryAttempts: " .. tostring(AutoParry.TotalParries),
        "--- TIMELINE ---",
    }, "\n")
    return header .. "\n" .. table.concat(Dbg.Timeline, "\n")
end

local function stunDebugValue(value, depth)
    depth = depth or 0
    local valueType = typeof(value)
    if valueType == "Instance" then return tostring(value) end
    if valueType ~= "table" then return tostring(value) end
    if depth >= 2 then return "{...}" end

    local values = {}
    local count = 0
    for key, child in pairs(value) do
        count += 1
        if count > 16 then
            table.insert(values, "...")
            break
        end
        table.insert(values, tostring(key) .. "=" .. stunDebugValue(child, depth + 1))
    end
    return "{" .. table.concat(values, ", ") .. "}"
end

local function stunDebugLog(tag, ...)
    if not Dbg.StunEvents then return end
    local values = { ... }
    for index, value in ipairs(values) do
        values[index] = stunDebugValue(value)
    end
    local line = string.format("+%.6f | [STUN %s] %s",
        os.clock() - Dbg.StunStartedAt, tag, table.concat(values, " "))
    table.insert(Dbg.StunTimeline, line)
    if #Dbg.StunTimeline > 2000 then table.remove(Dbg.StunTimeline, 1) end
    print(line)
end

local function getStunDebugOutput()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local header = table.concat({
        "BagahHub Gakuran Stun/Ragdoll Debug",
        "Copied: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
        "HumanoidState: " .. tostring(humanoid and humanoid:GetState() or "none"),
        "--- TIMELINE ---",
    }, "\n")
    return header .. "\n" .. table.concat(Dbg.StunTimeline, "\n")
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if not Dbg.StunEvents then return end
    local inputName = input.UserInputType == Enum.UserInputType.Keyboard
        and input.KeyCode.Name or input.UserInputType.Name
    stunDebugLog("INPUT BEGIN", inputName, "processed=", gameProcessed)
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
    if not Dbg.StunEvents then return end
    local inputName = input.UserInputType == Enum.UserInputType.Keyboard
        and input.KeyCode.Name or input.UserInputType.Name
    stunDebugLog("INPUT END", inputName, "processed=", gameProcessed)
end)


local function holdBlock()
    AutoParry.BlockToken += 1
    local blockToken = AutoParry.BlockToken
    if AutoParry.IsBlocking then return blockToken end
    AutoParry.IsBlocking = true
    RemotesServer:FireServer({
        Type = "Combat",
        Action = "Block",
        Func = "Activated"
    }, tick())
    debugLog("[BagahHub BLOCK]", "HELD", "serverTime:", workspace:GetServerTimeNow())
    return blockToken
end

local function restoreParryFacing()
    local humanoid = AutoParry.FacingHumanoid
    if humanoid and humanoid.Parent and AutoParry.PreviousAutoRotate ~= nil then
        humanoid.AutoRotate = AutoParry.PreviousAutoRotate
    end
    AutoParry.FacingHumanoid = nil
    AutoParry.PreviousAutoRotate = nil
end

local function releaseBlock(expectedToken)
    if expectedToken and expectedToken ~= AutoParry.BlockToken then return end
    if not AutoParry.IsBlocking then
        restoreParryFacing()
        return
    end
    AutoParry.IsBlocking = false
    RemotesServer:FireServer({
        Type = "Combat",
        Action = "Block",
        Func = "Deactivated"
    })
    restoreParryFacing()
    debugLog("[BagahHub BLOCK]", "RELEASED", "serverTime:", workspace:GetServerTimeNow())
end

local function getCombatModel(modelName)
    local workspacePlayers = workspace:FindFirstChild("Players")
    local workspaceNpcs = workspace:FindFirstChild("NPCs")
    local model = workspacePlayers and workspacePlayers:FindFirstChild(modelName)
        or workspaceNpcs and workspaceNpcs:FindFirstChild(modelName)
    local player = Players:FindFirstChild(modelName)
    return model or player and player.Character
end

local function faceAttacker(attackerName)
    if not AutoParry.FacingEnabled then return end

    local localModel = LocalPlayer.Character or getCombatModel(LocalPlayer.Name)
    local attackerModel = getCombatModel(attackerName)
    local localRoot = localModel and localModel:FindFirstChild("HumanoidRootPart")
    local attackerRoot = attackerModel and attackerModel:FindFirstChild("HumanoidRootPart")
    local humanoid = localModel and localModel:FindFirstChildOfClass("Humanoid")
    if not localRoot or not attackerRoot or not humanoid then return end

    -- Only face if within FaceTargetRange
    local dist = (attackerRoot.Position - localRoot.Position).Magnitude
    if dist > AutoParry.FaceTargetRange then return end

    local targetPosition = Vector3.new(attackerRoot.Position.X,
        localRoot.Position.Y, attackerRoot.Position.Z)
    if (targetPosition - localRoot.Position).Magnitude < 0.01 then return end

    if AutoParry.FacingHumanoid ~= humanoid then
        restoreParryFacing()
        AutoParry.FacingHumanoid = humanoid
        AutoParry.PreviousAutoRotate = humanoid.AutoRotate
    end
    humanoid.AutoRotate = false
    localRoot.CFrame = CFrame.lookAt(localRoot.Position, targetPosition)
    debugLog("[BagahHub FACING]", "turned toward", attackerName)
end

local function getAttackerDistance(attackerName)
    local attackerModel = getCombatModel(attackerName)

    local localModel = LocalPlayer.Character or getCombatModel(LocalPlayer.Name)
    local localRoot = localModel and localModel:FindFirstChild("HumanoidRootPart")
    local attackerRoot = attackerModel and attackerModel:FindFirstChild("HumanoidRootPart")
    if not localRoot or not attackerRoot then return math.huge end
    return (localRoot.Position - attackerRoot.Position).Magnitude
end

-- ── Facing Check: only parry attackers actually facing you ───────────── --
local function isAttackerFacingMe(attackerName, maxAngle)
    local attackerModel = getCombatModel(attackerName)
    local attackerRoot = attackerModel and attackerModel:FindFirstChild("HumanoidRootPart")
    local localModel = LocalPlayer.Character or getCombatModel(LocalPlayer.Name)
    local localRoot = localModel and localModel:FindFirstChild("HumanoidRootPart")
    if not attackerRoot or not localRoot then return true end -- can't tell, allow parry
    local toMe = (localRoot.Position - attackerRoot.Position)
    if toMe.Magnitude < 0.01 then return true end
    toMe = toMe.Unit
    local look = attackerRoot.CFrame.LookVector
    local dot = look:Dot(toMe)
    -- dot > cos(angle): 0.5 = 60deg, 0 = 90deg
    return dot > (maxAngle or 0.3)
end

-- ── Face Lock: rotate toward nearest enemy continuously ──────────────── --

local function stopFaceLock()
    if AutoParry.FaceLockConn then
        AutoParry.FaceLockConn:Disconnect()
        AutoParry.FaceLockConn = nil
    end
    restoreParryFacing()
end

local function startFaceLock()
    if AutoParry.FaceLockConn then return end
    AutoParry.FaceLockConn = RunService.Heartbeat:Connect(function()
        if not AutoParry.FaceLockEnabled then
            stopFaceLock()
            return
        end
        local char = LocalPlayer.Character
        if not char then return end
        local root = char:FindFirstChild("HumanoidRootPart")
        local humanoid = char:FindFirstChildOfClass("Humanoid")
        if not root or not humanoid then return end

        -- Find nearest enemy within FaceTargetRange
        local nearest, nearestDist = nil, AutoParry.FaceTargetRange
        local containers = { workspace:FindFirstChild("Players"), workspace:FindFirstChild("NPCs") }
        for _, container in containers do
            if container then
                for _, model in container:GetChildren() do
                    if model:IsA("Model") and model ~= char and model.Name ~= LocalPlayer.Name then
                        local hrp = model:FindFirstChild("HumanoidRootPart")
                        local hum = model:FindFirstChildOfClass("Humanoid")
                        if hrp and hum and hum.Health > 0 then
                            local d = (hrp.Position - root.Position).Magnitude
                            if d < nearestDist then
                                nearest, nearestDist = hrp, d
                            end
                        end
                    end
                end
            end
        end

        if nearest then
            if AutoParry.FacingHumanoid ~= humanoid then
                restoreParryFacing()
                AutoParry.FacingHumanoid = humanoid
                AutoParry.PreviousAutoRotate = humanoid.AutoRotate
            end
            humanoid.AutoRotate = false
            local target = Vector3.new(nearest.Position.X, root.Position.Y, nearest.Position.Z)
            if (target - root.Position).Magnitude > 0.01 then
                root.CFrame = CFrame.lookAt(root.Position, target)
            end
        end
    end)
end

local function tapParry(attackerName, delay, holdTime, minDelay)
    local now = os.clock()
    if now - (AutoParry.LastSwing[attackerName] or 0) < 0.15 then return end

    -- Facing Check: skip if attacker isn't facing us
    if AutoParry.FacingCheckEnabled and not isAttackerFacingMe(attackerName) then
        return
    end

    AutoParry.LastSwing[attackerName] = now
    local generation = AutoParry.ParryToken
    local scheduledAt = now
    local parryDelay = math.max(minDelay or AutoParry.MinParryDelay,
        delay or (AutoParry.DefaultImpactTime - AutoParry.ImpactLead))
    AutoParry.PendingParry[attackerName] = scheduledAt
    faceAttacker(attackerName)

    if Dbg.Events then
        debugLog("[BagahHub SCHEDULE]", attackerName, "| delay:", parryDelay,
            "| hold:", holdTime or AutoParry.ParryDuration,
            "| mode:", AutoParry.PerfectEnabled and "perfect" or "normal")
    end

    task.delay(parryDelay, function()
        if not isAnyAutoParryEnabled() or generation ~= AutoParry.ParryToken
            or AutoParry.PendingParry[attackerName] ~= scheduledAt then
            return
        end
        AutoParry.PendingParry[attackerName] = nil
        faceAttacker(attackerName)
        local blockToken = holdBlock()
        AutoParry.TotalParries += 1

        -- Block M1: suppress own M1 until parry resolves
        if AutoParry.BlockM1Enabled then
            AutoParry.BlockM1Active = true
        end

        -- Hold Through Combo: extend hold for fast M1 chains
        local actualHold = holdTime or AutoParry.ParryDuration
        if AutoParry.ComboHoldEnabled then
            local lastSwing = AutoParry.LastSwing[attackerName] or 0
            local swingGap = now - lastSwing
            if swingGap < 0.6 then -- fast chain detected
                actualHold = actualHold + AutoParry.ComboHoldExtra
            end
        end

        task.delay(actualHold, function()
            AutoParry.BlockM1Active = false
            releaseBlock(blockToken)
        end)
    end)
end

-- ── Fallback Safety Block ─────────────────────────────────────────────── --
-- When a real parry can't be scheduled (out of range, facing-check fail,
-- cooldown, etc.) but an attack is incoming, hold block briefly so the
-- character still mitigates damage instead of eating it raw.
local function fallbackBlock(attackerName)
    if not AutoParry.FallbackBlockEnabled then return end
    if not isAnyAutoParryEnabled() then return end
    -- Don't override an active parry/block window
    if AutoParry.IsBlocking then return end
    local now = os.clock()
    if now - AutoParry.LastFallbackBlock < 0.35 then return end
    -- Only bother if the attacker is within fallback range
    if getAttackerDistance(attackerName) > AutoParry.FallbackBlockRange then return end

    AutoParry.LastFallbackBlock = now
    faceAttacker(attackerName)
    local blockToken = holdBlock()
    if Dbg.Events then
        debugLog("[BagahHub FALLBACK]", "safety block", "| attacker:", attackerName,
            "| hold:", AutoParry.FallbackBlockDuration)
    end
    task.delay(AutoParry.FallbackBlockDuration, function()
        releaseBlock(blockToken)
    end)
end

local notify

-- ========================================================================= --
--                       PRE-HIT ANIMATION DETECTION                         --
-- ========================================================================= --
local AnimReg = { Conns = {}, ModelConns = {}, Attack = {}, Grapple = {} }

local function normalizeAnimationId(animationId)
    return tostring(animationId or ""):match("%d+") or ""
end

local function registerAnimation(animation)
    if not animation:IsA("Animation") then return end
    local animationId = normalizeAnimationId(animation.AnimationId)
    if animationId ~= "" then
        AnimReg.Attack[animationId] = animation:GetFullName()
    end
end

local function registerGrappleAnimation(animation)
    if not animation:IsA("Animation") then return end
    local animationId = normalizeAnimationId(animation.AnimationId)
    if animationId ~= "" then
        AnimReg.Grapple[animationId] = animation:GetFullName()
    end
end

local function autoBackdash(attackerName, animationPath)
    local now = os.clock()
    if now - AutoParry.LastGrappleDodge < 0.75 then return end
    AutoParry.LastGrappleDodge = now
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.S, false, game)
    task.wait()
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Q, false, game)
    task.wait(0.04)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Q, false, game)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.S, false, game)
    debugLog("[BagahHub GRAPPLE]", "backdash from", attackerName,
        "| attack:", animationPath)
end

local function autoPunish(targetName)
    if not AutoParry.AutoPunishEnabled then return end
    local now = os.clock()
    if now - AutoParry.LastAutoPunish < 0.45 then return end
    AutoParry.LastAutoPunish = now

    task.spawn(function()
        releaseBlock()
        if targetName then faceAttacker(targetName) end
        task.wait(0.14)
        local camera = workspace.CurrentCamera
        local viewport = camera and camera.ViewportSize or Vector2.new(800, 600)
        local inset = GuiService:GetGuiInset()
        local clickX = math.floor(viewport.X * 0.5)
        local clickY = math.floor(viewport.Y * 0.5 + inset.Y)
        VirtualInputManager:SendMouseButtonEvent(clickX, clickY, 0, true, game, 0)
        task.wait(0.06)
        VirtualInputManager:SendMouseButtonEvent(clickX, clickY, 0, false, game, 0)
        if AutoParry.FacingEnabled then
            task.delay(0.15, restoreParryFacing)
        end
        debugLog("[BagahHub PUNISH]", "M1 counter", "| target:", targetName or "unknown")
    end)
end

local function buildAttackAnimationRegistry()
    table.clear(AnimReg.Attack)
    table.clear(AnimReg.Grapple)

    local roots = {
        ReplicatedStorage:FindFirstChild("Animations"),
        ReplicatedStorage:FindFirstChild("AnimationsLEGACY"),
    }
    local excludedFolders = {
        Dodges = true,
        Grappling = true,
        PerfectBlockAnims = true,
    }
    local excludedNames = {
        blocking = true,
        blockhit = true,
        idle = true,
        walk = true,
        parryer = true,
        parried = true,
    }

    for _, root in roots do
        if root then
            local baseCombat = root:FindFirstChild("BaseCombat")
            if baseCombat then
                for _, name in { "1stM1", "2ndM1", "3rdM1", "4thM1", "M2" } do
                    local animation = baseCombat:FindFirstChild(name)
                    if animation then
                        registerAnimation(animation)
                        if name == "M2" then registerGrappleAnimation(animation) end
                    end
                end
            end

            local combat = root:FindFirstChild("Combat")
            if combat then
                for _, animation in combat:GetDescendants() do
                    local excluded = false
                    local cursor = animation.Parent
                    while cursor and cursor ~= combat do
                        if excludedFolders[cursor.Name] then
                            excluded = true
                            break
                        end
                        cursor = cursor.Parent
                    end

                    local lowerName = animation.Name:lower():gsub("[^%w]", "")
                    local fullPath = animation:GetFullName()
                    local lowerPath = fullPath:lower()
                    local isGrappleMove = animation:IsA("Animation")
                        and (lowerPath:find("grappl", 1, true)
                            or lowerName == "m2"
                            or lowerName:find("m2", 1, true))
                    if isGrappleMove then
                        registerGrappleAnimation(animation)
                    end
                    if animation:IsA("Animation") and not excluded
                        and not excludedNames[lowerName]
                        and not lowerName:find("victim", 1, true)
                        and not lowerName:find("hitreact", 1, true)
                        and not lowerName:find("ehit", 1, true)
                        and not lowerName:find("block", 1, true)
                        and not lowerName:find("dodge", 1, true) then
                        registerAnimation(animation)
                    end
                end
            end
        end
    end

    local registeredCount = 0
    for _ in AnimReg.Attack do
        registeredCount += 1
    end
    debugLog("[BagahHub REGISTRY]", "Registered attack animations:", registeredCount)
end

buildAttackAnimationRegistry()

local function disconnectAnimator(model)
    local connection = AnimReg.Conns[model]
    if connection then
        connection:Disconnect()
        AnimReg.Conns[model] = nil
    end
end

local function watchCharacter(character)
    if not character:IsA("Model") or character == LocalPlayer.Character
        or character.Name == LocalPlayer.Name then
        return
    end
    disconnectAnimator(character)

    task.spawn(function()
        local humanoid = character:FindFirstChildOfClass("Humanoid")
            or character:WaitForChild("Humanoid", 10)
        local animator = humanoid and (humanoid:FindFirstChildOfClass("Animator")
            or humanoid:WaitForChild("Animator", 10))
        if not animator or not character.Parent then return end

        AnimReg.Conns[character] = animator.AnimationPlayed:Connect(function(track)
            if not isAnyAutoParryEnabled() and not AutoParry.GrappleAwareEnabled then return end
            if character:GetAttribute("CanFight") == false or character:GetAttribute("Ragdoll") == true then return end
            local maxDistance = AutoParry.PerfectEnabled
                and PERFECT_PARRY_CONFIG.MaxDistance or AutoParry.MaxDistance
            if getAttackerDistance(character.Name) > maxDistance then
                fallbackBlock(character.Name)
                return
            end

            local animationId = normalizeAnimationId(track.Animation and track.Animation.AnimationId)
            if animationId == "" then return end
            local registryPath = AnimReg.Attack[animationId]
            local grapplePath = AnimReg.Grapple[animationId]

            if Dbg.Events then
                debugLog("[BagahHub ANIMATION]", character.Name, "| name:", track.Name,
                    "| id:", animationId, "| priority:", track.Priority.Name,
                    "| attack:", registryPath or false, "| grapple:", grapplePath or false)
            end

            if AutoParry.GrappleAwareEnabled and grapplePath then
                AutoParry.PendingParry[character.Name] = nil
                task.spawn(autoBackdash, character.Name, grapplePath)
                return
            end

            if not registryPath then return end

            local candidates = AutoParry.RecentAttackAnimations[character.Name]
            if not candidates then
                candidates = {}
                AutoParry.RecentAttackAnimations[character.Name] = candidates
            end

            local attackStartedAt = os.clock()
            table.insert(candidates, {
                Id = animationId,
                StartedAt = attackStartedAt,
                Name = track.Name,
                Track = track,
            })

            while #candidates > 8 do
                table.remove(candidates, 1)
            end

            if AutoParry.PerfectEnabled then
                local function schedulePerfect(correction, syncValid)
                    if not AutoParry.PerfectEnabled or not character.Parent then return end
                    local impactTime = AutoParry.LearnedImpactTime[animationId]
                        or getPerfectDefaultImpactTime(registryPath)
                    local parryDelay = impactTime - PERFECT_PARRY_CONFIG.InputLead
                        - MOBILE_EXTRA_LEAD - getNetworkOneWayTime() - correction
                    if Dbg.Events then
                        debugLog("[BagahHub SYNC]", animationId,
                            "| enabled:", AutoParry.AnimationSyncEnabled,
                            "| correction:", correction,
                            "| animationValid:", syncValid,
                            "| timePosition:", track.TimePosition,
                            "| speed:", track.Speed,
                            "| delay:", math.max(PERFECT_PARRY_CONFIG.MinDelay, parryDelay))
                    end
                    tapParry(character.Name, parryDelay,
                        PERFECT_PARRY_CONFIG.HoldTime, PERFECT_PARRY_CONFIG.MinDelay)
                end

                if AutoParry.AnimationSyncEnabled then
                    -- Read TimePosition immediately (no Heartbeat:Wait, saves 1 frame on mobile)
                    local elapsed = os.clock() - attackStartedAt
                    local syncCorrection, syncValid = getAnimationSyncCorrection(track)
                    schedulePerfect(syncValid and syncCorrection or elapsed, syncValid)
                else
                    schedulePerfect(0, false)
                end
            else
                local impactTime = AutoParry.LearnedImpactTime[animationId]
                    or AutoParry.DefaultImpactTime
                local parryDelay = math.max(AutoParry.MinParryDelay,
                    impactTime - AutoParry.ImpactLead - MOBILE_EXTRA_LEAD)
                tapParry(character.Name, parryDelay)
            end
        end)
    end)
end

local function watchContainer(container)
    if not container then return end
    for _, character in container:GetChildren() do
        watchCharacter(character)
    end
    AnimReg.ModelConns[container] = container.ChildAdded:Connect(watchCharacter)
    container.ChildRemoved:Connect(disconnectAnimator)
end

watchContainer(workspace:WaitForChild("Players", 10))
watchContainer(workspace:WaitForChild("NPCs", 10))

for _, player in Players:GetPlayers() do
    if player ~= LocalPlayer and player.Character then watchCharacter(player.Character) end
end
Players.PlayerAdded:Connect(function(player)
    if player ~= LocalPlayer then player.CharacterAdded:Connect(watchCharacter) end
end)

-- ========================================================================= --
--                          INCOMING ATTACK DETECTION                         --
-- ========================================================================= --

CombatClientRemote.OnClientEvent:Connect(function(...)
    local args      = { ... }
    local eventType = args[1]

    if Dbg.Events then
        local argStr = ""
        for i = 1, math.min(#args, 6) do
            argStr = argStr .. tostring(args[i]) .. " | "
        end
        debugLog("[BagahHub EVENT]", eventType, "| Args:", argStr)
    end

    if not isAnyAutoParryEnabled() then return end


    if eventType == "NpcCombatSound" then
        local attacker = args[2]
        local action   = args[3]


        if action == "PunchSwing" and attacker ~= LocalPlayer.Name then
            local distance = getAttackerDistance(attacker)
            local maxDistance = AutoParry.PerfectEnabled
                and PERFECT_PARRY_CONFIG.MaxDistance or AutoParry.MaxDistance
            if distance <= maxDistance then
                local now = os.clock()
                local candidates = AutoParry.RecentAttackAnimations[attacker]
                local recent

                if candidates then
                    for index = #candidates, 1, -1 do
                        local candidate = candidates[index]
                        local age = now - candidate.StartedAt
                        if age > 2 then
                            table.remove(candidates, index)
                        elseif not recent and age >= 0.05 then
                            recent = candidate
                        end
                    end
                end

                if recent then
                    local impactTime = now - recent.StartedAt
                    if impactTime > 0.05 and impactTime < 2 then
                        local previousImpact = AutoParry.LearnedImpactTime[recent.Id]
                        local learnedImpact = previousImpact
                            and (previousImpact * 0.75 + impactTime * 0.25)
                            or impactTime
                        AutoParry.LearnedImpactTime[recent.Id] = learnedImpact
                        local learnedDelay = math.max(AutoParry.MinParryDelay,
                            learnedImpact - AutoParry.ImpactLead)
                        if Dbg.Events then
                            debugLog("[BagahHub LEARNED]", recent.Id, "| sample:", impactTime,
                                "| smoothed impact:", learnedImpact, "| next delay:", learnedDelay)
                        end
                    end
                elseif Dbg.Events then
                    debugLog("[BagahHub LEARN]", "no registered attack-animation candidate for", attacker)
                end
                if Dbg.Events then
                    debugLog("[BagahHub IMPACT]", attacker, "| distance:", distance)
                end
            end
        end


        if action == "PerfectBlocked" and attacker == LocalPlayer.Name then
            local now = os.clock()
            if now - AutoParry.LastPerfectResult >= 0.15 then
                AutoParry.TotalPerfectBlocks += 1
                AutoParry.LastPerfectResult = now
            end
            local recentTarget
            local recentTime = -math.huge
            for targetName, swingTime in pairs(AutoParry.LastSwing) do
                if swingTime > recentTime then
                    recentTime = swingTime
                    recentTarget = targetName
                end
            end
            autoPunish(recentTarget)
            if Dbg.Events then
                debugLog("[BagahHub RESULT]", "PERFECT PARRY (Sound)")
            end
            if AutoParry.Notification then
                notify("✨ Perfect Parry!", "Perfect block!", 1.5)
            end
        end


        if (action == "Blocked" or action == "BlockedAHit")
            and attacker == LocalPlayer.Name then
            local now = os.clock()
            if now - AutoParry.LastBlockResult >= 0.15 then
                AutoParry.TotalBlocks += 1
                AutoParry.LastBlockResult = now
            end
            if Dbg.Events then
                debugLog("[BagahHub RESULT]", "BLOCKED (Sound)")
            end
        end


        if action == "PunchHit" and attacker ~= LocalPlayer.Name then
            if Dbg.Events then
                debugLog("[BagahHub RESULT]", "HIT by", attacker)
            end
        end
    end


    if eventType == "CombatPairCosmetic" then
        local action   = args[2]
        local attacker = args[3]
        local victim   = args[4]

        if (action == "M1PerfectBlocked" or action == "M2PerfectBlocked")
            and victim == LocalPlayer.Name then
            local now = os.clock()
            if now - AutoParry.LastPerfectResult >= 0.15 then
                AutoParry.TotalPerfectBlocks += 1
                AutoParry.LastPerfectResult = now
            end
            autoPunish(attacker)
            if Dbg.Events then
                debugLog("[BagahHub RESULT]", "PERFECT PARRY | attacker:", attacker,
                    "| victim:", victim)
            end
            if AutoParry.Notification then
                notify("✨ Perfect Parry!", "Blocked " .. tostring(victim), 1.5)
            end
        end

        if (action == "M1Blocked" or action == "M2Blocked")
            and victim == LocalPlayer.Name then
            local now = os.clock()
            if now - AutoParry.LastBlockResult >= 0.15 then
                AutoParry.TotalBlocks += 1
                AutoParry.LastBlockResult = now
            end
            if Dbg.Events then
                debugLog("[BagahHub RESULT]", "BLOCKED | attacker:", attacker, "| victim:", victim)
            end
        end
    end
end)

-- ========================================================================= --
--                         CHARACTER RESET HANDLING                           --
-- ========================================================================= --
LocalPlayer.CharacterAdded:Connect(function(_character)
    AutoParry.ParryToken += 1
    AutoParry.IsBlocking = false
    AutoParry.BlockToken += 1
    AutoParry.LastPerfectResult = 0
    AutoParry.LastBlockResult = 0
    AutoParry.LastSwing = {}
    AutoParry.PendingParry = {}
    AutoParry.RecentAttackAnimations = {}
    AutoParry.LastGrappleDodge = 0
    AutoParry.LastAutoPunish = 0
    AutoParry.FacingHumanoid = nil
    AutoParry.PreviousAutoRotate = nil
end)

-- ========================================================================= --
local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()
WindUI.TransparencyValue = 0.2
WindUI:SetTheme("Crimson")

local Window = WindUI:CreateWindow({
    Title = "Bagah Hub - Gakuran",
    Icon = "sprout",
    Author = "Made by : Bagah Project",
    Folder = "BagahHubGakuran",
    Size = UDim2.fromOffset(450, 400),
    Theme = "Crimson",
    HidePanelBackground = false,
    Acrylic = false,
    HideSearchBar = false,
    SideBarWidth = 180,
})
Window:Tag({
    Title = "BETA",
    Color = Color3.fromHex("#FF00FF")
})

Window:Tag({
    Title = "V0.0.1",
    Color = Color3.fromHex("#FF9500")
})


Window:SetToggleKey(Enum.KeyCode.RightControl)

-- -------------------------------------------------------------------------- --
--                            NOTIFICATION FUNCTION                           --
-- -------------------------------------------------------------------------- --

local function Success(title, message, duration)
    WindUI:Notify({
        Title = title,
        Content = message,
        Duration = duration,
        Icon = "circle-check"
    })
end

local function Error(title, message, duration)
    WindUI:Notify({
        Title = title,
        Content = message,
        Duration = duration,
        Icon = "ban"
    })
end

local function Info(title, message, duration)
    WindUI:Notify({
        Title = title,
        Content = message,
        Duration = duration,
        Icon = "info"
    })
end

local function Warning(title, message, duration)
    WindUI:Notify({
        Title = title,
        Content = message,
        Duration = duration,
        Icon = "triangle-alert"
    })
end


-- ========================================================================= --
--                         PLAYER TAB / RHYTHM PLAYER                       --
-- ========================================================================= --
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Rhythm    = {
    Enabled = false,
    Root = nil,
    Active = {},
    Holds = {},
    Tokens = {},
    Keys = { Enum.KeyCode.X, Enum.KeyCode.C, Enum.KeyCode.N, Enum.KeyCode.M },
    Names = { "X", "C", "N", "M" },
    Receptors = {},
    LaneCount = 4,
    LastPress = {},
    HitWindow = UserInputService.TouchEnabled and 0.12 or 0.08,
    MinInterval = 0.015,
    NoteTravelTime = 2.5,
    TouchLeadTime = 0.06,
    Generation = 0,
    TouchMode = UserInputService.TouchEnabled,
    TouchPositions = {},
    TouchCorrection = nil,
    PendingTouches = {},
    -- ── Timing mode settings ──────────────────────────────────────────
    Mode = "perfect",   -- "perfect" | "custom"
    PressLeadMs = 0,    -- extra ms to press early (default 0)
    HoldExtendMs = 80,  -- extra ms to hold long notes (default 80)
    PerfectChance = 70, -- % chance of PERFECT in custom mode
    GoodChance = 25,    -- % chance of GOOD in custom mode
    OkChance = 5,       -- % chance of OK in custom mode
    -- ── Debug ─────────────────────────────────────────────────────────
    DebugEnabled = false,
    DebugTimeline = {},
    DebugStartedAt = os.clock(),
    LastMissingRootDebug = 0,
    -- ── Internal state (moved from locals to save upvalue slots) ─────
    BuildId = "rhythm-notetime-20260802-6",
    Connections = {},
    ManualTouchStarted = {},
    DebugRootReported = nil,
    TaskDelayComp = 0.016,
    RenderConn = nil,
    LastScan = 0,
    ScanInterval = 0.5,
    -- ── Rating Spy ──────────────────────────────────────────────────
    RatingSpy = false,
    RatingConn = nil,
    RatingRemoveConn = nil,
    RatingCounts = {},
    RatingTotal = 0,
    LastPressAt = {},
    GuiInspector = false,
    InspectorConnections = {},
    InspectorRoot = nil,
    InspectorIds = setmetatable({}, { __mode = "k" }),
    NextInspectorId = 0,
    ClockEvidence = {},
    -- ── Attribute-based timing (NoteTime / NoteLane) ────────────────
    ScrollSpeed = nil,
    ScrollSpeedSamples = {},
    SongTime = nil,
    SongTimeSamples = {},
    LastSongTimeAt = 0,
}

local function rhythmDebug(tag, ...)
    if not Rhythm.DebugEnabled then return end
    local values = { ... }
    for index, value in ipairs(values) do values[index] = tostring(value) end
    local line = string.format("+%.4f | [RHYTHM %s] %s",
        os.clock() - Rhythm.DebugStartedAt, tag, table.concat(values, " "))
    table.insert(Rhythm.DebugTimeline, line)
    if #Rhythm.DebugTimeline > 800 then table.remove(Rhythm.DebugTimeline, 1) end
end

local function makeRhythmDebugReport()
    local count = 0
    for _ in pairs(Rhythm.Active) do count += 1 end
    return table.concat({
        "BagahHub Gakuran Rhythm Debug",
        "Build: " .. Rhythm.BuildId,
        "Copied: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
        "TouchEnabled: " .. tostring(UserInputService.TouchEnabled),
        "KeyboardEnabled: " .. tostring(UserInputService.KeyboardEnabled),
        "TouchMode: " .. tostring(Rhythm.TouchMode),
        "Enabled: " .. tostring(Rhythm.Enabled),
        "Root: " .. tostring(Rhythm.Root),
        "LaneCount: " .. tostring(Rhythm.LaneCount),
        "TrackedNotes: " .. tostring(count),
        "ScrollSpeed: " .. tostring(Rhythm.ScrollSpeed),
        "SongTime: " .. tostring(Rhythm.SongTime),
        "--- RATING SPY ---",
        "RatingSpy: " .. tostring(Rhythm.RatingSpy),
        "Total: " .. tostring(Rhythm.RatingTotal),
        "Perfect: " .. tostring(Rhythm.RatingCounts["Perfect"] or 0),
        "Great: " .. tostring(Rhythm.RatingCounts["Great"] or 0),
        "Good: " .. tostring(Rhythm.RatingCounts["Good"] or 0),
        "Ok: " .. tostring(Rhythm.RatingCounts["Ok"] or 0),
        "Bad: " .. tostring(Rhythm.RatingCounts["Bad"] or 0),
        "Miss: " .. tostring(Rhythm.RatingCounts["Miss"] or 0),
        "--- CLOCK EVIDENCE ---",
        #Rhythm.ClockEvidence > 0 and table.concat(Rhythm.ClockEvidence, "\n") or "No clock candidates captured",
        "--- TIMELINE ---",
        table.concat(Rhythm.DebugTimeline, "\n"),
    }, "\n")
end

local function copyRhythmDebug()
    local output = makeRhythmDebugReport()
    if typeof(setclipboard) == "function" then
        setclipboard(output)
        print("[BagahHub RHYTHM] Debug copied to clipboard")
    else
        warn("[BagahHub RHYTHM] setclipboard unavailable; copy console output")
        print(output)
    end
end

-- ========================================================================= --
--                             DEBUG COPY UTILITY                              --
-- ========================================================================= --

-- ── Upload debug logs to a free paste service (paste.rs) ──────────────── --
-- Uses the executor's HTTP function. Prints the paste URL + copies to clipboard.
local function uploadDebugLogs(text)
    -- Safely resolve whichever HTTP function the executor exposes
    local env = getfenv and getfenv() or _G
    local httpFn = (typeof(request) == "function" and request)
        or (typeof(http_request) == "function" and http_request)
        or (typeof(syn) == "table" and syn.request)
        or (rawget(env, "http") and rawget(env, "http").request)

    if not httpFn then
        warn("[BagahHub UPLOAD] No executor HTTP function available (request/http_request)")
        return
    end

    print("[BagahHub UPLOAD] Uploading debug logs to paste.rs ...")

    task.spawn(function()
        local ok, res = pcall(function()
            return httpFn({
                Url = "https://paste.rs/",
                Method = "POST",
                Headers = { ["Content-Type"] = "text/plain" },
                Body = text,
            })
        end)

        if not ok or not res then
            warn("[BagahHub UPLOAD] Upload failed:", res or "no response")
            return
        end

        local body = res.Body or ""
        if res.StatusCode == 200 or res.StatusCode == 201 then
            local url = body:match("https?://%S+") or body
            print("[BagahHub UPLOAD] ✅ Debug log uploaded:", url)
            if typeof(setclipboard) == "function" then
                setclipboard(url)
                print("[BagahHub UPLOAD] URL copied to clipboard")
            end
            if notify then notify("📤 Debug Uploaded", url, 6) end
        else
            warn("[BagahHub UPLOAD] Server returned", res.StatusCode, body)
        end
    end)
end

local function copyActiveDebugLogs()
    local reports = {}
    if Dbg.Events then
        table.insert(reports, getAutoParryDebugOutput())
    end
    if Dbg.StunEvents then
        table.insert(reports, getStunDebugOutput())
    end
    if Rhythm.DebugEnabled then
        table.insert(reports, makeRhythmDebugReport())
    end
    if Dbg.ArDebug then
        local report = "=== Auto Respawn Debug ===\n"
        if #Dbg.ArTimeline > 0 then
            report = report .. table.concat(Dbg.ArTimeline, "\n")
        else
            report = report .. "(no knock events yet)"
        end
        table.insert(reports, report)
    end

    if #reports == 0 then
        warn("[BagahHub] Enable a debug logger before pressing F8")
        return
    end

    local output = table.concat(reports, "\n\n========================================\n\n")

    if typeof(setclipboard) == "function" then
        setclipboard(output)
        print("[BagahHub DEBUG COPY]", #reports, "active debug report(s) copied with F8")
    else
        warn("[BagahHub] Executor does not provide setclipboard")
    end

    uploadDebugLogs(output)
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if not gameProcessed and input.KeyCode == Dbg.CopyKey then
        copyActiveDebugLogs()
    end
    -- Track manual rhythm key presses for rating delta calculation
    if Rhythm.RatingSpy and input.UserInputType == Enum.UserInputType.Keyboard then
        for lane, key in ipairs(Rhythm.Keys) do
            if input.KeyCode == key then
                Rhythm.LastPressAt[lane] = os.clock()
                break
            end
        end
    end
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if input.UserInputType ~= Enum.UserInputType.Touch then return end
    local now = os.clock()
    if not Rhythm.TouchCorrection then
        for lane, pending in pairs(Rhythm.PendingTouches) do
            if now - pending.Time <= 0.25
                and math.abs(input.Position.X - pending.Target.X) <= 80 then
                Rhythm.TouchCorrection = pending.Sent - Vector2.new(
                    input.Position.X, input.Position.Y)
                table.clear(Rhythm.PendingTouches)
                rhythmDebug("TOUCH CALIBRATED", "lane=", lane,
                    "target=", pending.Target, "observed=", input.Position,
                    "correction=", Rhythm.TouchCorrection)
                break
            elseif now - pending.Time > 0.25 then
                Rhythm.PendingTouches[lane] = nil
            end
        end
    end

    if not Rhythm.DebugEnabled then return end
    Rhythm.ManualTouchStarted[input] = input.Position
    rhythmDebug("REAL TOUCH BEGIN", "pos=", input.Position,
        "processed=", processed, "state=", input.UserInputState)
end)

UserInputService.InputEnded:Connect(function(input, processed)
    if not Rhythm.DebugEnabled or input.UserInputType ~= Enum.UserInputType.Touch then return end
    rhythmDebug("REAL TOUCH END", "start=", Rhythm.ManualTouchStarted[input] or "unknown",
        "pos=", input.Position, "processed=", processed,
        "state=", input.UserInputState)
    Rhythm.ManualTouchStarted[input] = nil
end)

UserInputService.TouchTap:Connect(function(positions, processed)
    if not Rhythm.DebugEnabled then return end
    local values = {}
    for index, position in ipairs(positions) do values[index] = tostring(position) end
    rhythmDebug("REAL TOUCH TAP", "positions=", table.concat(values, ";"),
        "processed=", processed)
end)
-- ========================================================================= --
--                     INFINITE STAMINA + NO DODGE COOLDOWN                   --
-- ========================================================================= --
local CS                   = {
    InfiniteStamina = false,
    NoDodgeCooldown = false,
    AntiStun = false,
    AntiRagdoll = false,
    DodgeCooldownTime = 0,
    LastDodgeTime = 0,
    NamecallHooked = false,
    OldNamecall = nil,
    AntiStunConns = {},
    StunDebugConns = {},
}

local dodgeGateSpoof       = {
    OutnumberedEvasiveGrant = true,
    IFRAMECD                = nil,
    Ragdoll                 = nil,
    Blocking                = nil,
    CombatAttacking         = nil,
    Greenzone               = nil,
    RpCombatLocked          = nil,
    Downed                  = nil,
    Stunned                 = nil,
    GuardBroken             = nil,
    Grappling               = nil,
    CantAnything            = nil,
    CombatRecovery          = nil,
}

local dodgeBlockedSetAttrs = {
    IFRAMECD                 = true,
    EvasiveCooldownRemaining = true,
    CantAnything             = true,
}

local stunAttrs            = {
    Stunned        = true,
    GuardBroken    = true,
    CombatRecovery = true,
}

local ragdollAttrs         = {
    Ragdoll = true,
    Downed  = true,
}


local stunAnimationIds = {
    ["91352556581859"]  = true, -- heavy/M2 reaction (1.25 s)
    ["108045962864902"] = true, -- short hit reaction
    ["122541287927198"] = true, -- short hit reaction
    ["104407197874289"] = true, -- short hit reaction
}

local function disconnectAntiStunConnections()
    for _, connection in ipairs(CS.AntiStunConns) do
        connection:Disconnect()
    end
    table.clear(CS.AntiStunConns)
end

local function disconnectStunDebugConnections()
    for _, connection in ipairs(CS.StunDebugConns) do
        connection:Disconnect()
    end
    table.clear(CS.StunDebugConns)
end

local function attachStunDebug(character)
    disconnectStunDebugConnections()
    if not Dbg.StunEvents or not character then return end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
        or character:WaitForChild("Humanoid", 10)
    if not humanoid then
        stunDebugLog("ERROR", "Humanoid not found")
        return
    end

    stunDebugLog("ATTACH", character, "attributes=", character:GetAttributes(),
        "state=", humanoid:GetState(), "walkSpeed=", humanoid.WalkSpeed,
        "jumpPower=", humanoid.JumpPower, "platformStand=", humanoid.PlatformStand)

    table.insert(CS.StunDebugConns, character.AttributeChanged:Connect(function(attribute)
        stunDebugLog("ATTRIBUTE", attribute, "=", character:GetAttribute(attribute),
            "all=", character:GetAttributes())
    end))
    table.insert(CS.StunDebugConns, humanoid.StateChanged:Connect(function(oldState, newState)
        stunDebugLog("HUMANOID STATE", oldState, "->", newState,
            "walkSpeed=", humanoid.WalkSpeed, "platformStand=", humanoid.PlatformStand)
    end))
    table.insert(CS.StunDebugConns, humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
        stunDebugLog("PROPERTY", "WalkSpeed=", humanoid.WalkSpeed)
    end))
    table.insert(CS.StunDebugConns, humanoid:GetPropertyChangedSignal("PlatformStand"):Connect(function()
        stunDebugLog("PROPERTY", "PlatformStand=", humanoid.PlatformStand)
    end))

    local animator = humanoid:FindFirstChildOfClass("Animator")
        or humanoid:WaitForChild("Animator", 5)
    if animator then
        table.insert(CS.StunDebugConns, animator.AnimationPlayed:Connect(function(track)
            local animation = track.Animation
            stunDebugLog("ANIMATION", "name=", animation and animation.Name or track.Name,
                "id=", animation and animation.AnimationId or "none",
                "priority=", track.Priority, "length=", track.Length)
            table.insert(CS.StunDebugConns, track.Stopped:Connect(function()
                stunDebugLog("ANIMATION STOP", "name=", animation and animation.Name or track.Name,
                    "id=", animation and animation.AnimationId or "none")
            end))
        end))
    end
end

local function getRecoveryAnimationType(track)
    local animation = track.Animation
    local name = string.lower((animation and animation.Name) or track.Name or "")
    local animationId = animation and animation.AnimationId or ""
    local numericId = string.match(animationId, "%d+")
    if numericId and stunAnimationIds[numericId] then
        return "stun"
    end
    if string.find(name, "ragdoll", 1, true)
        or string.find(name, "getup", 1, true)
        or string.find(name, "knock", 1, true)
        or string.find(name, "downed", 1, true) then
        return "ragdoll"
    end
    if string.find(name, "stun", 1, true)
        or string.find(name, "recover", 1, true)
        or string.find(name, "guardbreak", 1, true) then
        return "stun"
    end
    return nil
end

local function cancelRecovery(character, humanoid)
    if not (CS.AntiStun or CS.AntiRagdoll) or not character or not humanoid then return end

    if CS.AntiRagdoll then
        humanoid.PlatformStand = false
        humanoid.Sit = false
        humanoid.AutoRotate = true
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

        local state = humanoid:GetState()
        if state == Enum.HumanoidStateType.Ragdoll
            or state == Enum.HumanoidStateType.FallingDown
            or state == Enum.HumanoidStateType.GettingUp
            or state == Enum.HumanoidStateType.PlatformStanding then
            humanoid:ChangeState(Enum.HumanoidStateType.Running)
        end
    end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if animator then
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            local animationType = getRecoveryAnimationType(track)
            if (animationType == "stun" and CS.AntiStun)
                or (animationType == "ragdoll" and CS.AntiRagdoll) then
                track:Stop(0)
            end
        end
    end
end

local function attachAntiStun(character)
    disconnectAntiStunConnections()
    if not (CS.AntiStun or CS.AntiRagdoll) or not character then return end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
        or character:WaitForChild("Humanoid", 10)
    if not humanoid then return end

    cancelRecovery(character, humanoid)
    table.insert(CS.AntiStunConns, character.AttributeChanged:Connect(function(attribute)
        if (CS.AntiStun and stunAttrs[attribute]) or (CS.AntiRagdoll and ragdollAttrs[attribute]) then
            task.defer(cancelRecovery, character, humanoid)
        end
    end))
    table.insert(CS.AntiStunConns, humanoid.StateChanged:Connect(function(_, newState)
        if CS.AntiRagdoll and (newState == Enum.HumanoidStateType.Ragdoll
                or newState == Enum.HumanoidStateType.FallingDown
                or newState == Enum.HumanoidStateType.GettingUp
                or newState == Enum.HumanoidStateType.PlatformStanding) then
            task.defer(cancelRecovery, character, humanoid)
        end
    end))

    local animator = humanoid:FindFirstChildOfClass("Animator")
        or humanoid:WaitForChild("Animator", 5)
    if animator then
        table.insert(CS.AntiStunConns, animator.AnimationPlayed:Connect(function(track)
            local animationType = getRecoveryAnimationType(track)
            if (animationType == "stun" and CS.AntiStun)
                or (animationType == "ragdoll" and CS.AntiRagdoll) then
                track:Stop(0)
            end
        end))
    end
end

-- Cached character reference (updated on CharacterAdded, avoids per-call lookup)
local cachedCharacter = LocalPlayer.Character

local function getLocalStaminaModel()
    return cachedCharacter
end

local function hookNamecall()
    if CS.NamecallHooked then return end
    CS.NamecallHooked = true

    local success, result = pcall(function()
        CS.OldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()

            if Dbg.StunEvents and (method == "FireServer" or method == "InvokeServer") then
                stunDebugLog("REMOTE OUT", method, self, { ... })
            end

            -- ── Stamina ────────────────────────────────────────────── --
            if CS.InfiniteStamina and self == cachedCharacter then
                if method == "SetAttribute" then
                    local attr = select(1, ...)
                    if attr == "Stamina" then
                        return CS.OldNamecall(self, "Stamina", 100)
                    end
                elseif method == "GetAttribute" then
                    local attr = select(1, ...)
                    if attr == "Stamina" then
                        return 100
                    end
                end
            end

            if CS.InfiniteStamina and method == "FireServer" and SprintRemote and self == SprintRemote then
                local arg1 = select(1, ...)
                if type(arg1) == "table" and arg1.Stamina ~= nil then
                    arg1.Stamina = 100
                end
                return CS.OldNamecall(self, ...)
            end

            -- ── No Dodge Cooldown (manual Q, no auto-loop) ──────────── --
            if CS.NoDodgeCooldown then
                if method == "GetAttribute" and self == cachedCharacter then
                    local attr = select(1, ...)
                    local spoofValue = dodgeGateSpoof[attr]
                    if spoofValue ~= nil then
                        return spoofValue
                    end
                elseif method == "SetAttribute" and self == cachedCharacter then
                    local attr = select(1, ...)
                    if dodgeBlockedSetAttrs[attr] then
                        return
                    end
                    if attr == "CombatActionToken" then
                        return CS.OldNamecall(self, "CombatActionToken", 1)
                    end
                elseif method == "FireServer" and CS.DodgeCooldownTime > 0 and self == RemotesServer then
                    local arg1 = select(1, ...)
                    if type(arg1) == "table"
                        and arg1.Type == "Combat"
                        and arg1.Action == "Evasive" then
                        local now = os.clock()
                        if now - CS.LastDodgeTime < CS.DodgeCooldownTime then
                            return
                        end
                        CS.LastDodgeTime = now
                    end
                end
            end

            -- ── Independent Anti-Stun / Anti-Ragdoll ───────────────── --
            if (CS.AntiStun or CS.AntiRagdoll) and method == "GetAttribute" and self == cachedCharacter then
                local attr = select(1, ...)
                if (CS.AntiStun and stunAttrs[attr])
                    or (CS.AntiRagdoll and ragdollAttrs[attr]) then
                    return nil
                end
            end

            -- ── Block M1 Until Parry Confirmed ──────────────────────── --
            if AutoParry.BlockM1Active and method == "FireServer" and self == RemotesServer then
                local arg1 = select(1, ...)
                if type(arg1) == "table" and arg1.Type == "Combat"
                    and (arg1.Action == "M1" or arg1.Action == "Attack") then
                    return -- suppress M1 so it doesn't cancel block
                end
            end

            return CS.OldNamecall(self, ...)
        end)
    end)

    if not success then
        warn("[BagahHub] __namecall hook failed:", result)
        CS.NamecallHooked = false
    else
        print("[BagahHub] Unified namecall hook active (stamina + dodge)")
    end
end

local function setInfiniteStamina(value)
    CS.InfiniteStamina = value
    if value then hookNamecall() end
end

local function setNoDodgeCooldown(value)
    CS.NoDodgeCooldown = value
    if value then
        hookNamecall()
    end
end

local function updateRecoveryProtection()
    if CS.AntiStun or CS.AntiRagdoll then
        hookNamecall()
        attachAntiStun(getLocalStaminaModel())
    else
        disconnectAntiStunConnections()
        local character = getLocalStaminaModel()
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
        end
    end
end

local function setAntiStun(value)
    CS.AntiStun = value
    updateRecoveryProtection()
end

local function setAntiRagdoll(value)
    CS.AntiRagdoll = value
    local character = getLocalStaminaModel()
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not value and humanoid then
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
    end
    updateRecoveryProtection()
end

LocalPlayer.CharacterAdded:Connect(function(character)
    cachedCharacter = character
    if CS.InfiniteStamina or CS.NoDodgeCooldown or CS.AntiStun or CS.AntiRagdoll or Dbg.StunEvents then
        CS.NamecallHooked = false
        hookNamecall()
    end
    if CS.AntiStun or CS.AntiRagdoll then
        task.defer(attachAntiStun, character)
    end
    if Dbg.StunEvents then
        task.defer(attachStunDebug, character)
    end
end)

local function rhythmReleaseAll()
    for lane, key in ipairs(Rhythm.Keys) do
        Rhythm.Tokens[key.Name] = nil
        pcall(function() VirtualInputManager:SendKeyEvent(false, key, false, game) end)
        local position = Rhythm.TouchPositions[lane]
        if position then
            pcall(function()
                local inset = Rhythm.TouchCorrection or GuiService:GetGuiInset()
                VirtualInputManager:SendTouchEvent(lane, 2,
                    position.X + inset.X, position.Y + inset.Y)
            end)
        end
    end
    table.clear(Rhythm.TouchPositions)
    table.clear(Rhythm.PendingTouches)
end

local function rhythmIsNote(instance)
    return instance:IsA("GuiObject") and instance.Name == "NoteTemplate"
end

local function rhythmKeyDown(key, duration)
    local name = key.Name
    local token = (Rhythm.Tokens[name] or 0) + 1
    Rhythm.Tokens[name] = token
    pcall(function() VirtualInputManager:SendKeyEvent(true, key, false, game) end)
    task.delay(math.clamp(duration or 0.15, 0.05, 5), function()
        if Rhythm.Tokens[name] == token then
            Rhythm.Tokens[name] = nil
            pcall(function() VirtualInputManager:SendKeyEvent(false, key, false, game) end)
        end
    end)
end

local function rhythmSendInput(lane, key, pressed)
    if Rhythm.TouchMode then
        local receptor = Rhythm.Receptors[lane]
        if not receptor or not receptor.Parent or not receptor.Visible then return false end
        local position = Rhythm.TouchPositions[lane] or Vector2.new(
            math.floor(receptor.AbsolutePosition.X + receptor.AbsoluteSize.X / 2),
            math.floor(receptor.AbsolutePosition.Y + receptor.AbsoluteSize.Y / 2)
        )
        if pressed then Rhythm.TouchPositions[lane] = position end
        local correction = Rhythm.TouchCorrection
        if not correction then
            correction = Vector2.zero
            pcall(function()
                correction = GuiService:GetGuiInset()
            end)
        end
        local inputPosition = position + correction
        if pressed and not Rhythm.TouchCorrection
            and next(Rhythm.PendingTouches) == nil then
            Rhythm.PendingTouches[lane] = {
                Target = position,
                Sent = inputPosition,
                Time = os.clock(),
            }
        end
        local touchSuccess, touchError = pcall(function()
            VirtualInputManager:SendTouchEvent(lane, pressed and 0 or 2,
                inputPosition.X, inputPosition.Y)
        end)
        rhythmDebug("TOUCH", "lane=", lane, "pressed=", pressed,
            "id=", lane, "state=", pressed and 0 or 2,
            "visual=", position.X .. "," .. position.Y,
            "correction=", correction.X .. "," .. correction.Y,
            "sent=", inputPosition.X .. "," .. inputPosition.Y,
            "success=", touchSuccess, "error=", touchError or "none")

        local keySuccess = false
        if not touchSuccess then
            keySuccess = pcall(function()
                VirtualInputManager:SendKeyEvent(pressed, key, false, game)
            end)
            rhythmDebug("KEY FALLBACK", "lane=", lane, "key=", key.Name,
                "pressed=", pressed, "success=", keySuccess)
        end

        if not touchSuccess and not keySuccess then
            local mouseSuccess, mouseError = pcall(function()
                VirtualInputManager:SendMouseButtonEvent(position.X, position.Y,
                    0, pressed, game, 0)
            end)
            rhythmDebug("MOUSE FALLBACK", "lane=", lane, "pressed=", pressed,
                "success=", mouseSuccess, "error=", mouseError or "none")
            return mouseSuccess
        end
        return true
    end
    return pcall(function()
        VirtualInputManager:SendKeyEvent(pressed, key, false, game)
    end)
end

local function rhythmHoldUntilTail(note, receptor, lane, key, fallbackDuration, generation)
    local name = key.Name
    local token = (Rhythm.Tokens[name] or 0) + 1
    Rhythm.Tokens[name] = token
    rhythmSendInput(lane, key, true)

    task.spawn(function()
        local started = os.clock()
        local fallbackAt = started + math.clamp(fallbackDuration or 0.5, 0.25, 5)
        local released = false
        while Rhythm.Enabled and generation == Rhythm.Generation
            and Rhythm.Tokens[name] == token and note.Parent and note.Visible
            and os.clock() < started + 5.5 do
            local tail = note:FindFirstChild("Tail")
            local receptorY = receptor.AbsolutePosition.Y + receptor.AbsoluteSize.Y / 2
            local endpoint = tail and tail:IsA("GuiObject") and tail.Visible
                and (tail.AbsolutePosition.Y + tail.AbsoluteSize.Y) or nil

            if endpoint and endpoint <= receptorY + 2 then
                fallbackAt = math.max(fallbackAt, os.clock() + 0.08)
            elseif endpoint and os.clock() >= fallbackAt then
                released = true
                break
            elseif not endpoint and os.clock() >= fallbackAt then
                released = true
                break
            end
            task.wait(0.033) -- ~30fps polling, no need for 60fps on hold notes
        end

        if Rhythm.Tokens[name] == token then
            Rhythm.Tokens[name] = nil
            rhythmSendInput(lane, key, false)
        end
    end)
end

local function rhythmGetHoldDuration(note, receptor, velocity)
    if not velocity or velocity <= 1 then return nil end
    local tail = note:FindFirstChild("Tail")
    if not tail or not tail:IsA("GuiObject") or not tail.Visible then return nil end

    local duration = tail.AbsoluteSize.Y / velocity
    local extend = (Rhythm.HoldExtendMs or 80) / 1000

    return math.clamp(duration + extend, 0.25, 5.0)
end

local function rhythmTap(lane, key)
    rhythmSendInput(lane, key, true)
    local tapDuration = Rhythm.TouchMode and Rhythm.LaneCount >= 4 and 0.08 or 0.03
    task.delay(tapDuration, function()
        rhythmSendInput(lane, key, false)
    end)
end

local function rhythmConfigure(root)
    local receptors = root:FindFirstChild("Receptors", true)
    if not receptors then return false end
    local found, foundKeys = {}, {}
    local candidates = { receptors }
    for _, object in ipairs(receptors:GetDescendants()) do
        table.insert(candidates, object)
    end
    for _, receptor in ipairs(candidates) do
        local index = receptor:IsA("GuiObject")
            and tonumber(receptor.Name:match("^Receptor(%d+)$")) or nil
        local hint = receptor:FindFirstChild("KeyHint", true)
        local name = hint and hint:IsA("TextLabel") and hint.Text:upper()
        if index then
            found[index] = receptor
            if name and name ~= "" then
                local valid, keyCode = pcall(function()
                    return Enum.KeyCode[name]
                end)
                if valid and keyCode then foundKeys[index] = name end
            end
        end
    end
    local count = 0
    for i = 1, 4 do
        if found[i] then count = i else break end
    end
    if count == 0 then return false end
    Rhythm.LaneCount, Rhythm.Keys, Rhythm.Names = count, {}, {}
    local fallbackKeys = count == 2 and { "F", "J" }
        or { "X", "C", "N", "M" }
    Rhythm.Receptors = {}
    for i = 1, count do
        local keyName = foundKeys[i] or fallbackKeys[i]
        Rhythm.Names[i] = keyName
        Rhythm.Keys[i] = Enum.KeyCode[keyName]
        Rhythm.Receptors[i] = found[i]
        local receptor = Rhythm.Receptors[i]
        rhythmDebug("RECEPTOR", "lane=", i, "object=", receptor,
            "class=", receptor and receptor.ClassName or "nil",
            "visible=", receptor and receptor.Visible or "nil",
            "pos=", receptor and receptor.AbsolutePosition or "nil",
            "size=", receptor and receptor.AbsoluteSize or "nil")
    end
    table.clear(Rhythm.TouchPositions)
    rhythmDebug("CONFIG", "lanes=", count, "keys=", table.concat(Rhythm.Names, ","))
    return true
end

local function rhythmLane(note)
    local x = note.AbsolutePosition.X + note.AbsoluteSize.X / 2
    local lane, best = nil, math.huge
    for i, receptor in ipairs(Rhythm.Receptors) do
        if receptor and receptor.Parent then
            local center = receptor.AbsolutePosition.X + receptor.AbsoluteSize.X / 2
            if math.abs(x - center) < best then lane, best = i, math.abs(x - center) end
        end
    end
    return lane
end

local function rhythmRegister(note)
    if not Rhythm.Enabled or not rhythmIsNote(note) or not note.Visible then return end
    local attrLane = note:GetAttribute("NoteLane")
    local lane = (type(attrLane) == "number" and attrLane >= 1 and attrLane <= Rhythm.LaneCount)
        and attrLane or rhythmLane(note)
    if not lane or Rhythm.Active[note] then return end
    Rhythm.Active[note] = {
        lane = lane,
        key = Rhythm.Keys[lane],
        pressed = false,
        tail = nil,
        isHold = false,
        parent = note.Parent,
        lastY = nil,
        lastAt = nil,
        wasInactive = false,
        holdDuration = nil,
        noteTime = note:GetAttribute("NoteTime"),
        noteLane = lane,
        lastNoteTime = note:GetAttribute("NoteTime"),
    }
    rhythmDebug("NOTE", "registered", note, "lane=", lane,
        "noteTime=", Rhythm.Active[note].noteTime,
        "pos=", note.AbsolutePosition, "size=", note.AbsoluteSize)
end

local function rhythmResetRecycled(note, data)
    local attrLane = note:GetAttribute("NoteLane")
    local lane = (type(attrLane) == "number" and attrLane >= 1 and attrLane <= Rhythm.LaneCount)
        and attrLane or rhythmLane(note)
    if not lane then return end
    data.lane = lane
    data.key = Rhythm.Keys[lane]
    data.pressed = false
    data.parent = note.Parent
    data.wasInactive = false
    data.lastY = nil
    data.lastAt = nil
    data.holdDuration = nil
    data.noteTime = note:GetAttribute("NoteTime")
    data.noteLane = lane
    data.lastNoteTime = data.noteTime
end

local function rhythmInspectorId(object)
    local id = Rhythm.InspectorIds[object]
    if not id then
        Rhythm.NextInspectorId += 1
        id = Rhythm.NextInspectorId
        Rhythm.InspectorIds[object] = id
    end
    return object.Name .. "#" .. id
end

-- ── Rating Spy: detect Perfect/Good/Ok/Miss from game UI ─────────────
local function rhythmConnectRatingSpy(root)
    if Rhythm.RatingConn then
        Rhythm.RatingConn:Disconnect()
        Rhythm.RatingConn = nil
    end
    if Rhythm.RatingRemoveConn then
        Rhythm.RatingRemoveConn:Disconnect()
        Rhythm.RatingRemoveConn = nil
    end
    if not Rhythm.RatingSpy or not root or not root.Parent then return end
    local seenRatings = setmetatable({}, { __mode = "k" })
    local ratingKeywords = { "perfect", "great", "good", "ok", "miss", "bad" }
    local function checkRating(obj)
        if not Rhythm.RatingSpy then return end
        if not obj:IsA("TextLabel") and not obj:IsA("TextButton") then return end
        local text = obj.Text
        if not text or text == "" then return end
        local lower = text:lower()
        for _, keyword in ipairs(ratingKeywords) do
            if lower:find(keyword, 1, true) then
                if seenRatings[obj] ~= keyword then
                    seenRatings[obj] = keyword
                    local now = os.clock()
                    local label = keyword:sub(1, 1):upper() .. keyword:sub(2)
                    Rhythm.RatingCounts[label] = (Rhythm.RatingCounts[label] or 0) + 1
                    Rhythm.RatingTotal += 1
                    -- Delta: time since last key press (manual or auto)
                    local delta = nil
                    local latestPress = 0
                    local pressLane = 0
                    for lane, t in pairs(Rhythm.LastPressAt) do
                        if t > latestPress then
                            latestPress = t; pressLane = lane
                        end
                    end
                    if latestPress > 0 then delta = now - latestPress end
                    -- Position of the judgement label (correlate to lane)
                    local pos = nil
                    pcall(function()
                        if obj:IsA("GuiObject") then
                            pos = obj.AbsolutePosition
                        end
                    end)
                    rhythmDebug("RATING", label,
                        "text=", text,
                        "pos=", pos and string.format("%.0f,%.0f", pos.X, pos.Y) or "n/a",
                        "pressLane=", pressLane > 0 and pressLane or "n/a",
                        "delta=", delta and string.format("%.4f", delta) or "n/a",
                        "id=", rhythmInspectorId(obj),
                        "total=", Rhythm.RatingTotal)
                end
                return
            end
        end
        seenRatings[obj] = nil
    end
    local function watchRating(obj)
        checkRating(obj)
        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            obj:GetPropertyChangedSignal("Text"):Connect(function()
                checkRating(obj)
            end)
        end
    end
    Rhythm.RatingConn = root.DescendantAdded:Connect(watchRating)
    Rhythm.RatingRemoveConn = root.DescendantRemoving:Connect(function(obj)
        seenRatings[obj] = nil
    end)
    for _, obj in ipairs(root:GetDescendants()) do
        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            watchRating(obj)
        end
    end
    rhythmDebug("RATING SPY", "started", "monitoring root=", root.Name)
end

local function rhythmScan()
    local ui, root = nil, nil
    for _, object in ipairs(PlayerGui:GetDescendants()) do
        if object.Name == "RhythmRoot" then
            local candidateReceptors = object:FindFirstChild("Receptors", true)
            if candidateReceptors then
                root = object
                local ancestor = object.Parent
                while ancestor and ancestor ~= PlayerGui do
                    if ancestor.Name == "RhythmServiceUI" then
                        ui = ancestor
                        break
                    end
                    ancestor = ancestor.Parent
                end
                break
            elseif not root then
                root = object
            end
        end
    end
    if not root then
        Rhythm.Root = nil
        local now = os.clock()
        if now - Rhythm.LastMissingRootDebug >= 1 then
            Rhythm.LastMissingRootDebug = now
            rhythmDebug("SCAN", "no RhythmRoot", "playerGuiDescendants=",
                #PlayerGui:GetDescendants())
        end
        return
    end
    local receptorsReady = Rhythm.LaneCount > 0
    for lane = 1, Rhythm.LaneCount do
        local receptor = Rhythm.Receptors[lane]
        if not receptor or not receptor:IsDescendantOf(root) then
            receptorsReady = false
            break
        end
    end
    if Rhythm.Root ~= root or not receptorsReady then
        Rhythm.Root = root
        if not rhythmConfigure(root) then return end
        rhythmConnectRatingSpy(root)
    end
    for _, object in ipairs(root:GetDescendants()) do rhythmRegister(object) end
end

local function rhythmDebugStructure()
    local root = Rhythm.Root
    local ui = root
    while ui and ui ~= PlayerGui and ui.Name ~= "RhythmServiceUI" do
        ui = ui.Parent
    end
    if ui == PlayerGui then ui = nil end
    rhythmDebug("UI", "service=", ui, "root=", root)
    if not root then return end

    rhythmConfigure(root)
    local descendants = root:GetDescendants()
    rhythmDebug("STRUCTURE", "descendants=", #descendants)
    for index, object in ipairs(descendants) do
        if index > 120 then
            rhythmDebug("STRUCTURE", "truncated after 120 descendants")
            break
        end
        if object:IsA("GuiObject") then
            rhythmDebug("GUI", index, object.Name, "class=", object.ClassName,
                "parent=", object.Parent and object.Parent.Name or "nil",
                "visible=", object.Visible, "pos=", object.AbsolutePosition,
                "size=", object.AbsoluteSize)
        else
            rhythmDebug("OBJECT", index, object.Name, "class=", object.ClassName,
                "parent=", object.Parent and object.Parent.Name or "nil")
        end
    end
end

local function rhythmDisconnectGuiInspector()
    for _, connection in ipairs(Rhythm.InspectorConnections) do connection:Disconnect() end
    table.clear(Rhythm.InspectorConnections)
    Rhythm.InspectorRoot = nil
end

local function rhythmInspectorPath(object)
    local parts = {}
    while object and object ~= PlayerGui do
        table.insert(parts, 1, object.Name)
        object = object.Parent
    end
    return "PlayerGui/" .. table.concat(parts, "/")
end

local function rhythmInspectObject(object, event)
    if not Rhythm.GuiInspector or not object then return end
    local details = { event, "id=", rhythmInspectorId(object), "path=", rhythmInspectorPath(object), "class=", object
        .ClassName,
        "parent=", object.Parent and object.Parent.Name or "nil" }
    if object:IsA("GuiObject") then
        table.insert(details, "visible="); table.insert(details, object.Visible)
        table.insert(details, "pos="); table.insert(details, object.AbsolutePosition)
        table.insert(details, "size="); table.insert(details, object.AbsoluteSize)
        table.insert(details, "z="); table.insert(details, object.ZIndex)
        table.insert(details, "layoutPos="); table.insert(details, object.Position)
        table.insert(details, "layoutSize="); table.insert(details, object.Size)
    end
    if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
        table.insert(details, "text="); table.insert(details, string.format("%q", object.Text))
        table.insert(details, "textTransparency="); table.insert(details, object.TextTransparency)
    elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
        table.insert(details, "image="); table.insert(details, object.Image)
        table.insert(details, "imageTransparency="); table.insert(details, object.ImageTransparency)
    end
    for name, value in pairs(object:GetAttributes()) do
        table.insert(details, "attr." .. name .. "="); table.insert(details, value)
    end
    rhythmDebug("GUI INSPECT", table.unpack(details))
end

local function rhythmWatchInspectedObject(object)
    local lowerName = object.Name:lower()
    local focused = lowerName:find("hitshard", 1, true)
        or lowerName:find("judgement", 1, true)
        or lowerName:find("note", 1, true)
    if not focused then return end
    rhythmInspectObject(object, "WATCH")
    local properties = { "Name", "Parent" }
    if object:IsA("GuiObject") then
        -- Position and Size animate continuously while notes travel. Logging those
        -- signals floods the report and hides lifecycle and judgement changes.
        table.insert(properties, "Visible")
    end
    if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
        -- TextTransparency is commonly tweened every frame on judgements. Its
        -- initial/final values are already captured by WATCH and REMOVING.
        table.insert(properties, "Text")
    elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
        table.insert(properties, "Image"); table.insert(properties, "ImageTransparency")
    end
    for _, property in ipairs(properties) do
        table.insert(Rhythm.InspectorConnections,
            object:GetPropertyChangedSignal(property):Connect(function()
                rhythmInspectObject(object, "CHANGED " .. property)
            end))
    end
    table.insert(Rhythm.InspectorConnections, object.AttributeChanged:Connect(function(attribute)
        rhythmInspectObject(object, "ATTRIBUTE " .. attribute)
    end))
end

local function rhythmInspectClockMetadata(ui, root)
    local clockKeywords = { "song", "music", "time", "clock", "playback", "start", "bpm", "beat", "speed", "offset" }
    local logged = 0
    table.clear(Rhythm.ClockEvidence)
    local function logClock(...)
        local values = { ... }
        for index, value in ipairs(values) do values[index] = tostring(value) end
        local line = table.concat(values, " ")
        table.insert(Rhythm.ClockEvidence, line)
        rhythmDebug("CLOCK", line)
    end
    local function relevant(name)
        name = name:lower()
        for _, keyword in ipairs(clockKeywords) do
            if name:find(keyword, 1, true) then return true end
        end
        return false
    end
    local searchRoot = ui or root
    if not searchRoot then return end
    local objects = { searchRoot }
    for _, object in ipairs(searchRoot:GetDescendants()) do table.insert(objects, object) end
    for _, object in ipairs(objects) do
        if logged >= 80 then
            logClock("truncated after 80 candidates")
            break
        end
        local isSound = object:IsA("Sound")
        local isNamedValue = object:IsA("ValueBase") and relevant(object.Name)
        if isSound or isNamedValue then
            logged += 1
            if isSound then
                logClock("id=", rhythmInspectorId(object), "path=", rhythmInspectorPath(object),
                    "class=Sound", "playing=", object.Playing, "timePosition=", object.TimePosition,
                    "timeLength=", object.TimeLength, "playbackSpeed=", object.PlaybackSpeed,
                    "soundId=", object.SoundId)
            else
                logClock("id=", rhythmInspectorId(object), "path=", rhythmInspectorPath(object),
                    "class=", object.ClassName, "value=", object.Value)
            end
        end
        for attribute, value in pairs(object:GetAttributes()) do
            if relevant(attribute) then
                logged += 1
                logClock("id=", rhythmInspectorId(object), "path=", rhythmInspectorPath(object),
                    "attribute=", attribute, "value=", value)
                if logged >= 80 then break end
            end
        end
    end
    logClock("candidates=", logged)
end

local function rhythmConnectGuiInspector()
    rhythmDisconnectGuiInspector()
    if not Rhythm.GuiInspector then return end
    local ui = PlayerGui:FindFirstChild("RhythmServiceUI")
    local root = ui and ui:FindFirstChild("RhythmRoot") or Rhythm.Root
    rhythmDebug("GUI INSPECT", "SNAPSHOT", "service=", ui or "missing", "root=", root or "missing")
    if ui then rhythmInspectObject(ui, "TARGET") end
    if not root then return end
    Rhythm.InspectorRoot = root
    rhythmInspectObject(root, "TARGET")
    rhythmInspectClockMetadata(ui, root)
    local judgement = root:FindFirstChild("JudgementTemplate", true)
    rhythmDebug("GUI INSPECT", "judgement=", judgement or "missing")
    if judgement then rhythmInspectObject(judgement, "TARGET") end
    for _, object in ipairs(root:GetDescendants()) do rhythmWatchInspectedObject(object) end
    table.insert(Rhythm.InspectorConnections, root.DescendantAdded:Connect(function(object)
        rhythmInspectObject(object, "ADDED")
        rhythmWatchInspectedObject(object)
    end))
    table.insert(Rhythm.InspectorConnections, root.DescendantRemoving:Connect(function(object)
        local name = object.Name:lower()
        if name:find("hitshard", 1, true) or name:find("judgement", 1, true)
            or name:find("note", 1, true) then
            rhythmInspectObject(object, "REMOVING")
        end
    end))
    rhythmDebug("GUI INSPECT", "watching", rhythmInspectorPath(root),
        "descendants=", #root:GetDescendants())
end

local function rhythmDebugAndroidHierarchy()
    local descendants = PlayerGui:GetDescendants()
    rhythmDebug("ANDROID", "playerGuiDescendants=", #descendants,
        "viewport=", workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or "nil")

    for index, child in ipairs(PlayerGui:GetChildren()) do
        rhythmDebug("ANDROID ROOT", index, child.Name, "class=", child.ClassName,
            "enabled=", child:IsA("ScreenGui") and child.Enabled or "n/a")
    end

    local matched = 0
    for _, object in ipairs(descendants) do
        local lowerName = object.Name:lower()
        local relevantName = lowerName:find("rhythm", 1, true)
            or lowerName:find("note", 1, true)
            or lowerName:find("receptor", 1, true)
            or lowerName:find("lane", 1, true)
            or lowerName:find("keyhint", 1, true)
        if relevantName then
            matched += 1
            if matched <= 300 then
                local path = {}
                local ancestor = object
                while ancestor and ancestor ~= PlayerGui do
                    table.insert(path, 1, ancestor.Name)
                    ancestor = ancestor.Parent
                end
                if object:IsA("GuiObject") then
                    rhythmDebug("ANDROID MATCH", matched, table.concat(path, "/"),
                        "class=", object.ClassName, "visible=", object.Visible,
                        "pos=", object.AbsolutePosition, "size=", object.AbsoluteSize,
                        "z=", object.ZIndex)
                else
                    rhythmDebug("ANDROID MATCH", matched, table.concat(path, "/"),
                        "class=", object.ClassName)
                end
            end
        end
    end
    rhythmDebug("ANDROID", "nameMatches=", matched,
        matched > 300 and "truncated=300" or "complete")
end

-- ── Timing mode: returns delay before press (0 = immediate) ───────────
local function rhythmGetCustomDelay()
    if Rhythm.Mode == "perfect" then
        return 0
    end
    local roll = math.random(1, 100)
    if roll <= Rhythm.PerfectChance then
        return 0
    elseif roll <= Rhythm.PerfectChance + Rhythm.GoodChance then
        return math.random() * 0.025 + 0.005
    elseif roll <= Rhythm.PerfectChance + Rhythm.GoodChance + Rhythm.OkChance then
        return math.random() * 0.040 + 0.025
    else
        return math.random() * 0.060 + 0.050
    end
end

local function rhythmCalibrateScrollSpeed(note, data, now, noteY)
    if data.lastY and data.lastAt then
        local dt = now - data.lastAt
        local dy = noteY - data.lastY
        if dt > 0.001 and math.abs(dy) >= 2 and math.abs(dy) < 120 then
            local speed = dy / dt
            if speed > 50 and speed < 2000 then
                table.insert(Rhythm.ScrollSpeedSamples, speed)
                if #Rhythm.ScrollSpeedSamples > 60 then
                    table.remove(Rhythm.ScrollSpeedSamples, 1)
                end
                Rhythm.ScrollSpeedDirty = (Rhythm.ScrollSpeedDirty or 0) + 1
                if #Rhythm.ScrollSpeedSamples >= 5 and Rhythm.ScrollSpeedDirty >= 5 then
                    Rhythm.ScrollSpeedDirty = 0
                    local sorted = {}
                    for _, s in ipairs(Rhythm.ScrollSpeedSamples) do
                        table.insert(sorted, s)
                    end
                    table.sort(sorted)
                    local median = sorted[math.ceil(#sorted / 2)]
                    if not Rhythm.ScrollSpeed then
                        Rhythm.ScrollSpeed = median
                    else
                        local clampedMedian = math.clamp(median,
                            Rhythm.ScrollSpeed * 0.92, Rhythm.ScrollSpeed * 1.08)
                        Rhythm.ScrollSpeed = Rhythm.ScrollSpeed * 0.7 + clampedMedian * 0.3
                    end
                end
            end
            return speed
        end
    end
    return nil
end

local function rhythmDeriveSongTime(noteTime, noteY, receptorY)
    if not Rhythm.ScrollSpeed or Rhythm.ScrollSpeed <= 0 then return nil end
    local distanceToReceptor = receptorY - noteY
    local timeToHit = distanceToReceptor / Rhythm.ScrollSpeed
    return noteTime - timeToHit, timeToHit
end

local function rhythmStep()
    if not Rhythm.Enabled then return end
    local now = os.clock()
    if not Rhythm.Root or now - Rhythm.LastScan >= Rhythm.ScanInterval then
        Rhythm.LastScan = now
        rhythmScan()
    end
    if Rhythm.DebugEnabled and Rhythm.Root
        and Rhythm.DebugRootReported ~= Rhythm.Root then
        Rhythm.DebugRootReported = Rhythm.Root
        rhythmDebugStructure()
    end

    local songTimeVotes = {}

    for note, data in pairs(Rhythm.Active) do
        if not note.Parent then
            Rhythm.Active[note] = nil
        elseif note.Parent.Name == "OffscreenPool" or not note.Visible then
            data.wasInactive = true
            data.lastY = nil; data.lastAt = nil
            if data.pressed then data.pressed = false end
        else
            local noteTime = note:GetAttribute("NoteTime")
            if data.wasInactive or data.parent ~= note.Parent
                or (noteTime and data.lastNoteTime and noteTime ~= data.lastNoteTime) then
                rhythmResetRecycled(note, data)
            end
            data.lastNoteTime = noteTime
            data.noteTime = noteTime

            if not data.pressed and Rhythm.Receptors[data.lane] then
                data.tail = note:FindFirstChild("Tail")
                data.isHold = data.tail and data.tail:IsA("GuiObject")
                    and data.tail.Visible and data.tail.AbsoluteSize.Y > 1 or false

                local receptor = Rhythm.Receptors[data.lane]
                local noteY = note.AbsolutePosition.Y + note.AbsoluteSize.Y / 2
                local receptorY = receptor.AbsolutePosition.Y + receptor.AbsoluteSize.Y / 2
                local frameVelocity = rhythmCalibrateScrollSpeed(note, data, now, noteY)
                data.lastY, data.lastAt = noteY, now

                local effectiveSpeed = Rhythm.ScrollSpeed
                if data.isHold and effectiveSpeed and effectiveSpeed > 1 then
                    data.holdDuration = rhythmGetHoldDuration(note, receptor, effectiveSpeed)
                end

                if noteTime and Rhythm.ScrollSpeed and #Rhythm.ScrollSpeedSamples >= 15 then
                    local songTime, timeToHit = rhythmDeriveSongTime(noteTime, noteY, receptorY)
                    if songTime then
                        table.insert(songTimeVotes, songTime)
                    end

                    if timeToHit and timeToHit <= 0.005 and timeToHit >= -0.080
                        and now - (Rhythm.LastPress[data.lane] or 0) >= Rhythm.MinInterval then
                        data.pressed = true
                        Rhythm.LastPress[data.lane] = now
                        Rhythm.LastPressAt[data.lane] = now
                        local scheduledHold = data.isHold and data.holdDuration or nil
                        local generation = Rhythm.Generation
                        local customDelay = rhythmGetCustomDelay()
                        rhythmDebug("HIT", "lane=", data.lane, "noteTime=", string.format("%.4f", noteTime),
                            "timeToHit=", string.format("%.4f", timeToHit),
                            "scrollSpeed=", string.format("%.1f", Rhythm.ScrollSpeed),
                            "hold=", scheduledHold ~= nil, "customDelay=", string.format("%.4f", customDelay))
                        if customDelay <= 0 then
                            if scheduledHold then
                                rhythmHoldUntilTail(note, receptor, data.lane, data.key,
                                    scheduledHold, generation)
                            else
                                rhythmTap(data.lane, data.key)
                            end
                        else
                            task.delay(customDelay, function()
                                if not Rhythm.Enabled or generation ~= Rhythm.Generation then return end
                                if scheduledHold then
                                    rhythmHoldUntilTail(note, receptor, data.lane, data.key,
                                        scheduledHold, generation)
                                else
                                    rhythmTap(data.lane, data.key)
                                end
                            end)
                        end
                    end
                elseif frameVelocity and frameVelocity > 1 then
                    local eta = (receptorY - noteY) / frameVelocity
                    if eta <= 0.005 and eta >= -0.080
                        and now - (Rhythm.LastPress[data.lane] or 0) >= Rhythm.MinInterval then
                        data.pressed = true
                        Rhythm.LastPress[data.lane] = now
                        Rhythm.LastPressAt[data.lane] = now
                        local scheduledHold = data.isHold and data.holdDuration or nil
                        local generation = Rhythm.Generation
                        local customDelay = rhythmGetCustomDelay()
                        rhythmDebug("HIT", "lane=", data.lane, "eta=", string.format("%.4f", eta),
                            "velocity=", string.format("%.2f", frameVelocity), "hold=", scheduledHold ~= nil,
                            "noteY=", string.format("%.1f", noteY), "targetY=", string.format("%.1f", receptorY),
                            "customDelay=", string.format("%.4f", customDelay))
                        if customDelay <= 0 then
                            if scheduledHold then
                                rhythmHoldUntilTail(note, receptor, data.lane, data.key,
                                    scheduledHold, generation)
                            else
                                rhythmTap(data.lane, data.key)
                            end
                        else
                            task.delay(customDelay, function()
                                if not Rhythm.Enabled or generation ~= Rhythm.Generation then return end
                                if scheduledHold then
                                    rhythmHoldUntilTail(note, receptor, data.lane, data.key,
                                        scheduledHold, generation)
                                else
                                    rhythmTap(data.lane, data.key)
                                end
                            end)
                        end
                    end
                end
            else
                local noteY = note.AbsolutePosition.Y + note.AbsoluteSize.Y / 2
                rhythmCalibrateScrollSpeed(note, data, now, noteY)
                data.lastY, data.lastAt = noteY, now
            end
        end
    end

    if #songTimeVotes > 0 then
        local sum = 0
        for _, v in ipairs(songTimeVotes) do sum += v end
        Rhythm.SongTime = sum / #songTimeVotes
        Rhythm.LastSongTimeAt = now
    end
end

local function setRhythmEnabled(value)
    Rhythm.Enabled = value
    Rhythm.Generation += 1
    if not value then
        rhythmReleaseAll()
        table.clear(Rhythm.Active)
        table.clear(Rhythm.ScrollSpeedSamples)
        Rhythm.ScrollSpeed = nil
        Rhythm.SongTime = nil
        Rhythm.SongTimeSamples = {}
        if Rhythm.RatingConn then
            Rhythm.RatingConn:Disconnect(); Rhythm.RatingConn = nil
        end
        if Rhythm.RenderConn then
            Rhythm.RenderConn:Disconnect()
            Rhythm.RenderConn = nil
        end
    else
        Rhythm.LastScan = 0
        rhythmScan()
        if not Rhythm.RenderConn then
            Rhythm.RenderConn = RunService.RenderStepped:Connect(rhythmStep)
        end
    end
    rhythmDebug("STATE", value and "enabled" or "disabled",
        "TouchEnabled=", UserInputService.TouchEnabled,
        "KeyboardEnabled=", UserInputService.KeyboardEnabled,
        "TouchMode=", Rhythm.TouchMode)
end
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.F6 then
        setRhythmEnabled(not Rhythm.Enabled)
    end
end)
PlayerGui.ChildAdded:Connect(function(child)
    if child.Name == "RhythmServiceUI" then
        task.delay(0.3, function()
            rhythmScan()
            if Rhythm.GuiInspector then rhythmConnectGuiInspector() end
        end)
    end
end)
PlayerGui.DescendantAdded:Connect(function(descendant)
    if descendant.Name == "RhythmRoot" and Rhythm.GuiInspector then
        task.defer(function()
            if descendant.Parent and Rhythm.InspectorRoot ~= descendant then
                rhythmScan()
                rhythmConnectGuiInspector()
            end
        end)
    end
end)
PlayerGui.ChildRemoved:Connect(function(child)
    if child.Name == "RhythmServiceUI" then
        Rhythm.Generation += 1
        Rhythm.Root = nil; table.clear(Rhythm.Active); rhythmReleaseAll()
        if Rhythm.GuiInspector then
            rhythmDisconnectGuiInspector()
            rhythmDebug("GUI INSPECT", "detached; RhythmServiceUI removed")
        end
        if Rhythm.RatingConn then
            Rhythm.RatingConn:Disconnect(); Rhythm.RatingConn = nil
        end
    end
end)

local AutoRespawn = { Enabled = false, Conn = nil, Triggered = false, WaitingRevive = false }

local function arDebug(...)
    if not Dbg.ArDebug then return end
    local parts = {}
    for _, v in ipairs({ ... }) do
        table.insert(parts, tostring(v))
    end
    local msg = table.concat(parts, " ")
    print("[AutoRespawn]", msg)
    table.insert(Dbg.ArTimeline, os.date("!%H:%M:%S") .. " " .. msg)
    if #Dbg.ArTimeline > 200 then
        table.remove(Dbg.ArTimeline, 1)
    end
end

local function triggerAutoRespawn()
    if AutoRespawn.Triggered then
        arDebug("already triggered, skipping")
        return
    end
    AutoRespawn.Triggered = true
    arDebug("trigger called")
    local char = LocalPlayer.Character
    if not char then
        arDebug("no character, aborting")
        AutoRespawn.Triggered = false
        return
    end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        arDebug("no HRP, aborting")
        AutoRespawn.Triggered = false
        return
    end
    arDebug("teleporting out of bounds")
    pcall(function()
        hrp.Anchored = true
        hrp.CFrame = CFrame.new(0, 99999, 0)
    end)
    arDebug("teleport done")
end

local function attachAutoRespawn(character)
    if not character or not AutoRespawn.Enabled then return end
    arDebug("attaching to character", character.Name)
    if AutoRespawn.Conn then AutoRespawn.Conn:Disconnect() end
    AutoRespawn.Conn = character.AttributeChanged:Connect(function(attr)
        local val = character:GetAttribute(attr)
        arDebug("AttributeChanged:", attr, "=", tostring(val))
        if attr == "Downed" and val == true then
            arDebug("knocked, waiting for revive...")
            AutoRespawn.WaitingRevive = true
        end
        if attr == "Downed" and val == false and AutoRespawn.WaitingRevive then
            arDebug("revived! triggering respawn...")
            AutoRespawn.WaitingRevive = false
            task.wait(0.1)
            task.defer(triggerAutoRespawn)
        end
    end)
end

local function detachAutoRespawn()
    if AutoRespawn.Conn then
        AutoRespawn.Conn:Disconnect()
        AutoRespawn.Conn = nil
    end
end

local Fly = { Enabled = false, Speed = 50, BV = nil, BG = nil, Conn = nil, Humanoid = nil, Root = nil }

local function startFly()
    local char = LocalPlayer.Character
    if not char then return end
    local rootPart = char:FindFirstChild("HumanoidRootPart")
    local humanoid = char:FindFirstChild("Humanoid")
    if not rootPart or not humanoid then return end
    Fly.Enabled = true
    Fly.Humanoid = humanoid
    Fly.Root = rootPart
    Fly.BV = Instance.new("BodyVelocity")
    Fly.BV.MaxForce = Vector3.new(400000, 400000, 400000)
    Fly.BV.Velocity = Vector3.zero
    Fly.BV.Parent = rootPart
    Fly.BG = Instance.new("BodyGyro")
    Fly.BG.MaxTorque = Vector3.new(400000, 400000, 400000)
    Fly.BG.CFrame = rootPart.CFrame
    Fly.BG.Parent = rootPart
    humanoid.PlatformStand = true
    if not Fly.Conn then
        Fly.Conn = RunService.Heartbeat:Connect(function()
            if not Fly.Enabled or not Fly.BV or not Fly.BG then return end
            if not Fly.Humanoid or not Fly.Humanoid.Parent then return end
            local camera = workspace.CurrentCamera
            local direction = Vector3.zero
            local moveDir = Fly.Humanoid.MoveDirection
            if moveDir.Magnitude > 0 then
                local forward = camera.CFrame.LookVector
                local right = camera.CFrame.RightVector
                local flatDir = (moveDir:Dot(forward) * forward + moveDir:Dot(right) * right)
                if flatDir.Magnitude > 0 then direction = flatDir.Unit end
            end
            if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
                direction += Vector3.new(0, 1, 0)
            end
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
                direction -= Vector3.new(0, 1, 0)
            end
            Fly.BV.Velocity = direction.Magnitude > 0 and direction.Unit * Fly.Speed or Vector3.zero
            Fly.BG.CFrame = camera.CFrame
        end)
    end
end

local function stopFly()
    Fly.Enabled = false
    if Fly.Conn then
        Fly.Conn:Disconnect(); Fly.Conn = nil
    end
    if Fly.BV then
        Fly.BV:Destroy(); Fly.BV = nil
    end
    if Fly.BG then
        Fly.BG:Destroy(); Fly.BG = nil
    end
    if Fly.Humanoid and Fly.Humanoid.Parent then
        Fly.Humanoid.PlatformStand = false
    end
    Fly.Humanoid = nil
    Fly.Root = nil
end

local Noclip = { Enabled = false, Conn = nil, Parts = {} }

local function noclipCacheParts(character)
    table.clear(Noclip.Parts)
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            table.insert(Noclip.Parts, part)
        end
    end
end

local function enableNoclip()
    if Noclip.Conn then return end
    noclipCacheParts(LocalPlayer.Character)
    Noclip.Conn = RunService.Stepped:Connect(function()
        for _, part in ipairs(Noclip.Parts) do
            if part.Parent then part.CanCollide = false end
        end
    end)
end

local function disableNoclip()
    if Noclip.Conn then
        Noclip.Conn:Disconnect(); Noclip.Conn = nil
    end
    for _, part in ipairs(Noclip.Parts) do
        pcall(function() part.CanCollide = true end)
    end
    table.clear(Noclip.Parts)
end

LocalPlayer.CharacterAdded:Connect(function(character)
    local wasFlying = Fly.Enabled
    local wasNoclipping = Noclip.Enabled
    if Fly.Enabled then stopFly() end
    if Noclip.Enabled then disableNoclip() end
    if wasFlying then
        task.wait(0.5)
        startFly()
    end
    if wasNoclipping then
        task.wait(0.3)
        enableNoclip()
    end
    if AutoRespawn.Enabled then
        AutoRespawn.Triggered = false
        AutoRespawn.WaitingRevive = false
        task.wait(0.5)
        attachAutoRespawn(character)
    end
end)

local PlayerTab = Window:Tab({ Title = "Player", Icon = "move" })

PlayerTab:Toggle({
    Title = "Infinite Stamina",
    Description = "Bypass stamina drain via namecall hook + sprint remote intercept",
    Default = false,
    Callback = function(value)
        setInfiniteStamina(value)
    end
})

PlayerTab:Toggle({
    Title = "No Dodge Cooldown",
    Description = "Remove local cooldown so you can spam Q without waiting",
    Default = false,
    Callback = function(value)
        setNoDodgeCooldown(value)
    end
})

PlayerTab:Toggle({
    Title = "No Stun Animation",
    Description = "Hide stun, guard-break, and recovery animations; server attack lock still applies",
    Default = false,
    Callback = function(value)
        setAntiStun(value)
    end
})

PlayerTab:Toggle({
    Title = "Anti-Ragdoll",
    Description = "Prevent ragdoll, knockdown, and get-up animations",
    Default = false,
    Callback = function(value)
        setAntiRagdoll(value)
    end
})

PlayerTab:Slider({
    Title = "Dodge Cooldown",
    Description = "Custom delay between dodges (0 = instant, no cooldown)",
    Flag = "DodgeCooldownSlider",
    Value = { Min = 0, Max = 3, Default = 0 },
    Step = 0.05,
    Callback = function(value)
        CS.DodgeCooldownTime = value
        CS.LastDodgeTime = 0 -- reset throttle so new value applies immediately
    end
})

PlayerTab:Divider()

PlayerTab:Toggle({
    Title = "Fly",
    Description = "Fly freely using WASD, Space to go up, LeftShift to go down",
    Default = false,
    Callback = function(value)
        if value then
            startFly()
            notify("Fly", "Enabled", 2)
        else
            stopFly()
            notify("Fly", "Disabled", 2)
        end
    end
})

PlayerTab:Slider({
    Title = "Fly Speed",
    Description = "Adjust flight speed",
    Flag = "FlySpeedSlider",
    Value = { Min = 20, Max = 200, Default = 50 },
    Step = 5,
    Callback = function(value)
        Fly.Speed = value
    end
})

PlayerTab:Divider()

PlayerTab:Toggle({
    Title = "No Clip",
    Description = "Walk through walls and objects",
    Default = false,
    Callback = function(value)
        Noclip.Enabled = value
        if value then
            enableNoclip()
            notify("No Clip", "Enabled", 2)
        else
            disableNoclip()
            notify("No Clip", "Disabled", 2)
        end
    end
})

PlayerTab:Divider()

PlayerTab:Section({ Title = "Auto Respawn", TextSize = 20 })

PlayerTab:Toggle({
    Title = "Auto Respawn",
    Description = "Auto respawn when knocked by teleporting out of bounds",
    Default = false,
    Callback = function(value)
        AutoRespawn.Enabled = value
        if value then
            local char = LocalPlayer.Character
            if char then attachAutoRespawn(char) end
            notify("Auto Respawn", "Enabled", 2)
        else
            detachAutoRespawn()
            notify("Auto Respawn", "Disabled", 2)
        end
    end
})

PlayerTab:Divider()

PlayerTab:Section({ Title = "Teleport", TextSize = 20 })

local TeleportUI = { PlayerName = nil, Dropdown = nil }

local function getPlayerList()
    local names = {}
    for _, pl in pairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer then
            table.insert(names, pl.Name)
        end
    end
    table.sort(names)
    return #names > 0 and names or { "No players" }
end

local function refreshPlayerDropdown()
    if TeleportUI.Dropdown then
        local list = getPlayerList()
        TeleportUI.Dropdown:Refresh(list)
        if list[1] and list[1] ~= "No players" then
            if not TeleportUI.PlayerName or not table.find(list, TeleportUI.PlayerName) then
                TeleportUI.PlayerName = list[1]
                TeleportUI.Dropdown:Select(TeleportUI.PlayerName)
            end
        else
            TeleportUI.PlayerName = nil
        end
    end
end

TeleportUI.Dropdown = PlayerTab:Dropdown({
    Title = "Select Player",
    Flag = "TeleportPlayerDropdown",
    Values = getPlayerList(),
    Value = getPlayerList()[1] or "No players",
    Callback = function(value)
        if value ~= "No players" then
            TeleportUI.PlayerName = value
        end
    end
})

PlayerTab:Button({
    Title = "Teleport to Player",
    Description = "Teleport to the selected player",
    Callback = function()
        if not TeleportUI.PlayerName then
            notify("Teleport", "No player selected", 2)
            return
        end
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then
            notify("Teleport", "Character not found", 2)
            return
        end
        local target = Players:FindFirstChild(TeleportUI.PlayerName)
        if not target or not target.Character or not target.Character:FindFirstChild("HumanoidRootPart") then
            notify("Teleport", TeleportUI.PlayerName .. " not found", 2)
            refreshPlayerDropdown()
            return
        end
        hrp.CFrame = target.Character.HumanoidRootPart.CFrame + Vector3.new(0, 3, 0)
        notify("Teleport", "Teleported to " .. TeleportUI.PlayerName, 2)
    end
})

PlayerTab:Button({
    Title = "Refresh Player List",
    Description = "Update the player list",
    Callback = function()
        refreshPlayerDropdown()
        notify("Player List", "Refreshed", 2)
    end
})

Players.PlayerAdded:Connect(function()
    task.wait(0.5)
    refreshPlayerDropdown()
end)

Players.PlayerRemoving:Connect(function()
    task.wait(0.1)
    refreshPlayerDropdown()
end)

-- ========================================================================= --
--                              AUTO PARRY TAB                               --
-- ========================================================================= --
local AutoParryTab = Window:Tab({ Title = "Combat", Icon = "shield" })

-- ── Enable/Disable ────────────────────────────────────────────────────── --
AutoParryTab:Section({ Title = "Auto Parry", TextSize = 20 })

AutoParryTab:Toggle({
    Title = "Perfect Auto Parry",
    Description = "Ultra-fast automatic timing for regular and M2 parries; no setup required",
    Default = false,
    Callback = function(Value)
        AutoParry.PerfectEnabled = Value
        AutoParry.ParryToken += 1
        AutoParry.PendingParry = {}
        releaseBlock()
        if Value then
            debugLog("[BagahHub STATE]", "Perfect Auto Parry enabled")
            notify("✨ Perfect Auto Parry", "ON - automatic M1/M2 timing", 2)
        else
            debugLog("[BagahHub STATE]", "Perfect Auto Parry disabled")
        end
    end
})

AutoParryTab:Toggle({
    Title = "Animation Sync",
    Description = "Optional high-precision timing from enemy animation progress; Perfect Auto Parry required",
    Default = false,
    Callback = function(Value)
        AutoParry.AnimationSyncEnabled = Value
        AutoParry.ParryToken += 1
        AutoParry.PendingParry = {}
        releaseBlock()
        debugLog("[BagahHub STATE]", "Animation Sync", Value and "enabled" or "disabled")
        if Value and not AutoParry.PerfectEnabled then
            notify("🎯 Animation Sync", "Ready - enable Perfect Auto Parry to use it", 2)
        elseif Value then
            notify("🎯 Animation Sync", "ON - animation progress correction enabled", 2)
        end
    end
})

AutoParryTab:Toggle({
    Title = "Parry Facing",
    Description = "Automatically face the attacker when parrying attacks from any direction",
    Default = false,
    Callback = function(Value)
        AutoParry.FacingEnabled = Value
        if not Value then restoreParryFacing() end
        debugLog("[BagahHub STATE]", "Parry Facing", Value and "enabled" or "disabled")
    end
})

AutoParryTab:Toggle({
    Title = "Grapple-Aware Combat",
    Description = "Automatically backdash against grapple moves and all M2 attacks",
    Default = false,
    Callback = function(Value)
        AutoParry.GrappleAwareEnabled = Value
        AutoParry.LastGrappleDodge = 0
        debugLog("[BagahHub STATE]", "Grapple-Aware Combat",
            Value and "enabled" or "disabled")
        if Value then
            notify("🥊 Grapple-Aware Combat", "ON - grapple/M2 backdash enabled", 2)
        end
    end
})

AutoParryTab:Toggle({
    Title = "Auto Punish",
    Description = "Instantly counter with one M1 after a confirmed perfect parry",
    Default = false,
    Callback = function(Value)
        AutoParry.AutoPunishEnabled = Value
        AutoParry.LastAutoPunish = 0
        debugLog("[BagahHub STATE]", "Auto Punish", Value and "enabled" or "disabled")
    end
})

AutoParryTab:Toggle({
    Title = "Face Lock",
    Description = "Continuously rotate toward the nearest enemy within range",
    Default = false,
    Callback = function(Value)
        AutoParry.FaceLockEnabled = Value
        if Value then
            startFaceLock()
            notify("🎯 Face Lock", "ON - auto-facing nearest enemy", 2)
        else
            stopFaceLock()
        end
        debugLog("[BagahHub STATE]", "Face Lock", Value and "enabled" or "disabled")
    end
})

AutoParryTab:Toggle({
    Title = "Block M1 Until Parry",
    Description = "Holds your M1 until the parry resolves, so it can't cancel the block",
    Default = false,
    Callback = function(Value)
        AutoParry.BlockM1Enabled = Value
        if Value then hookNamecall() end
        debugLog("[BagahHub STATE]", "Block M1 Until Parry", Value and "enabled" or "disabled")
    end
})

AutoParryTab:Toggle({
    Title = "Hold Through Combo",
    Description = "Holds block ~0.35s longer against fast M1 chains",
    Default = false,
    Callback = function(Value)
        AutoParry.ComboHoldEnabled = Value
        debugLog("[BagahHub STATE]", "Hold Through Combo", Value and "enabled" or "disabled")
    end
})

AutoParryTab:Toggle({
    Title = "Facing Check",
    Description = "Only parry attackers that are actually facing you",
    Default = false,
    Callback = function(Value)
        AutoParry.FacingCheckEnabled = Value
        debugLog("[BagahHub STATE]", "Facing Check", Value and "enabled" or "disabled")
    end
})

AutoParryTab:Section({ Title = "Parry Settings", TextSize = 20 })

-- ── Timing ────────────────────────────────────────────────────────────── --
AutoParryTab:Slider({
    Title = "Max Distance",
    Description = "How far away a swing still gets picked up",
    Flag = "EnemyDistanceSlider",
    Value = { Min = 3, Max = 30, Default = 6 },
    Step = 1,
    Callback = function(Value)
        AutoParry.MaxDistance = Value
        PERFECT_PARRY_CONFIG.MaxDistance = Value + 12
    end
})

AutoParryTab:Slider({
    Title = "Face Target Range",
    Description = "Max range Face Lock / Parry Facing will rotate you to square up",
    Flag = "FaceTargetRangeSlider",
    Value = { Min = 3, Max = 20, Default = 7 },
    Step = 1,
    Callback = function(Value)
        AutoParry.FaceTargetRange = Value
    end
})

AutoParryTab:Slider({
    Title = "Parry Timing",
    Description = "Seconds before impact the block is pressed",
    Flag = "PerfectWindowLeadSlider",
    Value = { Min = 0.01, Max = 0.35, Default = 0.06 },
    Step = 0.005,
    Callback = function(Value)
        AutoParry.ImpactLead = Value
    end
})

AutoParryTab:Slider({
    Title = "Block Hold Time",
    Description = "Seconds the block is held. Fine 0.01 steps for precise tuning",
    Flag = "ParryHoldTimeSlider",
    Value = { Min = 0.08, Max = 0.8, Default = 0.30 },
    Step = 0.01,
    Callback = function(Value)
        AutoParry.ParryDuration = Value
    end
})

AutoParryTab:Slider({
    Title = "Ping Adjust %",
    Description = "Scales ping compensation. 100% = default; raise if late, lower if early",
    Flag = "PingAdjustSlider",
    Value = { Min = 0, Max = 300, Default = 100 },
    Step = 5,
    Callback = function(Value)
        AutoParry.PingAdjustPercent = Value
    end
})

AutoParryTab:Section({ Title = "Fallback Safety Block", TextSize = 20 })

AutoParryTab:Toggle({
    Title = "Fallback Safety Block",
    Description = "When parry can't trigger (too far), hold block briefly as a safety net",
    Default = false,
    Callback = function(Value)
        AutoParry.FallbackBlockEnabled = Value
        debugLog("[BagahHub STATE]", "Fallback Safety Block", Value and "enabled" or "disabled")
    end
})

AutoParryTab:Slider({
    Title = "Fallback Block Duration",
    Description = "How long the safety block is held (seconds)",
    Flag = "FallbackBlockDurationSlider",
    Value = { Min = 0.1, Max = 1.5, Default = 0.45 },
    Step = 0.05,
    Callback = function(Value)
        AutoParry.FallbackBlockDuration = Value
    end
})

AutoParryTab:Slider({
    Title = "Fallback Block Range",
    Description = "Max distance to trigger safety block (studs)",
    Flag = "FallbackBlockRangeSlider",
    Value = { Min = 5, Max = 30, Default = 12 },
    Step = 1,
    Callback = function(Value)
        AutoParry.FallbackBlockRange = Value
    end
})
if DEBUG_TAB_ENABLED then
    -- ========================================================================= --
    --                                  DEBUG TAB                                 --
    -- ========================================================================= --
    local DebugTab = Window:Tab({ Title = "Debug", Icon = "bug" })

    DebugTab:Toggle({
        Title = "Auto Parry Debug Log",
        Description = "Record Auto Parry events; press F8 to copy active debug logs",
        Default = false,
        Callback = function(value)
            Dbg.Events = value
            if value then
                Dbg.StartedAt = os.clock()
                table.clear(Dbg.Timeline)
                debugLog("[BagahHub STATE]", "Auto Parry debug enabled")
            end
        end
    })

    DebugTab:Toggle({
        Title = "Stun/Ragdoll Debug Log",
        Description = "Record attributes, states, animations, properties, and outgoing remotes; press F8 to copy",
        Default = false,
        Callback = function(value)
            Dbg.StunEvents = value
            if value then
                Dbg.StunStartedAt = os.clock()
                table.clear(Dbg.StunTimeline)
                hookNamecall()
                attachStunDebug(LocalPlayer.Character)
                stunDebugLog("STATE", "enabled", "AntiStun=", CS.AntiStun, "AntiRagdoll=", CS.AntiRagdoll)
            else
                disconnectStunDebugConnections()
            end
        end
    })

    DebugTab:Button({
        Title = "Copy Active Debug Logs",
        Description = "Copy whichever debug logs are currently enabled (same as F8)",
        Callback = copyActiveDebugLogs
    })

    DebugTab:Divider()

    DebugTab:Toggle({
        Title = "Rhythm Debug",
        Description = "Logs note detection, timing, receptor coordinates, and input results",
        Default = false,
        Callback = function(value)
            Rhythm.DebugEnabled = value
            if value then
                table.clear(Rhythm.DebugTimeline)
                Rhythm.DebugStartedAt = os.clock()
                rhythmDebug("DEBUG", "started")
                rhythmScan()
                rhythmDebugStructure()
                rhythmDebugAndroidHierarchy()
            end
        end
    })

    DebugTab:Toggle({
        Title = "Rhythm Rating Spy",
        Description = "Detects Perfect/Good/Ok/Miss ratings from game UI and logs timing delta",
        Default = false,
        Callback = function(value)
            Rhythm.RatingSpy = value
            if value then
                table.clear(Rhythm.RatingCounts)
                Rhythm.RatingTotal = 0
                table.clear(Rhythm.LastPressAt)
                rhythmConnectRatingSpy(Rhythm.Root)
                rhythmDebug("RATING SPY", "enabled", "root=", Rhythm.Root or "nil")
            else
                if Rhythm.RatingConn then
                    Rhythm.RatingConn:Disconnect()
                    Rhythm.RatingConn = nil
                end
                rhythmDebug("RATING SPY", "disabled", "total=", Rhythm.RatingTotal)
            end
        end
    })

    DebugTab:Toggle({
        Title = "Rhythm GUI Inspector",
        Description = "Watch RhythmServiceUI, RhythmRoot, Judgement, Note, and HitShard changes; press F8 to copy",
        Default = false,
        Callback = function(value)
            Rhythm.GuiInspector = value
            if value then
                Rhythm.DebugEnabled = true
                Rhythm.DebugStartedAt = os.clock()
                table.clear(Rhythm.DebugTimeline)
                rhythmScan()
                rhythmConnectGuiInspector()
            else
                rhythmDebug("GUI INSPECT", "disabled")
                rhythmDisconnectGuiInspector()
            end
        end
    })

    DebugTab:Divider()

    DebugTab:Toggle({
        Title = "Auto Respawn Debug",
        Description = "Log knock detection and teleport trigger events",
        Default = false,
        Callback = function(value)
            Dbg.ArDebug = value
            if value then
                table.clear(Dbg.ArTimeline)
                arDebug("debug enabled")
                arDebug("AutoRespawnEnabled=" .. tostring(AutoRespawn.Enabled))
            end
        end
    })
end

-- ========================================================================= --
--                                 ESP SUITE                                  --
-- ========================================================================= --
local ESP = {
    ShowBox          = false,
    ShowHealth       = false,
    ShowStamina      = false,
    ShowTracer       = false,
    ShowInfo         = false,
    ShowHighlight    = false,
    MaxDistance      = 200,
    BoxColor         = Color3.fromRGB(255, 255, 255),
    TracerColor      = Color3.fromRGB(255, 255, 255),
    InfoColor        = Color3.fromRGB(255, 255, 255),
    HighlightColor   = Color3.fromRGB(255, 60, 60),
    Generation       = 0,
    -- Internal state
    Objects          = {},
    Highlights       = {},
    CharCache        = {},
    FrameLocalRoot   = nil,
    WorkspacePlayers = nil,
    WorkspaceNpcs    = nil,
}

local function espHasEnabledFeature()
    return ESP.ShowBox or ESP.ShowHealth or ESP.ShowStamina
        or ESP.ShowTracer or ESP.ShowInfo or ESP.ShowHighlight
end

local function espRemoveDrawing(object)
    if not object then return end
    pcall(function() object.Visible = false end)
    pcall(function() object:Remove() end)
    pcall(function() object:Destroy() end)
end

local function espClearDrawingFields(fields)
    for _, objects in pairs(ESP.Objects) do
        for _, field in ipairs(fields) do
            local object = objects[field]
            if object then
                espRemoveDrawing(object)
                objects[field] = nil
            end
        end
    end
end

local function espClearHighlights()
    local models = {}
    for model, _ in pairs(ESP.Highlights) do
        table.insert(models, model)
    end
    for _, model in ipairs(models) do
        local highlight = ESP.Highlights[model]
        if highlight then
            pcall(function()
                highlight.Enabled = false
                highlight:Destroy()
            end)
        end
        ESP.Highlights[model] = nil
    end
end

local function espGetCharacter(model)
    if not model or not model:IsA("Model") then return nil end
    if model == LocalPlayer.Character then return nil end

    -- Return cached refs if still valid (avoids FindFirstChild per frame)
    local cached = ESP.CharCache[model]
    if cached and cached.HRP.Parent == model and cached.Humanoid.Parent == model then
        if cached.Humanoid.Health <= 0 then return nil end
        return cached
    end

    local hrp = model:FindFirstChild("HumanoidRootPart")
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then
        ESP.CharCache[model] = nil
        return nil
    end

    local data = { Model = model, HRP = hrp, Humanoid = hum, Head = model:FindFirstChild("Head"), Name = model.Name }
    ESP.CharCache[model] = data
    return data
end

local function espCreateDrawing(type)
    local ok, result = pcall(function() return Drawing.new(type) end)
    return ok and result or nil
end

local function espGetHealth(character)
    local humanoid = character.Humanoid
    local maxHealth = tonumber(humanoid.MaxHealth) or 100
    local health = tonumber(humanoid.Health) or maxHealth

    if maxHealth <= 0 then maxHealth = 100 end
    return math.clamp(health / maxHealth, 0, 1), health, maxHealth
end

local function espClearModel(model)
    local objs = ESP.Objects[model]
    if objs then
        for _, d in pairs(objs) do
            espRemoveDrawing(d)
        end
        ESP.Objects[model] = nil
    end
    local hl = ESP.Highlights[model]
    if hl then
        pcall(function()
            hl.Enabled = false
            hl:Destroy()
        end)
        ESP.Highlights[model] = nil
    end
end

local function espUpdateModel(model)
    if not espHasEnabledFeature() then
        espClearModel(model)
        return
    end

    local char = espGetCharacter(model)
    if not char then
        espClearModel(model)
        return
    end

    local cam = workspace.CurrentCamera
    if not cam then return end

    -- ── Distance check (uses cached localRoot from espRender) ─────── --
    local dist = ESP.FrameLocalRoot and (ESP.FrameLocalRoot.Position - char.HRP.Position).Magnitude or math.huge
    if dist > ESP.MaxDistance then
        espClearModel(model)
        return
    end

    -- ── Screen-space bounding box ────────────────────────────────── --
    local head = char.Head
    local headPos = head and head.Position or char.HRP.Position + Vector3.new(0, 2.5, 0)
    local bottomPos = char.HRP.Position - Vector3.new(0, 1.2, 0)

    local top, topVis = cam:WorldToViewportPoint(headPos + Vector3.new(0, 0.6, 0))
    local bot, botVis = cam:WorldToViewportPoint(bottomPos)

    if not (topVis or botVis) then
        espClearModel(model)
        return
    end

    local h = math.abs(top.Y - bot.Y)
    local w = h * 0.55
    local x = top.X - w / 2
    local y = top.Y

    local objs = ESP.Objects[model]
    if not objs then
        objs = {}
        ESP.Objects[model] = objs
    end

    -- ── Box ──────────────────────────────────────────────────────── --
    if ESP.ShowBox then
        local box = objs.Box
        if not box then
            box = espCreateDrawing("Square"); objs.Box = box
        end
        if box then
            box.Visible = true
            box.Color = ESP.BoxColor
            box.Filled = false
            box.Thickness = 1.5
            box.Position = Vector2.new(x, y)
            box.Size = Vector2.new(w, h)
        end
    elseif objs.Box then
        objs.Box.Visible = false
    end

    -- ── Health Bar ────────────────────────────────────────────────── --
    local hp = espGetHealth(char)
    if ESP.ShowHealth then
        local barWidth = 5
        local barX = x - barWidth - 4
        local bar = objs.HealthBar
        if not bar then
            bar = espCreateDrawing("Square"); objs.HealthBar = bar
        end
        if bar then
            bar.Visible = true
            bar.Filled = true
            bar.Color = Color3.fromRGB(0, 255, 80)
            bar.ZIndex = 3
            bar.Position = Vector2.new(barX, bot.Y - h * hp)
            bar.Size = Vector2.new(barWidth, h * hp)
        end
        local bg = objs.HealthBg
        if not bg then
            bg = espCreateDrawing("Square"); objs.HealthBg = bg
        end
        if bg then
            bg.Visible = true
            bg.Filled = true
            bg.Color = Color3.fromRGB(40, 40, 40)
            bg.ZIndex = 2
            bg.Position = Vector2.new(barX, y)
            bg.Size = Vector2.new(barWidth, h)
        end
    else
        if objs.HealthBar then objs.HealthBar.Visible = false end
        if objs.HealthBg then objs.HealthBg.Visible = false end
    end

    -- ── Stamina Bar ────────────────────────────────────────────────── --
    local stamAttr = model:GetAttribute("Stamina")
    local stam = math.clamp(tonumber(stamAttr) or 0, 0, 100) / 100
    if ESP.ShowStamina then
        local barX = x - 10
        local bar = objs.StaminaBar
        if not bar then
            bar = espCreateDrawing("Square"); objs.StaminaBar = bar
        end
        if bar then
            bar.Visible = true
            bar.Filled = true
            bar.Color = Color3.fromRGB(100 + 155 * (1 - stam), 200 * stam, 255 * stam)
            bar.ZIndex = 3
            bar.Position = Vector2.new(barX, bot.Y - h * stam)
            bar.Size = Vector2.new(3, h * stam)
        end
        local bg = objs.StaminaBg
        if not bg then
            bg = espCreateDrawing("Square"); objs.StaminaBg = bg
        end
        if bg then
            bg.Visible = true
            bg.Filled = true
            bg.Color = Color3.fromRGB(40, 40, 40)
            bg.ZIndex = 2
            bg.Position = Vector2.new(barX, y)
            bg.Size = Vector2.new(3, h)
        end
    else
        if objs.StaminaBar then objs.StaminaBar.Visible = false end
        if objs.StaminaBg then objs.StaminaBg.Visible = false end
    end

    -- ── Tracer ─────────────────────────────────────────────────────── --
    if ESP.ShowTracer then
        local tracer = objs.Tracer
        if not tracer then
            tracer = espCreateDrawing("Line"); objs.Tracer = tracer
        end
        if tracer then
            tracer.Visible = true
            tracer.Color = ESP.TracerColor
            tracer.Thickness = 1.2
            tracer.From = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)
            tracer.To = Vector2.new(top.X, bot.Y)
        end
    elseif objs.Tracer then
        objs.Tracer.Visible = false
    end

    -- ── Name / Info ────────────────────────────────────────────────── --
    if ESP.ShowInfo then
        local tag = objs.NameTag
        if not tag then
            tag = espCreateDrawing("Text"); objs.NameTag = tag
        end
        if tag then
            tag.Visible = true
            tag.Color = ESP.InfoColor
            tag.Size = 13
            tag.Center = true
            tag.Outline = true
            tag.OutlineColor = Color3.new(0, 0, 0)
            tag.Position = Vector2.new(top.X, top.Y - 5)

            local text = char.Name
            if hp < 1 then text = text .. string.format(" [%.0f%%]", hp * 100) end
            if stam > 0 then text = text .. string.format(" · S:%.0f", stam * 100) end
            if model:GetAttribute("Blocking") then text = text .. " | BLOCK" end
            if model:GetAttribute("InCombat") then text = text .. " | FIGHT" end

            tag.Text = text
        end
    elseif objs.NameTag then
        objs.NameTag.Visible = false
    end

    -- ── Highlight (chams) ──────────────────────────────────────────── --
    if ESP.ShowHighlight then
        local hl = ESP.Highlights[model]
        if not hl then
            hl = Instance.new("Highlight")
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.FillTransparency = 0.5
            ESP.Highlights[model] = hl
        end
        hl.Parent = model
        hl.FillColor = ESP.HighlightColor
        hl.OutlineColor = ESP.HighlightColor
        hl.Enabled = true
    else
        local hl = ESP.Highlights[model]
        if hl then
            hl.Enabled = false
        end
    end
end

local function espRender()
    if not espHasEnabledFeature() then return end
    local gen = ESP.Generation

    -- Cache workspace containers (rarely change)
    if not ESP.WorkspacePlayers or not ESP.WorkspacePlayers.Parent then
        ESP.WorkspacePlayers = workspace:FindFirstChild("Players")
    end
    if not ESP.WorkspaceNpcs or not ESP.WorkspaceNpcs.Parent then
        ESP.WorkspaceNpcs = workspace:FindFirstChild("NPCs")
    end

    -- Cache local root once per frame (not per model)
    local localChar = LocalPlayer.Character
    ESP.FrameLocalRoot = localChar and localChar:FindFirstChild("HumanoidRootPart")

    -- Single pass: update models + track active set
    local active = {}

    if ESP.WorkspacePlayers then
        for _, model in ESP.WorkspacePlayers:GetChildren() do
            if ESP.Generation ~= gen then return end
            active[model] = true
            espUpdateModel(model)
        end
    end

    if ESP.WorkspaceNpcs then
        for _, model in ESP.WorkspaceNpcs:GetChildren() do
            if ESP.Generation ~= gen then return end
            active[model] = true
            espUpdateModel(model)
        end
    end

    if ESP.Generation ~= gen then return end

    -- Cleanup stale models (no second GetChildren needed)
    local stale = {}
    for model, _ in pairs(ESP.Objects) do
        if not active[model] then table.insert(stale, model) end
    end
    for _, model in ipairs(stale) do
        if ESP.Generation ~= gen then return end
        espClearModel(model)
        ESP.CharCache[model] = nil
    end
end

-- ========================================================================= --
--                                VISUAL TAB                                  --
-- ========================================================================= --
local VisualTab = Window:Tab({ Title = "Visuals", Icon = "eye" })

VisualTab:Section({ Title = "ESP", TextSize = 20 })

VisualTab:Toggle({
    Title = "Box",
    Description = "2D rectangle around enemies",
    Default = false,
    Callback = function(value)
        ESP.ShowBox = value
        if not value then espClearDrawingFields({ "Box" }) end
    end
})

VisualTab:Toggle({
    Title = "Health Bar",
    Description = "Health bar on the left side of the box",
    Default = false,
    Callback = function(value)
        ESP.ShowHealth = value
        if not value then espClearDrawingFields({ "HealthBar", "HealthBg" }) end
    end
})

VisualTab:Toggle({
    Title = "Stamina Bar",
    Description = "Stamina bar on the left side of the box",
    Default = false,
    Callback = function(value)
        ESP.ShowStamina = value
        if not value then espClearDrawingFields({ "StaminaBar", "StaminaBg" }) end
    end
})

VisualTab:Toggle({
    Title = "Tracer",
    Description = "Line from screen bottom to enemy",
    Default = false,
    Callback = function(value)
        ESP.ShowTracer = value
        if not value then espClearDrawingFields({ "Tracer" }) end
    end
})

VisualTab:Toggle({
    Title = "Name & Info",
    Description = "Show player name, HP%, stamina, combat state",
    Default = false,
    Callback = function(value)
        ESP.ShowInfo = value
        if not value then espClearDrawingFields({ "NameTag" }) end
    end
})

VisualTab:Toggle({
    Title = "Highlight / Chams",
    Description = "Outline + fill glow around enemies",
    Default = false,
    Callback = function(value)
        ESP.ShowHighlight = value
        if not value then espClearHighlights() end
    end
})

VisualTab:Slider({
    Title = "ESP Distance",
    Description = "Max render distance for ESP",
    Flag = "ESPDistanceSlider",
    Value = { Min = 20, Max = 500, Default = 200 },
    Step = 10,
    Callback = function(value) ESP.MaxDistance = value end
})

VisualTab:Divider()

VisualTab:Section({ Title = "Player HUD", TextSize = 20 })

local HUD = { ShowHealth = false, ShowStamina = false, Objects = {}, Connections = {} }
local AntiAfk = { Enabled = false, Conn = nil }

local function hudCreateBar(yOffset)
    local bar = {}
    local ok1, bg = pcall(function() return Drawing.new("Square") end)
    local ok2, fill = pcall(function() return Drawing.new("Square") end)
    local ok3, txt = pcall(function() return Drawing.new("Text") end)
    if not ok1 or not ok2 or not ok3 then return nil end
    bg.Filled = true
    bg.Color = Color3.fromRGB(20, 20, 20)
    bg.Transparency = 0.4
    bg.Thickness = 1
    bg.Visible = false
    fill.Filled = true
    fill.Thickness = 1
    fill.Visible = false
    txt.Size = 13
    txt.Center = true
    txt.Outline = true
    txt.OutlineColor = Color3.fromRGB(0, 0, 0)
    txt.Color = Color3.fromRGB(255, 255, 255)
    txt.Visible = false
    bar.bg = bg
    bar.fill = fill
    bar.txt = txt
    bar.yOffset = yOffset
    return bar
end

local function hudUpdateBar(bar, percent, color, label)
    if not bar then return end
    local cam = workspace.CurrentCamera
    if not cam then return end
    local screenW = cam.ViewportSize.X
    local screenH = cam.ViewportSize.Y
    local barW = 220
    local barH = 14
    local x = (screenW - barW) / 2
    local y = screenH - 60 + bar.yOffset
    bar.bg.Size = Vector2.new(barW, barH)
    bar.bg.Position = Vector2.new(x, y)
    bar.bg.Visible = true
    local fillW = math.floor(barW * (percent / 100))
    bar.fill.Size = Vector2.new(fillW, barH)
    bar.fill.Position = Vector2.new(x, y)
    bar.fill.Color = color
    bar.fill.Visible = true
    bar.txt.Position = Vector2.new(screenW / 2, y - 1)
    bar.txt.Text = label .. " " .. percent .. "%"
    bar.txt.Visible = true
end

local function hudRemoveBar(bar)
    if not bar then return end
    pcall(function()
        bar.bg.Visible = false; bar.bg:Remove()
    end)
    pcall(function()
        bar.fill.Visible = false; bar.fill:Remove()
    end)
    pcall(function()
        bar.txt.Visible = false; bar.txt:Remove()
    end)
end

local function hudUpdateHealth()
    if not (HUD.ShowHealth and HUD.Objects.health) then return end
    local char = LocalPlayer.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local hpPercent = math.floor((hum.Health / hum.MaxHealth) * 100)
    local color = hpPercent > 50 and Color3.fromRGB(80, 255, 80)
        or hpPercent > 25 and Color3.fromRGB(255, 200, 0)
        or Color3.fromRGB(255, 60, 60)
    hudUpdateBar(HUD.Objects.health, hpPercent, color, "HP")
end

local function hudUpdateStamina()
    if not (HUD.ShowStamina and HUD.Objects.stamina) then return end
    local char = LocalPlayer.Character
    if not char then return end
    local stamina = math.floor(char:GetAttribute("Stamina") or 100)
    local color = stamina > 50 and Color3.fromRGB(80, 180, 255)
        or stamina > 25 and Color3.fromRGB(255, 200, 0)
        or Color3.fromRGB(255, 60, 60)
    hudUpdateBar(HUD.Objects.stamina, stamina, color, "STA")
end

local function startHud()
    -- Disconnect old connections
    for _, conn in ipairs(HUD.Connections) do conn:Disconnect() end
    table.clear(HUD.Connections)

    if HUD.ShowHealth then
        if not HUD.Objects.health then HUD.Objects.health = hudCreateBar(-20) end
        local char = LocalPlayer.Character
        if char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                hudUpdateHealth()
                table.insert(HUD.Connections, hum:GetPropertyChangedSignal("Health"):Connect(hudUpdateHealth))
                table.insert(HUD.Connections, hum:GetPropertyChangedSignal("MaxHealth"):Connect(hudUpdateHealth))
            end
        end
    end
    if HUD.ShowStamina then
        if not HUD.Objects.stamina then HUD.Objects.stamina = hudCreateBar(0) end
        local char = LocalPlayer.Character
        if char then
            hudUpdateStamina()
            table.insert(HUD.Connections, char:GetAttributeChangedSignal("Stamina"):Connect(hudUpdateStamina))
        end
    end
end

local function stopHud()
    if not HUD.ShowHealth and not HUD.ShowStamina then
        for _, conn in ipairs(HUD.Connections) do conn:Disconnect() end
        table.clear(HUD.Connections)
        for _, bar in pairs(HUD.Objects) do hudRemoveBar(bar) end
        HUD.Objects = {}
    end
end

VisualTab:Toggle({
    Title = "Show Health",
    Description = "Health bar at bottom-center of screen",
    Default = false,
    Callback = function(value)
        HUD.ShowHealth = value
        if value then
            if not HUD.Objects.health then HUD.Objects.health = hudCreateBar(-20) end
            startHud()
        else
            hudRemoveBar(HUD.Objects.health)
            HUD.Objects.health = nil
            stopHud()
        end
    end
})

VisualTab:Toggle({
    Title = "Show Stamina",
    Description = "Stamina bar at bottom-center of screen",
    Default = false,
    Callback = function(value)
        HUD.ShowStamina = value
        if value then
            if not HUD.Objects.stamina then HUD.Objects.stamina = hudCreateBar(0) end
            startHud()
        else
            hudRemoveBar(HUD.Objects.stamina)
            HUD.Objects.stamina = nil
            stopHud()
        end
    end
})


local function startAntiAfk()
    if AntiAfk.Conn then return end
    AntiAfk.Conn = LocalPlayer.Idled:Connect(function()
        VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        task.wait(1)
        VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    end)
end

local function stopAntiAfk()
    if AntiAfk.Conn then
        AntiAfk.Conn:Disconnect()
        AntiAfk.Conn = nil
    end
end

local MiscTab = Window:Tab({ Title = "Misc", Icon = "gravity:bulb" })

MiscTab:Section({ Title = "Music Game Rhythm", TextSize = 20 })

MiscTab:Toggle({
    Title = "Rhythm Auto",
    Description = "Automatically plays Gakuran rhythm notes (F6 is also supported)",
    Default = false,
    Callback = function(value)
        setRhythmEnabled(value)
    end
})

MiscTab:Dropdown({
    Title = "Timing Mode",
    Description = "Always Perfect = hit every note perfectly | Custom Mix = random PERFECT/GOOD/OK/BAD",
    Flag = "RhythmTimingMode",
    Values = { "Always Perfect", "Custom Mix" },
    Value = "Always Perfect",
    Callback = function(value)
        Rhythm.Mode = value == "Custom Mix" and "custom" or "perfect"
    end
})

MiscTab:Slider({
    Title = "Press Lead (ms)",
    Description = "Extra milliseconds to press early (0 = exact timing)",
    Flag = "RhythmPressLead",
    Value = { Min = 0, Max = 100, Default = 0 },
    Step = 5,
    Callback = function(value)
        Rhythm.PressLeadMs = value
    end
})

MiscTab:Slider({
    Title = "Hold Extend (ms)",
    Description = "Extra milliseconds to hold long notes (default 80)",
    Flag = "RhythmHoldExtend",
    Value = { Min = 0, Max = 300, Default = 80 },
    Step = 10,
    Callback = function(value)
        Rhythm.HoldExtendMs = value
    end
})

MiscTab:Slider({
    Title = "PERFECT %",
    Description = "Custom Mix: chance of PERFECT hit per note",
    Flag = "RhythmPerfectChance",
    Value = { Min = 0, Max = 100, Default = 70 },
    Step = 5,
    Callback = function(value)
        Rhythm.PerfectChance = value
    end
})

MiscTab:Slider({
    Title = "GOOD %",
    Description = "Custom Mix: chance of GOOD hit per note",
    Flag = "RhythmGoodChance",
    Value = { Min = 0, Max = 100, Default = 25 },
    Step = 5,
    Callback = function(value)
        Rhythm.GoodChance = value
    end
})

MiscTab:Slider({
    Title = "OK %",
    Description = "Custom Mix: chance of OK hit per note (rest = BAD)",
    Flag = "RhythmOkChance",
    Value = { Min = 0, Max = 100, Default = 5 },
    Step = 5,
    Callback = function(value)
        Rhythm.OkChance = value
    end
})

MiscTab:Toggle({
    Title = "Anti AFK",
    Description = "Prevent auto-kick by simulating input when idle",
    Default = false,
    Callback = function(value)
        AntiAfk.Enabled = value
        if value then
            startAntiAfk()
        else
            stopAntiAfk()
        end
    end
})


-- -------------------------------------------------------------------------- --
--                             SERVER INFORMATION                             --
-- -------------------------------------------------------------------------- --

local function getServerLink()
    return string.format("https://www.roblox.com/games/start?placeId=%d&jobId=%s", game.PlaceId, game.JobId)
end

local ServerTab = Window:Tab({ Icon = "server", Title = "Server" })

ServerTab:Section({ Title = "Server Info", TextSize = 20 })
ServerTab:Divider()

ServerTab:Paragraph({
    Title = "Server ID",
    Desc = game.JobId
})

ServerTab:Paragraph({
    Title = "Place ID",
    Desc = tostring(game.PlaceId)
})

ServerTab:Divider()
ServerTab:Section({ Title = "Quick Actions", TextSize = 20 })
ServerTab:Divider()

ServerTab:Button({
    Title = "Copy Server Link",
    Desc = "Copy the current server's join link",
    Icon = "link",
    Callback = function()
        local serverLink = getServerLink()
        local success, errorMsg = pcall(function()
            setclipboard(serverLink)
        end)

        if success then
            Info("Link Copied", "Server invite link copied to clipboard!", 3)
        else
            Error("Copy Failed", "Your executor doesn't support setclipboard", 3)
            warn("Failed to copy link:", errorMsg)
            warn("Server Link:", serverLink)
        end
    end
})

ServerTab:Button({
    Title = "Rejoin Server",
    Desc = "Rejoin the current server",
    Icon = "refresh-cw",
    Callback = function()
        game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
    end
})


ServerTab:Button({
    Title = "Server Hop",
    Desc = "Join a random server with 5+ players",
    Icon = "shuffle",
    Callback = function()
        local success, servers = pcall(function()
            return game:GetService("HttpService"):JSONDecode(game:HttpGet("https://games.roblox.com/v1/games/" ..
                game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"))
        end)
        if success and servers and servers.data and #servers.data > 0 then
            local filteredServers = {}
            for _, server in ipairs(servers.data) do
                if server.playing >= 5 then table.insert(filteredServers, server) end
            end
            if #filteredServers > 0 then
                local randomServer = filteredServers[math.random(1, #filteredServers)]
                game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, randomServer.id, LocalPlayer)
            else
                WindUI:Notify({ Title = "Server Hop Failed", Content = "No servers with 5+ players found!", Duration = 3 })
            end
        else
            WindUI:Notify({ Title = "Server Hop Failed", Content = "Could not fetch servers!", Duration = 3 })
        end
    end
})

ServerTab:Button({
    Title = "Hop to Small Server",
    Desc = "Hop to the emptiest available server",
    Icon = "minimize",
    Callback = function()
        local success, servers = pcall(function()
            return game:GetService("HttpService"):JSONDecode(game:HttpGet("https://games.roblox.com/v1/games/" ..
                game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"))
        end)
        if success and servers and servers.data and #servers.data > 0 then
            table.sort(servers.data, function(a, b) return a.playing < b.playing end)
            if servers.data[1] then
                game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, servers.data[1].id, LocalPlayer)
            end
        else
            WindUI:Notify({ Title = "Server Hop Failed", Content = "Could not fetch servers!", Duration = 3 })
        end
    end

})

local InfoTab = Window:Tab({ Icon = "info", Title = "Info" })

InfoTab:Section({ Title = "Discord", TextSize = 20 })

InfoTab:Button({
    Title = "Copy Discord Invite",
    Description = "https://discord.gg/kJ552CMBx4",
    Callback = function()
        pcall(function() setclipboard("https://discord.gg/kJ552CMBx4") end)
        notify("Discord", "Invite link copied to clipboard!", 2)
    end
})

InfoTab:Divider()

InfoTab:Section({ Title = "Credits", TextSize = 20 })

InfoTab:Paragraph({
    Title = "Project",
    Desc = "Bagah Project"
})

InfoTab:Paragraph({
    Title = "Script by",
    Desc = "ahmuq"
})


Window:SelectTab(1)

-- ========================================================================= --
--                               ESP RENDER LOOP                              --
-- ========================================================================= --
task.spawn(function()
    while true do
        if espHasEnabledFeature() then espRender() end
        task.wait(0.033) -- ~30fps, 2D drawings don't need 60fps
    end
end)


-- ========================================================================= --
--                            NOTIFICATION HELPER                             --
-- ========================================================================= --
notify = function(title, text, duration)
    WindUI:Notify({
        Title = title,
        Content = text,
        Duration = duration or 2,
    })
end

-- ========================================================================= --
--                               INITIALIZED                                  --
-- ========================================================================= --
notify("BagahHub - Gakuran", "Script Loaded !", 3)
