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
local AR_DEBUG            = false
local AR_DEBUG_TIMELINE   = {}

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
}

local PERFECT_PARRY_CONFIG = {
    MinDelay = 0.01,
    HoldTime = 0.30,
    MaxDistance = 18,
    M1ImpactTime = 0.42,
    M2ImpactTime = 0.61,
    InputLead = 0.06,
    MaxSyncCorrection = 0.12,
}

local function getPerfectDefaultImpactTime(registryPath)
    local lowerPath = string.lower(registryPath)
    if string.find(lowerPath, "m2", 1, true) then
        return PERFECT_PARRY_CONFIG.M2ImpactTime
    end
    if string.find(lowerPath, "2ndm1", 1, true)
        or string.find(lowerPath, "3rdm1", 1, true) then
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
local DEBUG_EVENTS       = false
local DEBUG_COPY_KEY     = Enum.KeyCode.F8
local DebugTimeline      = {}
local DebugStartedAt     = os.clock()
local STUN_DEBUG_EVENTS  = false
local StunDebugTimeline  = {}
local StunDebugStartedAt = os.clock()

local function debugLog(...)
    local values = { ... }
    for index, value in values do
        values[index] = tostring(value)
    end

    local line = string.format("+%.6f | %s", os.clock() - DebugStartedAt,
        table.concat(values, " "))
    table.insert(DebugTimeline, line)
    if #DebugTimeline > 1500 then
        table.remove(DebugTimeline, 1)
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
    return header .. "\n" .. table.concat(DebugTimeline, "\n")
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
    if not STUN_DEBUG_EVENTS then return end
    local values = { ... }
    for index, value in ipairs(values) do
        values[index] = stunDebugValue(value)
    end
    local line = string.format("+%.6f | [STUN %s] %s",
        os.clock() - StunDebugStartedAt, tag, table.concat(values, " "))
    table.insert(StunDebugTimeline, line)
    if #StunDebugTimeline > 2000 then table.remove(StunDebugTimeline, 1) end
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
    return header .. "\n" .. table.concat(StunDebugTimeline, "\n")
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if not STUN_DEBUG_EVENTS then return end
    local inputName = input.UserInputType == Enum.UserInputType.Keyboard
        and input.KeyCode.Name or input.UserInputType.Name
    stunDebugLog("INPUT BEGIN", inputName, "processed=", gameProcessed)
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
    if not STUN_DEBUG_EVENTS then return end
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
local faceLockConnection = nil

local function stopFaceLock()
    if faceLockConnection then
        faceLockConnection:Disconnect()
        faceLockConnection = nil
    end
    restoreParryFacing()
end

local function startFaceLock()
    if faceLockConnection then return end
    faceLockConnection = RunService.Heartbeat:Connect(function()
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

    if DEBUG_EVENTS then
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

local notify

-- ========================================================================= --
--                       PRE-HIT ANIMATION DETECTION                         --
-- ========================================================================= --
local animatorConnections = {}
local modelConnections = {}
local AttackAnimationIds = {}
local GrappleAnimationIds = {}

local function normalizeAnimationId(animationId)
    return tostring(animationId or ""):match("%d+") or ""
end

local function registerAnimation(animation)
    if not animation:IsA("Animation") then return end
    local animationId = normalizeAnimationId(animation.AnimationId)
    if animationId ~= "" then
        AttackAnimationIds[animationId] = animation:GetFullName()
    end
end

local function registerGrappleAnimation(animation)
    if not animation:IsA("Animation") then return end
    local animationId = normalizeAnimationId(animation.AnimationId)
    if animationId ~= "" then
        GrappleAnimationIds[animationId] = animation:GetFullName()
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
    table.clear(AttackAnimationIds)
    table.clear(GrappleAnimationIds)

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
    for _ in AttackAnimationIds do
        registeredCount += 1
    end
    debugLog("[BagahHub REGISTRY]", "Registered attack animations:", registeredCount)
end

buildAttackAnimationRegistry()

local function disconnectAnimator(model)
    local connection = animatorConnections[model]
    if connection then
        connection:Disconnect()
        animatorConnections[model] = nil
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

        animatorConnections[character] = animator.AnimationPlayed:Connect(function(track)
            if not isAnyAutoParryEnabled() and not AutoParry.GrappleAwareEnabled then return end
            if character:GetAttribute("CanFight") == false or character:GetAttribute("Ragdoll") == true then return end
            local maxDistance = AutoParry.PerfectEnabled
                and PERFECT_PARRY_CONFIG.MaxDistance or AutoParry.MaxDistance
            if getAttackerDistance(character.Name) > maxDistance then return end

            local animationId = normalizeAnimationId(track.Animation and track.Animation.AnimationId)
            if animationId == "" then return end
            local registryPath = AttackAnimationIds[animationId]
            local grapplePath = GrappleAnimationIds[animationId]

            if DEBUG_EVENTS then
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
                        - getNetworkOneWayTime() - correction
                    if DEBUG_EVENTS then
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
                    task.spawn(function()
                        RunService.Heartbeat:Wait()
                        local elapsed = os.clock() - attackStartedAt
                        local syncCorrection, syncValid = getAnimationSyncCorrection(track)
                        schedulePerfect(syncValid and syncCorrection or elapsed, syncValid)
                    end)
                else
                    schedulePerfect(0, false)
                end
            else
                local impactTime = AutoParry.LearnedImpactTime[animationId]
                    or AutoParry.DefaultImpactTime
                local parryDelay = math.max(AutoParry.MinParryDelay,
                    impactTime - AutoParry.ImpactLead)
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
    modelConnections[container] = container.ChildAdded:Connect(watchCharacter)
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

    if DEBUG_EVENTS then
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
                        if DEBUG_EVENTS then
                            debugLog("[BagahHub LEARNED]", recent.Id, "| sample:", impactTime,
                                "| smoothed impact:", learnedImpact, "| next delay:", learnedDelay)
                        end
                    end
                elseif DEBUG_EVENTS then
                    debugLog("[BagahHub LEARN]", "no registered attack-animation candidate for", attacker)
                end
                if DEBUG_EVENTS then
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
            if DEBUG_EVENTS then
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
            if DEBUG_EVENTS then
                debugLog("[BagahHub RESULT]", "BLOCKED (Sound)")
            end
        end


        if action == "PunchHit" and attacker ~= LocalPlayer.Name then
            if DEBUG_EVENTS then
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
            if DEBUG_EVENTS then
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
            if DEBUG_EVENTS then
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
local PlayerGui                = LocalPlayer:WaitForChild("PlayerGui")
local Rhythm                   = {
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
    HitWindow = UserInputService.TouchEnabled and 0.12 or 0.035,
    MinInterval = 0.015,
    NoteTravelTime = 2.5,
    TouchLeadTime = 0.06,
    Generation = 0,
    TouchMode = UserInputService.TouchEnabled,
    TouchPositions = {},
    TouchCorrection = nil,
    PendingTouches = {},
    DebugEnabled = false,
    DebugTimeline = {},
    DebugStartedAt = os.clock(),
    LastMissingRootDebug = 0,
}
local rhythmConnections        = {}
local rhythmManualTouchStarted = {}
local RHYTHM_BUILD_ID          = "android-four-key-timing-align-20260727-7"

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
        "Build: " .. RHYTHM_BUILD_ID,
        "Copied: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
        "TouchEnabled: " .. tostring(UserInputService.TouchEnabled),
        "KeyboardEnabled: " .. tostring(UserInputService.KeyboardEnabled),
        "TouchMode: " .. tostring(Rhythm.TouchMode),
        "Enabled: " .. tostring(Rhythm.Enabled),
        "Root: " .. tostring(Rhythm.Root),
        "LaneCount: " .. tostring(Rhythm.LaneCount),
        "TrackedNotes: " .. tostring(count),
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
local function copyActiveDebugLogs()
    local reports = {}
    if DEBUG_EVENTS then
        table.insert(reports, getAutoParryDebugOutput())
    end
    if STUN_DEBUG_EVENTS then
        table.insert(reports, getStunDebugOutput())
    end
    if Rhythm.DebugEnabled then
        table.insert(reports, makeRhythmDebugReport())
    end
    if AR_DEBUG then
        local report = "=== Auto Respawn Debug ===\n"
        if #AR_DEBUG_TIMELINE > 0 then
            report = report .. table.concat(AR_DEBUG_TIMELINE, "\n")
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
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if not gameProcessed and input.KeyCode == DEBUG_COPY_KEY then
        copyActiveDebugLogs()
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
    rhythmManualTouchStarted[input] = input.Position
    rhythmDebug("REAL TOUCH BEGIN", "pos=", input.Position,
        "processed=", processed, "state=", input.UserInputState)
end)

UserInputService.InputEnded:Connect(function(input, processed)
    if not Rhythm.DebugEnabled or input.UserInputType ~= Enum.UserInputType.Touch then return end
    rhythmDebug("REAL TOUCH END", "start=", rhythmManualTouchStarted[input] or "unknown",
        "pos=", input.Position, "processed=", processed,
        "state=", input.UserInputState)
    rhythmManualTouchStarted[input] = nil
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
local InfiniteStamina      = false
local NoDodgeCooldown      = false
local AntiStun             = false
local AntiRagdoll          = false
local DodgeCooldownTime    = 0
local lastDodgeTime        = 0
local namecallHooked       = false
local oldGameNamecall      = nil
local antiStunConnections  = {}
local stunDebugConnections = {}

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
    for _, connection in ipairs(antiStunConnections) do
        connection:Disconnect()
    end
    table.clear(antiStunConnections)
end

local function disconnectStunDebugConnections()
    for _, connection in ipairs(stunDebugConnections) do
        connection:Disconnect()
    end
    table.clear(stunDebugConnections)
end

local function attachStunDebug(character)
    disconnectStunDebugConnections()
    if not STUN_DEBUG_EVENTS or not character then return end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
        or character:WaitForChild("Humanoid", 10)
    if not humanoid then
        stunDebugLog("ERROR", "Humanoid not found")
        return
    end

    stunDebugLog("ATTACH", character, "attributes=", character:GetAttributes(),
        "state=", humanoid:GetState(), "walkSpeed=", humanoid.WalkSpeed,
        "jumpPower=", humanoid.JumpPower, "platformStand=", humanoid.PlatformStand)

    table.insert(stunDebugConnections, character.AttributeChanged:Connect(function(attribute)
        stunDebugLog("ATTRIBUTE", attribute, "=", character:GetAttribute(attribute),
            "all=", character:GetAttributes())
    end))
    table.insert(stunDebugConnections, humanoid.StateChanged:Connect(function(oldState, newState)
        stunDebugLog("HUMANOID STATE", oldState, "->", newState,
            "walkSpeed=", humanoid.WalkSpeed, "platformStand=", humanoid.PlatformStand)
    end))
    table.insert(stunDebugConnections, humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
        stunDebugLog("PROPERTY", "WalkSpeed=", humanoid.WalkSpeed)
    end))
    table.insert(stunDebugConnections, humanoid:GetPropertyChangedSignal("PlatformStand"):Connect(function()
        stunDebugLog("PROPERTY", "PlatformStand=", humanoid.PlatformStand)
    end))

    local animator = humanoid:FindFirstChildOfClass("Animator")
        or humanoid:WaitForChild("Animator", 5)
    if animator then
        table.insert(stunDebugConnections, animator.AnimationPlayed:Connect(function(track)
            local animation = track.Animation
            stunDebugLog("ANIMATION", "name=", animation and animation.Name or track.Name,
                "id=", animation and animation.AnimationId or "none",
                "priority=", track.Priority, "length=", track.Length)
            table.insert(stunDebugConnections, track.Stopped:Connect(function()
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
    if not (AntiStun or AntiRagdoll) or not character or not humanoid then return end

    if AntiRagdoll then
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
            if (animationType == "stun" and AntiStun)
                or (animationType == "ragdoll" and AntiRagdoll) then
                track:Stop(0)
            end
        end
    end
end

local function attachAntiStun(character)
    disconnectAntiStunConnections()
    if not (AntiStun or AntiRagdoll) or not character then return end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
        or character:WaitForChild("Humanoid", 10)
    if not humanoid then return end

    cancelRecovery(character, humanoid)
    table.insert(antiStunConnections, character.AttributeChanged:Connect(function(attribute)
        if (AntiStun and stunAttrs[attribute]) or (AntiRagdoll and ragdollAttrs[attribute]) then
            task.defer(cancelRecovery, character, humanoid)
        end
    end))
    table.insert(antiStunConnections, humanoid.StateChanged:Connect(function(_, newState)
        if AntiRagdoll and (newState == Enum.HumanoidStateType.Ragdoll
                or newState == Enum.HumanoidStateType.FallingDown
                or newState == Enum.HumanoidStateType.GettingUp
                or newState == Enum.HumanoidStateType.PlatformStanding) then
            task.defer(cancelRecovery, character, humanoid)
        end
    end))

    local animator = humanoid:FindFirstChildOfClass("Animator")
        or humanoid:WaitForChild("Animator", 5)
    if animator then
        table.insert(antiStunConnections, animator.AnimationPlayed:Connect(function(track)
            local animationType = getRecoveryAnimationType(track)
            if (animationType == "stun" and AntiStun)
                or (animationType == "ragdoll" and AntiRagdoll) then
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
    if namecallHooked then return end
    namecallHooked = true

    local success, result = pcall(function()
        oldGameNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()

            if STUN_DEBUG_EVENTS and (method == "FireServer" or method == "InvokeServer") then
                stunDebugLog("REMOTE OUT", method, self, { ... })
            end

            -- ── Stamina ────────────────────────────────────────────── --
            if InfiniteStamina and self == cachedCharacter then
                if method == "SetAttribute" then
                    local attr = select(1, ...)
                    if attr == "Stamina" then
                        return oldGameNamecall(self, "Stamina", 100)
                    end
                elseif method == "GetAttribute" then
                    local attr = select(1, ...)
                    if attr == "Stamina" then
                        return 100
                    end
                end
            end

            if InfiniteStamina and method == "FireServer" and SprintRemote and self == SprintRemote then
                local arg1 = select(1, ...)
                if type(arg1) == "table" and arg1.Stamina ~= nil then
                    arg1.Stamina = 100
                end
                return oldGameNamecall(self, ...)
            end

            -- ── No Dodge Cooldown (manual Q, no auto-loop) ──────────── --
            if NoDodgeCooldown then
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
                        return oldGameNamecall(self, "CombatActionToken", 1)
                    end
                elseif method == "FireServer" and DodgeCooldownTime > 0 and self == RemotesServer then
                    local arg1 = select(1, ...)
                    if type(arg1) == "table"
                        and arg1.Type == "Combat"
                        and arg1.Action == "Evasive" then
                        local now = os.clock()
                        if now - lastDodgeTime < DodgeCooldownTime then
                            return
                        end
                        lastDodgeTime = now
                    end
                end
            end

            -- ── Independent Anti-Stun / Anti-Ragdoll ───────────────── --
            if (AntiStun or AntiRagdoll) and method == "GetAttribute" and self == cachedCharacter then
                local attr = select(1, ...)
                if (AntiStun and stunAttrs[attr])
                    or (AntiRagdoll and ragdollAttrs[attr]) then
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

            return oldGameNamecall(self, ...)
        end)
    end)

    if not success then
        warn("[BagahHub] __namecall hook failed:", result)
        namecallHooked = false
    else
        print("[BagahHub] Unified namecall hook active (stamina + dodge)")
    end
end

local function setInfiniteStamina(value)
    InfiniteStamina = value
    if value then hookNamecall() end
end

local function setNoDodgeCooldown(value)
    NoDodgeCooldown = value
    if value then
        hookNamecall()
    end
end

local function updateRecoveryProtection()
    if AntiStun or AntiRagdoll then
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
    AntiStun = value
    updateRecoveryProtection()
end

local function setAntiRagdoll(value)
    AntiRagdoll = value
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
    if InfiniteStamina or NoDodgeCooldown or AntiStun or AntiRagdoll or STUN_DEBUG_EVENTS then
        namecallHooked = false
        hookNamecall()
    end
    if AntiStun or AntiRagdoll then
        task.defer(attachAntiStun, character)
    end
    if STUN_DEBUG_EVENTS then
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

    return math.clamp(duration + 0.28, 0.25, 5.0)
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
    local lane = rhythmLane(note)
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
    }
    rhythmDebug("NOTE", "registered", note, "lane=", lane,
        "pos=", note.AbsolutePosition, "size=", note.AbsoluteSize)
end

local function rhythmResetRecycled(note, data)
    local lane = rhythmLane(note)
    if not lane then return end
    data.lane = lane
    data.key = Rhythm.Keys[lane]
    data.pressed = false
    data.parent = note.Parent
    data.wasInactive = false
    data.lastY = nil
    data.lastAt = nil
    data.holdDuration = nil
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

local rhythmDebugRootReported = nil

local rhythmConnection = nil
local lastRhythmScan = 0
local RHYTHM_SCAN_INTERVAL = 0.5 -- scan for UI root every 0.5s, not every frame

local function rhythmStep()
    if not Rhythm.Enabled then return end
    local now = os.clock()
    -- Only do expensive PlayerGui:GetDescendants() scan periodically or when root is missing
    if not Rhythm.Root or now - lastRhythmScan >= RHYTHM_SCAN_INTERVAL then
        lastRhythmScan = now
        rhythmScan()
    end
    if Rhythm.DebugEnabled and Rhythm.Root
        and rhythmDebugRootReported ~= Rhythm.Root then
        rhythmDebugRootReported = Rhythm.Root
        rhythmDebugStructure()
    end
    for note, data in pairs(Rhythm.Active) do
        if not note.Parent then
            Rhythm.Active[note] = nil
        elseif note.Parent.Name == "OffscreenPool" or not note.Visible then
            data.wasInactive = true
            data.lastY = nil; data.lastAt = nil
            if data.pressed then data.pressed = false end
        elseif not data.pressed and Rhythm.Receptors[data.lane] then
            data.tail = note:FindFirstChild("Tail")
            data.isHold = data.tail and data.tail:IsA("GuiObject")
                and data.tail.Visible and data.tail.AbsoluteSize.Y > 1 or false
            if data.wasInactive or data.parent ~= note.Parent then
                rhythmResetRecycled(note, data)
            end
            local receptor = Rhythm.Receptors[data.lane]
            local y = note.AbsolutePosition.Y + note.AbsoluteSize.Y / 2
            local target = receptor.AbsolutePosition.Y + receptor.AbsoluteSize.Y / 2
            local velocity = data.lastY and data.lastAt and (y - data.lastY) / (now - data.lastAt) or nil
            if velocity and math.abs(y - data.lastY) >= 120 then
                velocity = nil
                data.lastY = y
                data.lastAt = now
            end
            if data.isHold and velocity and velocity > 1 then
                data.holdDuration = rhythmGetHoldDuration(note, receptor, velocity)
            end
            data.lastY, data.lastAt = y, now
            if velocity and velocity > 1 then
                local eta = (target - y) / velocity
                if eta >= -0.004 and eta <= Rhythm.HitWindow and now - (Rhythm.LastPress[data.lane] or 0) >= Rhythm.MinInterval then
                    data.pressed = true
                    Rhythm.LastPress[data.lane] = now
                    local leadTime = Rhythm.TouchMode
                        and (Rhythm.LaneCount >= 4 and 0.035 or Rhythm.TouchLeadTime)
                        or 0.008
                    local delay = math.max(0, eta - leadTime)
                    local scheduledHold = data.isHold and data.holdDuration or nil
                    local generation = Rhythm.Generation
                    rhythmDebug("HIT", "lane=", data.lane, "eta=", string.format("%.4f", eta),
                        "velocity=", string.format("%.2f", velocity), "hold=", scheduledHold ~= nil,
                        "noteY=", string.format("%.1f", y), "targetY=", string.format("%.1f", target))
                    task.delay(delay, function()
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
    end
end

local function setRhythmEnabled(value)
    Rhythm.Enabled = value
    Rhythm.Generation += 1
    if not value then
        rhythmReleaseAll()
        table.clear(Rhythm.Active)
        -- Disconnect RenderStepped when disabled (saves mobile perf)
        if rhythmConnection then
            rhythmConnection:Disconnect()
            rhythmConnection = nil
        end
    else
        lastRhythmScan = 0 -- force immediate scan
        rhythmScan()
        -- Only connect RenderStepped when actually enabled
        if not rhythmConnection then
            rhythmConnection = RunService.RenderStepped:Connect(rhythmStep)
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
        task.delay(0.3, rhythmScan)
    end
end)
PlayerGui.ChildRemoved:Connect(function(child)
    if child.Name == "RhythmServiceUI" then
        Rhythm.Generation += 1
        Rhythm.Root = nil; table.clear(Rhythm.Active); rhythmReleaseAll()
    end
end)

local AutoRespawnEnabled = false
local autoRespawnConnection = nil
local autoRespawnTriggered = false
local waitingForRevive = false

local function arDebug(...)
    if not AR_DEBUG then return end
    local parts = {}
    for _, v in ipairs({ ... }) do
        table.insert(parts, tostring(v))
    end
    local msg = table.concat(parts, " ")
    print("[AutoRespawn]", msg)
    table.insert(AR_DEBUG_TIMELINE, os.date("!%H:%M:%S") .. " " .. msg)
    if #AR_DEBUG_TIMELINE > 200 then
        table.remove(AR_DEBUG_TIMELINE, 1)
    end
end

local function triggerAutoRespawn()
    if autoRespawnTriggered then
        arDebug("already triggered, skipping")
        return
    end
    autoRespawnTriggered = true
    arDebug("trigger called")
    local char = LocalPlayer.Character
    if not char then
        arDebug("no character, aborting")
        autoRespawnTriggered = false
        return
    end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        arDebug("no HRP, aborting")
        autoRespawnTriggered = false
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
    if not character or not AutoRespawnEnabled then return end
    arDebug("attaching to character", character.Name)
    if autoRespawnConnection then autoRespawnConnection:Disconnect() end
    autoRespawnConnection = character.AttributeChanged:Connect(function(attr)
        local val = character:GetAttribute(attr)
        arDebug("AttributeChanged:", attr, "=", tostring(val))
        if attr == "Downed" and val == true then
            arDebug("knocked, waiting for revive...")
            waitingForRevive = true
        end
        if attr == "Downed" and val == false and waitingForRevive then
            arDebug("revived! triggering respawn...")
            waitingForRevive = false
            task.wait(0.1)
            task.defer(triggerAutoRespawn)
        end
    end)
end

local function detachAutoRespawn()
    if autoRespawnConnection then
        autoRespawnConnection:Disconnect()
        autoRespawnConnection = nil
    end
end

local FlyEnabled = false
local FlySpeed = 50
local flyBodyVelocity, flyBodyGyro, flyConnection = nil, nil, nil
local flyHumanoid, flyRootPart = nil, nil -- cached refs

local function startFly()
    local char = LocalPlayer.Character
    if not char then return end
    local rootPart = char:FindFirstChild("HumanoidRootPart")
    local humanoid = char:FindFirstChild("Humanoid")
    if not rootPart or not humanoid then return end
    FlyEnabled = true
    flyHumanoid = humanoid
    flyRootPart = rootPart
    flyBodyVelocity = Instance.new("BodyVelocity")
    flyBodyVelocity.MaxForce = Vector3.new(400000, 400000, 400000)
    flyBodyVelocity.Velocity = Vector3.zero
    flyBodyVelocity.Parent = rootPart
    flyBodyGyro = Instance.new("BodyGyro")
    flyBodyGyro.MaxTorque = Vector3.new(400000, 400000, 400000)
    flyBodyGyro.CFrame = rootPart.CFrame
    flyBodyGyro.Parent = rootPart
    humanoid.PlatformStand = true
    if not flyConnection then
        flyConnection = RunService.Heartbeat:Connect(function()
            if not FlyEnabled or not flyBodyVelocity or not flyBodyGyro then return end
            if not flyHumanoid or not flyHumanoid.Parent then return end
            local camera = workspace.CurrentCamera
            local direction = Vector3.zero
            local moveDir = flyHumanoid.MoveDirection
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
            flyBodyVelocity.Velocity = direction.Magnitude > 0 and direction.Unit * FlySpeed or Vector3.zero
            flyBodyGyro.CFrame = camera.CFrame
        end)
    end
end

local function stopFly()
    FlyEnabled = false
    if flyConnection then
        flyConnection:Disconnect(); flyConnection = nil
    end
    if flyBodyVelocity then
        flyBodyVelocity:Destroy(); flyBodyVelocity = nil
    end
    if flyBodyGyro then
        flyBodyGyro:Destroy(); flyBodyGyro = nil
    end
    if flyHumanoid and flyHumanoid.Parent then
        flyHumanoid.PlatformStand = false
    end
    flyHumanoid = nil
    flyRootPart = nil
end

local NoclipEnabled = false
local noclipConnection = nil
local noclipParts = {} -- cached BaseParts, rebuilt on CharacterAdded

local function noclipCacheParts(character)
    table.clear(noclipParts)
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            table.insert(noclipParts, part)
        end
    end
end

local function enableNoclip()
    if noclipConnection then return end
    noclipCacheParts(LocalPlayer.Character)
    noclipConnection = RunService.Stepped:Connect(function()
        for _, part in ipairs(noclipParts) do
            if part.Parent then part.CanCollide = false end
        end
    end)
end

local function disableNoclip()
    if noclipConnection then
        noclipConnection:Disconnect(); noclipConnection = nil
    end
    for _, part in ipairs(noclipParts) do
        pcall(function() part.CanCollide = true end)
    end
    table.clear(noclipParts)
end

LocalPlayer.CharacterAdded:Connect(function(character)
    local wasFlying = FlyEnabled
    local wasNoclipping = NoclipEnabled
    if FlyEnabled then stopFly() end
    if NoclipEnabled then disableNoclip() end
    if wasFlying then
        task.wait(0.5)
        startFly()
    end
    if wasNoclipping then
        task.wait(0.3)
        enableNoclip()
    end
    if AutoRespawnEnabled then
        autoRespawnTriggered = false
        waitingForRevive = false
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
        DodgeCooldownTime = value
        lastDodgeTime = 0 -- reset throttle so new value applies immediately
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
        FlySpeed = value
    end
})

PlayerTab:Divider()

PlayerTab:Toggle({
    Title = "No Clip",
    Description = "Walk through walls and objects",
    Default = false,
    Callback = function(value)
        NoclipEnabled = value
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
        AutoRespawnEnabled = value
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

local teleportPlayerName = nil
local teleportDropdown = nil

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
    if teleportDropdown then
        local list = getPlayerList()
        teleportDropdown:Refresh(list)
        if list[1] and list[1] ~= "No players" then
            if not teleportPlayerName or not table.find(list, teleportPlayerName) then
                teleportPlayerName = list[1]
                teleportDropdown:Select(teleportPlayerName)
            end
        else
            teleportPlayerName = nil
        end
    end
end

teleportDropdown = PlayerTab:Dropdown({
    Title = "Select Player",
    Flag = "TeleportPlayerDropdown",
    Values = getPlayerList(),
    Value = getPlayerList()[1] or "No players",
    Callback = function(value)
        if value ~= "No players" then
            teleportPlayerName = value
        end
    end
})

PlayerTab:Button({
    Title = "Teleport to Player",
    Description = "Teleport to the selected player",
    Callback = function()
        if not teleportPlayerName then
            notify("Teleport", "No player selected", 2)
            return
        end
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then
            notify("Teleport", "Character not found", 2)
            return
        end
        local target = Players:FindFirstChild(teleportPlayerName)
        if not target or not target.Character or not target.Character:FindFirstChild("HumanoidRootPart") then
            notify("Teleport", teleportPlayerName .. " not found", 2)
            refreshPlayerDropdown()
            return
        end
        hrp.CFrame = target.Character.HumanoidRootPart.CFrame + Vector3.new(0, 3, 0)
        notify("Teleport", "Teleported to " .. teleportPlayerName, 2)
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
            DEBUG_EVENTS = value
            if value then
                DebugStartedAt = os.clock()
                table.clear(DebugTimeline)
                debugLog("[BagahHub STATE]", "Auto Parry debug enabled")
            end
        end
    })

    DebugTab:Toggle({
        Title = "Stun/Ragdoll Debug Log",
        Description = "Record attributes, states, animations, properties, and outgoing remotes; press F8 to copy",
        Default = false,
        Callback = function(value)
            STUN_DEBUG_EVENTS = value
            if value then
                StunDebugStartedAt = os.clock()
                table.clear(StunDebugTimeline)
                hookNamecall()
                attachStunDebug(LocalPlayer.Character)
                stunDebugLog("STATE", "enabled", "AntiStun=", AntiStun, "AntiRagdoll=", AntiRagdoll)
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

    DebugTab:Divider()

    DebugTab:Toggle({
        Title = "Auto Respawn Debug",
        Description = "Log knock detection and teleport trigger events",
        Default = false,
        Callback = function(value)
            AR_DEBUG = value
            if value then
                table.clear(AR_DEBUG_TIMELINE)
                arDebug("debug enabled")
                arDebug("AutoRespawnEnabled=" .. tostring(AutoRespawnEnabled))
            end
        end
    })
end

-- ========================================================================= --
--                                 ESP SUITE                                  --
-- ========================================================================= --
local ESP = {
    ShowBox        = false,
    ShowHealth     = false,
    ShowStamina    = false,
    ShowTracer     = false,
    ShowInfo       = false,
    ShowHighlight  = false,
    MaxDistance    = 200,
    BoxColor       = Color3.fromRGB(255, 255, 255),
    TracerColor    = Color3.fromRGB(255, 255, 255),
    InfoColor      = Color3.fromRGB(255, 255, 255),
    HighlightColor = Color3.fromRGB(255, 60, 60),
    Generation     = 0,
}

local espObjects = {}
local espHighlights = {}

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
    for _, objects in pairs(espObjects) do
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
    for model, _ in pairs(espHighlights) do
        table.insert(models, model)
    end
    for _, model in ipairs(models) do
        local highlight = espHighlights[model]
        if highlight then
            pcall(function()
                highlight.Enabled = false
                highlight:Destroy()
            end)
        end
        espHighlights[model] = nil
    end
end

local espCharCache = {} -- model -> { HRP, Humanoid, Head, Name }

local function espGetCharacter(model)
    if not model or not model:IsA("Model") then return nil end
    if model == LocalPlayer.Character then return nil end

    -- Return cached refs if still valid (avoids FindFirstChild per frame)
    local cached = espCharCache[model]
    if cached and cached.HRP.Parent == model and cached.Humanoid.Parent == model then
        if cached.Humanoid.Health <= 0 then return nil end
        return cached
    end

    local hrp = model:FindFirstChild("HumanoidRootPart")
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then
        espCharCache[model] = nil
        return nil
    end

    local data = { Model = model, HRP = hrp, Humanoid = hum, Head = model:FindFirstChild("Head"), Name = model.Name }
    espCharCache[model] = data
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
    local objs = espObjects[model]
    if objs then
        for _, d in pairs(objs) do
            espRemoveDrawing(d)
        end
        espObjects[model] = nil
    end
    local hl = espHighlights[model]
    if hl then
        pcall(function()
            hl.Enabled = false
            hl:Destroy()
        end)
        espHighlights[model] = nil
    end
end

local espFrameLocalRoot = nil -- cached once per frame in espRender()

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
    local dist = espFrameLocalRoot and (espFrameLocalRoot.Position - char.HRP.Position).Magnitude or math.huge
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

    local objs = espObjects[model]
    if not objs then
        objs = {}
        espObjects[model] = objs
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
        local hl = espHighlights[model]
        if not hl then
            hl = Instance.new("Highlight")
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.FillTransparency = 0.5
            espHighlights[model] = hl
        end
        hl.Parent = model
        hl.FillColor = ESP.HighlightColor
        hl.OutlineColor = ESP.HighlightColor
        hl.Enabled = true
    else
        local hl = espHighlights[model]
        if hl then
            hl.Enabled = false
        end
    end
end

local espWorkspacePlayers = nil
local espWorkspaceNpcs = nil

local function espRender()
    if not espHasEnabledFeature() then return end
    local gen = ESP.Generation

    -- Cache workspace containers (rarely change)
    if not espWorkspacePlayers or not espWorkspacePlayers.Parent then
        espWorkspacePlayers = workspace:FindFirstChild("Players")
    end
    if not espWorkspaceNpcs or not espWorkspaceNpcs.Parent then
        espWorkspaceNpcs = workspace:FindFirstChild("NPCs")
    end

    -- Cache local root once per frame (not per model)
    local localChar = LocalPlayer.Character
    espFrameLocalRoot = localChar and localChar:FindFirstChild("HumanoidRootPart")

    -- Single pass: update models + track active set
    local active = {}

    if espWorkspacePlayers then
        for _, model in espWorkspacePlayers:GetChildren() do
            if ESP.Generation ~= gen then return end
            active[model] = true
            espUpdateModel(model)
        end
    end

    if espWorkspaceNpcs then
        for _, model in espWorkspaceNpcs:GetChildren() do
            if ESP.Generation ~= gen then return end
            active[model] = true
            espUpdateModel(model)
        end
    end

    if ESP.Generation ~= gen then return end

    -- Cleanup stale models (no second GetChildren needed)
    local stale = {}
    for model, _ in pairs(espObjects) do
        if not active[model] then table.insert(stale, model) end
    end
    for _, model in ipairs(stale) do
        if ESP.Generation ~= gen then return end
        espClearModel(model)
        espCharCache[model] = nil
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

local hudShowHealth = false
local hudShowStamina = false
local hudObjects = {}

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

local hudConnections = {}

local function hudUpdateHealth()
    if not (hudShowHealth and hudObjects.health) then return end
    local char = LocalPlayer.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local hpPercent = math.floor((hum.Health / hum.MaxHealth) * 100)
    local color = hpPercent > 50 and Color3.fromRGB(80, 255, 80)
        or hpPercent > 25 and Color3.fromRGB(255, 200, 0)
        or Color3.fromRGB(255, 60, 60)
    hudUpdateBar(hudObjects.health, hpPercent, color, "HP")
end

local function hudUpdateStamina()
    if not (hudShowStamina and hudObjects.stamina) then return end
    local char = LocalPlayer.Character
    if not char then return end
    local stamina = math.floor(char:GetAttribute("Stamina") or 100)
    local color = stamina > 50 and Color3.fromRGB(80, 180, 255)
        or stamina > 25 and Color3.fromRGB(255, 200, 0)
        or Color3.fromRGB(255, 60, 60)
    hudUpdateBar(hudObjects.stamina, stamina, color, "STA")
end

local function startHud()
    -- Disconnect old connections
    for _, conn in ipairs(hudConnections) do conn:Disconnect() end
    table.clear(hudConnections)

    if hudShowHealth then
        if not hudObjects.health then hudObjects.health = hudCreateBar(-20) end
        local char = LocalPlayer.Character
        if char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                hudUpdateHealth()
                table.insert(hudConnections, hum:GetPropertyChangedSignal("Health"):Connect(hudUpdateHealth))
                table.insert(hudConnections, hum:GetPropertyChangedSignal("MaxHealth"):Connect(hudUpdateHealth))
            end
        end
    end
    if hudShowStamina then
        if not hudObjects.stamina then hudObjects.stamina = hudCreateBar(0) end
        local char = LocalPlayer.Character
        if char then
            hudUpdateStamina()
            table.insert(hudConnections, char:GetAttributeChangedSignal("Stamina"):Connect(hudUpdateStamina))
        end
    end
end

local function stopHud()
    if not hudShowHealth and not hudShowStamina then
        for _, conn in ipairs(hudConnections) do conn:Disconnect() end
        table.clear(hudConnections)
        for _, bar in pairs(hudObjects) do hudRemoveBar(bar) end
        hudObjects = {}
    end
end

VisualTab:Toggle({
    Title = "Show Health",
    Description = "Health bar at bottom-center of screen",
    Default = false,
    Callback = function(value)
        hudShowHealth = value
        if value then
            if not hudObjects.health then hudObjects.health = hudCreateBar(-20) end
            startHud()
        else
            hudRemoveBar(hudObjects.health)
            hudObjects.health = nil
            stopHud()
        end
    end
})

VisualTab:Toggle({
    Title = "Show Stamina",
    Description = "Stamina bar at bottom-center of screen",
    Default = false,
    Callback = function(value)
        hudShowStamina = value
        if value then
            if not hudObjects.stamina then hudObjects.stamina = hudCreateBar(0) end
            startHud()
        else
            hudRemoveBar(hudObjects.stamina)
            hudObjects.stamina = nil
            stopHud()
        end
    end
})


local AntiAfkEnabled = false
local antiAfkConnection = nil

local function startAntiAfk()
    if antiAfkConnection then return end
    antiAfkConnection = LocalPlayer.Idled:Connect(function()
        VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        task.wait(1)
        VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    end)
end

local function stopAntiAfk()
    if antiAfkConnection then
        antiAfkConnection:Disconnect()
        antiAfkConnection = nil
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

MiscTab:Toggle({
    Title = "Anti AFK",
    Description = "Prevent auto-kick by simulating input when idle",
    Default = false,
    Callback = function(value)
        AntiAfkEnabled = value
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

local placeId = game.PlaceId
local jobId = game.JobId
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local function getServerLink()
    return string.format("https://www.roblox.com/games/start?placeId=%d&jobId=%s", placeId, jobId)
end

local ServerTab = Window:Tab({ Icon = "server", Title = "Server" })

ServerTab:Section({ Title = "Server Info", TextSize = 20 })
ServerTab:Divider()

ServerTab:Paragraph({
    Title = "Server ID",
    Desc = jobId
})

ServerTab:Paragraph({
    Title = "Place ID",
    Desc = tostring(placeId)
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
        TeleportService:Teleport(game.PlaceId, LocalPlayer)
    end
})


ServerTab:Button({
    Title = "Server Hop",
    Desc = "Join a random server with 5+ players",
    Icon = "shuffle",
    Callback = function()
        local success, servers = pcall(function()
            return HttpService:JSONDecode(game:HttpGet("https://games.roblox.com/v1/games/" ..
                placeId .. "/servers/Public?sortOrder=Asc&limit=100"))
        end)
        if success and servers and servers.data and #servers.data > 0 then
            local filteredServers = {}
            for _, server in ipairs(servers.data) do
                if server.playing >= 5 then table.insert(filteredServers, server) end
            end
            if #filteredServers > 0 then
                local randomServer = filteredServers[math.random(1, #filteredServers)]
                TeleportService:TeleportToPlaceInstance(placeId, randomServer.id, LocalPlayer)
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
            return HttpService:JSONDecode(game:HttpGet("https://games.roblox.com/v1/games/" ..
                placeId .. "/servers/Public?sortOrder=Asc&limit=100"))
        end)
        if success and servers and servers.data and #servers.data > 0 then
            table.sort(servers.data, function(a, b) return a.playing < b.playing end)
            if servers.data[1] then
                TeleportService:TeleportToPlaceInstance(placeId, servers.data[1].id, LocalPlayer)
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
