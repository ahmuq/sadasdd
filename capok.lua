-- Obsidian UI adapter: retains the existing Evade control calls.
local Library = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/Library.lua"))()
local SaveManager = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/addons/SaveManager.lua"))()
Library.ForceCheckbox = false
Library.ShowToggleFrameInKeybinds = true
Library.Scheme.AccentColor = Color3.fromRGB(250, 204, 21)

local ObsidianWindow = Library:CreateWindow({
    Title = "Bagah Hub - Evade",
    Footer = "Bagah Projects | Evade v1.8.2",
    NotifySide = "Right",
    ShowCustomCursor = false,
})

local controlIndex = 0
local function nextControlIndex(prefix)
    controlIndex += 1
    return prefix .. controlIndex
end

local function sliderRounding(step)
    local decimal = tostring(step or 1):match("%.(%d+)")
    return decimal and #decimal or 0
end

local function createAdapterTab(info)
    local rawTab = ObsidianWindow:AddTab(info.Title, info.Icon)
    local adapter = { Raw = rawTab, Group = nil, Left = true }
    local function ensureGroup()
        if not adapter.Group then adapter.Group = rawTab:AddLeftGroupbox("General") end
        return adapter.Group
    end

    function adapter:Section(section)
        local title = section.Title or "General"
        self.Group = self.Left and rawTab:AddLeftGroupbox(title) or rawTab:AddRightGroupbox(title)
        self.Left = not self.Left
    end

    function adapter:Divider() ensureGroup():AddDivider() end

    function adapter:Space() ensureGroup():AddDivider() end

    function adapter:Toggle(options)
        local raw = ensureGroup():AddToggle(options.Flag or nextControlIndex("Toggle"), {
            Text = options.Title,
            Tooltip = options.Desc or options.Description,
            Default = options.Value ~= nil and options.Value or options.Default or false,
            Callback = options.Callback,
        })
        return { Set = function(_, value) raw:SetValue(value) end }
    end

    function adapter:Slider(options)
        local value = options.Value or {}
        return ensureGroup():AddSlider(options.Flag or nextControlIndex("Slider"), {
            Text = options.Title,
            Tooltip = options.Desc or options.Description,
            Default = value.Default or value.Min or 0,
            Min = value.Min or 0,
            Max = value.Max or 100,
            Rounding = sliderRounding(options.Step or value.Step),
            Callback = options.Callback,
        })
    end

    function adapter:Dropdown(options)
        local raw = ensureGroup():AddDropdown(options.Flag or nextControlIndex("Dropdown"), {
            Text = options.Title,
            Tooltip = options.Desc or options.Description,
            Values = options.Values or {},
            Default = options.Value,
            Multi = false,
            Searchable = options.SearchBarEnabled ~= false,
            Callback = options.Callback,
        })
        return {
            Refresh = function(_, values, value)
                raw:SetValues(values); if value then raw:SetValue(value) end
            end,
            Select = function(_, value) raw:SetValue(value) end,
        }
    end

    function adapter:Input(options)
        local raw = ensureGroup():AddInput(options.Flag or nextControlIndex("Input"), {
            Text = options.Title,
            Tooltip = options.Desc or options.Description,
            Default = options.Value or options.Default or "",
            Placeholder = options.Placeholder,
            Numeric = options.Numeric or false,
            Finished = options.Finished == true,
            Callback = options.Callback,
        })
        return { Set = function(_, value) raw:SetValue(value) end }
    end

    function adapter:Button(options)
        return ensureGroup():AddButton({
            Text = options.Title, Tooltip = options.Desc or options.Description, Func = options.Callback,
        })
    end

    function adapter:Paragraph(options)
        local title = options.Title or ""
        local raw = ensureGroup():AddLabel(title .. "\n" .. (options.Desc or options.Description or ""), true)
        return { SetDesc = function(_, value) raw:SetText(title .. "\n" .. value) end }
    end

    return adapter
end

local Window = {
    Tabs = {},
    Tab = function(self, info)
        local tab = createAdapterTab(info)
        table.insert(self.Tabs, tab)
        return tab
    end,
    SelectTab = function(self, index)
        local tab = self.Tabs[index]
        if tab and tab.Raw and tab.Raw.Show then tab.Raw:Show() end
    end,
}
function Window:SetToggleKey(key)
    local picker = Library.Options.EvadeMenuKeybind
    if not picker then
        local tab = ObsidianWindow:AddTab("UI Settings", "settings")
        local group = tab:AddLeftGroupbox("Menu")
        group:AddLabel("Menu Keybind"):AddKeyPicker("EvadeMenuKeybind", {
            Default = key.Name,
            NoUI = true,
            Text = "Menu Keybind",
        })
        picker = Library.Options.EvadeMenuKeybind
        Library.ToggleKeybind = picker
    else
        picker:SetValue(key.Name)
    end
end

SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetFolder("BagahHubEvade")
SaveManager:SetSubFolder("Evade-" .. tostring(game.PlaceId))

local ObsidianUI = {
    TransparencyValue = 0,
    Notify = function(_, options)
        Library:Notify({
            Title = options.Title or "Bagah Hub",
            Description = options.Content or "",
            Time = options
                .Duration or 2
        })
    end,
}

-- Keybind Configuration
local keybindFile = "BagahHub_Evade_Keybind.txt"

local function loadKeybind()
    if isfile(keybindFile) then
        local savedKey = readfile(keybindFile)
        for _, key in pairs(Enum.KeyCode:GetEnumItems()) do
            if tostring(key) == savedKey then
                return key
            end
        end
    end
    return Enum.KeyCode.RightControl
end

local initialKey = loadKeybind()
Window:SetToggleKey(initialKey)

-- -------------------------------------------------------------------------- --
--                                  Services                                  --
-- -------------------------------------------------------------------------- --
local RunService         = game:GetService("RunService")
local Players            = game:GetService("Players")
local player             = Players.LocalPlayer
local PlayerGui          = player:WaitForChild("PlayerGui")
local UserInputService   = game:GetService("UserInputService")
local TeleportService    = game:GetService("TeleportService")
local HttpService        = game:GetService("HttpService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local InsertService      = game:GetService("InsertService")
local TweenService       = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local VirtualUser        = game:GetService("VirtualUser")
local placeId            = game.PlaceId
local jobId              = game.JobId
local ServerStateRegistryService
pcall(function()
    ServerStateRegistryService = require(ReplicatedStorage:WaitForChild("Services"):WaitForChild("Data")
        :WaitForChild("ServerStateRegistryService"))
end)

-- -------------------------------------------------------------------------- --
--                            NOTIFICATION FUNCTION                           --
-- -------------------------------------------------------------------------- --

local function Success(title, message, duration)
    ObsidianUI:Notify({
        Title = title,
        Content = message,
        Duration = duration,
        Icon = "circle-check"
    })
end

local function Error(title, message, duration)
    ObsidianUI:Notify({
        Title = title,
        Content = message,
        Duration = duration,
        Icon = "ban"
    })
end

local function Info(title, message, duration)
    ObsidianUI:Notify({
        Title = title,
        Content = message,
        Duration = duration,
        Icon = "info"
    })
end

local function Warning(title, message, duration)
    ObsidianUI:Notify({
        Title = title,
        Content = message,
        Duration = duration,
        Icon = "triangle-alert"
    })
end


-- -------------------------------------------------------------------------- --
--                                 TAB PLAYER                                 --
-- -------------------------------------------------------------------------- --

local State = {
    Player = {
        FlySpeed = 50,
        FlyEnabled = false,
        NoclipEnabled = false,
        SpeedValue = 16,
        SpeedEnabled = false,
        JumpPower = 50,
        BhopHoldEnabled = false,
        BhopToggleEnabled = false
    }
}


local featureStates = {
    AntiAFK = true,
    TimerDisplay = false
}


--OTHER REMOTES

local ChangeSettingRemote = ReplicatedStorage.Shared.UserData.Events.Requests:WaitForChild("SetSetting")
local UpdatedEvent = ReplicatedStorage.Shared.UserData.Events.Channels:WaitForChild("Settings")

-- =========================== GAME STATE TRACKER =========================== --
-- Evade update besar: workspace.Game.Stats dihapus, ganti ke remote event
local GameState = {}
local gameStateListeners = {}

local function initGameState()
    local ev = ReplicatedStorage:FindFirstChild("Events")
    if not ev then return end
    local stateReg = ev:FindFirstChild("UpdateServerStateRegistry")
    if not stateReg then return end

    stateReg.OnClientEvent:Connect(function(key, value)
        GameState[key] = value
        local listeners = gameStateListeners[key]
        if listeners then
            for _, cb in ipairs(listeners) do
                task.spawn(cb, key, value)
            end
        end
        listeners = gameStateListeners["*"]
        if listeners then
            for _, cb in ipairs(listeners) do
                task.spawn(cb, key, value)
            end
        end
    end)
end

function GameState.Get(key, default)
    return GameState[key] ~= nil and GameState[key] or default
end

function GameState.OnChange(key, callback)
    if not gameStateListeners[key] then
        gameStateListeners[key] = {}
    end
    table.insert(gameStateListeners[key], callback)
end

initGameState()

-- ----------------------------- FLYING FUNCTION ---------------------------- --

local FlyingModule = (function()
    local flying = false
    local bodyVelocity, bodyGyro, flyLoop = nil, nil, nil
    local function startFlying()
        local char = player.Character
        if not char then return end
        local humanoid = char:WaitForChild("Humanoid")
        local rootPart = char:WaitForChild("HumanoidRootPart")
        if not humanoid or not rootPart then return end
        flying = true
        bodyVelocity = Instance.new("BodyVelocity")
        bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
        bodyVelocity.Velocity = Vector3.zero
        bodyVelocity.Parent = rootPart
        bodyGyro = Instance.new("BodyGyro")
        bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
        bodyGyro.CFrame = rootPart.CFrame
        bodyGyro.Parent = rootPart
        humanoid.PlatformStand = true
    end
    local function stopFlying()
        flying = false
        if bodyVelocity then
            bodyVelocity:Destroy()
            bodyVelocity = nil
        end
        if bodyGyro then
            bodyGyro:Destroy()
            bodyGyro = nil
        end
        if player.Character then
            local humanoid = player.Character:FindFirstChild("Humanoid")
            if humanoid then humanoid.PlatformStand = false end
        end
    end


    local function updateFly()
        if not flying or not bodyVelocity or not bodyGyro then return end
        local char = player.Character
        if not char then return end
        local humanoid = char:FindFirstChild("Humanoid")
        if not humanoid then return end
        local camera = workspace.CurrentCamera
        local direction = Vector3.zero
        local moveDir = humanoid.MoveDirection
        if moveDir.Magnitude > 0 then
            local forward = camera.CFrame.LookVector
            local right = camera.CFrame.RightVector
            direction = direction + (moveDir:Dot(forward) * forward + moveDir:Dot(right) * right).Unit
        end
        if game:GetService("UserInputService"):IsKeyDown(Enum.KeyCode.Space) then
            direction = direction + Vector3.new(0, 1, 0)
        end
        if game:GetService("UserInputService"):IsKeyDown(Enum.KeyCode.LeftShift) then
            direction = direction - Vector3.new(0, 1, 0)
        end
        bodyVelocity.Velocity = direction.Magnitude > 0 and direction.Unit * (State.Player.FlySpeed * 2) or Vector3.zero
        bodyGyro.CFrame = camera.CFrame
    end
    return {
        Start = function()
            startFlying()
            if not flyLoop then
                flyLoop = RunService.RenderStepped:Connect(updateFly)
            end
        end,
        Stop = function()
            if flyLoop then
                flyLoop:Disconnect()
                flyLoop = nil
            end
            stopFlying()
        end
    }
end)()

-- ---------------------------- NO CLIP FUNCTION ---------------------------- --

local NoclipModule = (function()
    local connection = nil
    local function enable()
        if connection then return end
        connection = RunService.Stepped:Connect(function()
            local char = player.Character
            if not char then return end
            for _, part in pairs(char:GetDescendants()) do
                if part:IsA("BasePart") then part.CanCollide = false end
            end
        end)
    end
    local function disable()
        if connection then
            connection:Disconnect()
            connection = nil
        end
        local char = player.Character
        if char then
            for _, part in pairs(char:GetDescendants()) do
                if part:IsA("BasePart") then part.CanCollide = true end
            end
        end
    end
    return { Enable = enable, Disable = disable }
end)()

-- ------------------------- CFRAME SPEED FUNCTION -------------------------- --

local CFrameSpeedModule = (function()
    local connection = nil
    local function start()
        if connection then return end
        connection = RunService.RenderStepped:Connect(function()
            local char = player.Character
            if not char then return end
            local humanoid = char:FindFirstChildOfClass("Humanoid")
            local rootPart = char:FindFirstChild("HumanoidRootPart")
            if not humanoid or not rootPart then return end

            local moveDir = humanoid.MoveDirection
            if moveDir.Magnitude > 0 then
                rootPart.CFrame = rootPart.CFrame + moveDir * math.max(State.Player.SpeedValue, 1) * 0.080
            end
        end)
    end
    local function stop()
        if connection then
            connection:Disconnect()
            connection = nil
        end
    end
    return { Start = start, Stop = stop }
end)()

-- ----------------------------- BHOP FUNCTION ------------------------------ --

local BhopModule = (function()
    local isHoldingSpace = false
    local stateConnection = nil
    local inputBeganConnection = nil
    local inputEndedConnection = nil
    local characterAddedConnection = nil

    local function connectBhop(humanoid)
        if stateConnection then
            stateConnection:Disconnect()
        end
        stateConnection = humanoid.StateChanged:Connect(function(_, newState)
            if newState == Enum.HumanoidStateType.Landed then
                if isHoldingSpace and State.Player.BhopHoldEnabled then
                    humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                end
            end
        end)
    end

    local function start()
        -- Input handling
        inputBeganConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
            if input.KeyCode == Enum.KeyCode.Space and not gameProcessed then
                isHoldingSpace = true
            end
        end)

        inputEndedConnection = UserInputService.InputEnded:Connect(function(input, gameProcessed)
            if input.KeyCode == Enum.KeyCode.Space then
                isHoldingSpace = false
            end
        end)

        -- Connect to current character
        if player.Character then
            local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
            if humanoid then
                connectBhop(humanoid)
            end
        end

        -- Reconnect on character respawn
        characterAddedConnection = player.CharacterAdded:Connect(function(character)
            local humanoid = character:WaitForChild("Humanoid")
            connectBhop(humanoid)
        end)
    end

    local function stop()
        isHoldingSpace = false

        if inputBeganConnection then
            inputBeganConnection:Disconnect()
            inputBeganConnection = nil
        end

        if inputEndedConnection then
            inputEndedConnection:Disconnect()
            inputEndedConnection = nil
        end

        if stateConnection then
            stateConnection:Disconnect()
            stateConnection = nil
        end

        if characterAddedConnection then
            characterAddedConnection:Disconnect()
            characterAddedConnection = nil
        end
    end

    return { Start = start, Stop = stop }
end)()

-- ----------------------- BHOP TOGGLE FUNCTION (AUTO) ---------------------- --

local BhopToggleModule = (function()
    local stateConnection = nil
    local characterAddedConnection = nil

    local function connectBhopToggle(humanoid)
        if stateConnection then
            stateConnection:Disconnect()
        end
        stateConnection = humanoid.StateChanged:Connect(function(_, newState)
            if newState == Enum.HumanoidStateType.Landed then
                if State.Player.BhopToggleEnabled then
                    task.wait(0.1) -- Small delay untuk stability
                    humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                end
            end
        end)
    end

    local function start()
        -- Connect to current character
        if player.Character then
            local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
            if humanoid then
                connectBhopToggle(humanoid)
            end
        end

        -- Reconnect on character respawn
        characterAddedConnection = player.CharacterAdded:Connect(function(character)
            local humanoid = character:WaitForChild("Humanoid")
            connectBhopToggle(humanoid)
        end)
    end

    local function stop()
        if stateConnection then
            stateConnection:Disconnect()
            stateConnection = nil
        end

        if characterAddedConnection then
            characterAddedConnection:Disconnect()
            characterAddedConnection = nil
        end
    end

    return { Start = start, Stop = stop }
end)()

-- ------------------------------- UI FUNCTION ------------------------------ --

local PlayerTab = Window:Tab({ Icon = "user", Title = "Player" })

PlayerTab:Section({ Title = "Movement Control", TextSize = 20 })
PlayerTab:Divider()

PlayerTab:Toggle({
    Title = "Fly",
    Flag = "FlyToggle",
    Desc = "Make your character flying",
    Value = State.Player.FlyEnabled,
    Callback = function(state)
        State.Player.FlyEnabled = state
        if state then
            FlyingModule.Start()
            Success("Fly Enabled", "You are now flying!", 2)
        else
            FlyingModule.Stop()
            Success("Fly Disabled", "Flying disabled", 2)
        end
    end
})

PlayerTab:Slider({
    Title = "Fly Speed",
    Flag = "FlySpeedSlider",
    Value = { Min = 10, Max = 200, Default = State.Player.FlySpeed },
    Callback = function(value)
        State.Player.FlySpeed = value
    end
})

PlayerTab:Space();

PlayerTab:Toggle({
    Title = "Noclip",
    Flag = "NoclipToggle",
    Desc = "Walk through walls (need higher speed)",
    Value = State.Player.NoclipEnabled,
    Callback = function(state)
        State.Player.NoclipEnabled = state
        if state then
            NoclipModule.Enable()
            Success("Noclip Enabled", "You can walk through walls", 2)
        else
            NoclipModule.Disable()
            Success("Noclip Disabled", "Noclip disabled", 2)
        end
    end
})

PlayerTab:Space();

PlayerTab:Toggle({
    Title = "CFrame Speed Boost",
    Flag = "CFrameSpeedToggle",
    Desc = "Movement speed boost",
    Value = State.Player.SpeedEnabled,
    Callback = function(state)
        State.Player.SpeedEnabled = state
        if state then
            CFrameSpeedModule.Start()
            Success("Speed Enabled", "CFrame speed boost activated!", 2)
        else
            CFrameSpeedModule.Stop()
            Success("Speed Disabled", "CFrame speed boost disabled", 2)
        end
    end
})

PlayerTab:Slider({
    Title = "Speed Value",
    Flag = "SpeedValueSlider",
    Value = { Min = 1, Max = 50, Default = State.Player.SpeedValue },
    Callback = function(value)
        State.Player.SpeedValue = value
    end
})

PlayerTab:Space();

PlayerTab:Toggle({
    Title = "Jump Boost",
    Flag = "JumpBoostToggle",
    Desc = "Enable custom jump power",
    Value = false,
    Callback = function(state)
        if player.Character and player.Character:FindFirstChildOfClass("Humanoid") then
            player.Character.Humanoid.UseJumpPower = state
        end
    end
})

PlayerTab:Slider({
    Title = "Jump Power",
    Flag = "JumpPowerSlider",
    Value = { Min = 0, Max = 1000, Default = 50 },
    Callback = function(value)
        State.Player.JumpPower = value
        if player.Character and player.Character:FindFirstChildOfClass("Humanoid") then
            player.Character.Humanoid.JumpPower = value
        end
    end
})

PlayerTab:Divider()
PlayerTab:Section({ Title = "Bunny Hop", TextSize = 18 })

PlayerTab:Toggle({
    Title = "Bunny Hop Hold",
    Flag = "BhopHoldToggle",
    Desc = "Hold space to bunny hop",
    Value = State.Player.BhopHoldEnabled,
    Callback = function(state)
        State.Player.BhopHoldEnabled = state
        if state then
            BhopModule.Start()
            Success("Bhop Hold Enabled", "Hold space to bunny hop!", 2)
        else
            BhopModule.Stop()
            Success("Bhop Hold Disabled", "Bhop hold disabled", 2)
        end
    end
})

PlayerTab:Toggle({
    Title = "Bunny Hop Toggle",
    Flag = "BhopToggleToggle",
    Desc = "Auto bunny hop without holding space",
    Value = State.Player.BhopToggleEnabled,
    Callback = function(state)
        State.Player.BhopToggleEnabled = state
        if state then
            BhopToggleModule.Start()
            Success("Bhop Auto Enabled", "Auto bunny hop activated!", 2)
        else
            BhopToggleModule.Stop()
            Success("Bhop Auto Disabled", "Auto bhop disabled", 2)
        end
    end
})


-- -------------------------------------------------------------------------- --
--                                   TAB ESP                                  --
-- -------------------------------------------------------------------------- --

-- ------------------------------ ESP VARIABLES ----------------------------- --

local NextbotBillboards = {}
local PlayerBillboards = {}
local TicketBillboards = {}
local playerTracerElements = {}
local botTracerElements = {}
local nextbotESPLoop = nil
local playerESPLoop = nil
local ticketESPLoop = nil
local playerTracerConnection = nil
local botTracerConnection = nil
local nextBotNames = {}

-- -------------------------- ESP HELPER FUNCTIONS -------------------------- --

if ReplicatedStorage:FindFirstChild("NPCs") then
    for _, npc in ipairs(ReplicatedStorage.NPCs:GetChildren()) do
        table.insert(nextBotNames, npc.Name)
    end
end

local function isNextbotModel(model)
    if not model or not model.Name then return false end
    for _, name in ipairs(nextBotNames) do
        if model.Name == name then return true end
    end
    return model.Name:lower():find("nextbot") or
        model.Name:lower():find("scp") or
        model.Name:lower():find("monster") or
        model.Name:lower():find("creep") or
        model.Name:lower():find("enemy") or
        model.Name:lower():find("zombie") or
        model.Name:lower():find("ghost") or
        model.Name:lower():find("demon")
end

local function getDistanceFromPlayer(targetPosition)
    if not player.Character or not player.Character:FindFirstChild("HumanoidRootPart") then
        return 0
    end
    local distance = (targetPosition - player.Character.HumanoidRootPart.Position).Magnitude
    return math.floor(distance)
end

function CreateBillboardESP(Name, Part, Color, TextSize)
    if not Part or Part:FindFirstChild(Name) then return nil end

    local BillboardGui = Instance.new("BillboardGui")
    local TextLabel = Instance.new("TextLabel")
    local TextStroke = Instance.new("UIStroke")

    BillboardGui.Parent = Part
    BillboardGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    BillboardGui.Name = Name
    BillboardGui.AlwaysOnTop = true
    BillboardGui.LightInfluence = 1
    BillboardGui.Size = UDim2.new(0, 200, 0, 50)
    BillboardGui.StudsOffset = Vector3.new(0, 3, 0)
    BillboardGui.MaxDistance = 1000

    TextLabel.Parent = BillboardGui
    TextLabel.BackgroundTransparency = 1
    TextLabel.Size = UDim2.new(1, 0, 1, 0)
    TextLabel.TextScaled = false
    TextLabel.Font = Enum.Font.SourceSansBold
    TextLabel.TextSize = TextSize or 14
    TextLabel.TextColor3 = Color or Color3.fromRGB(255, 255, 255)

    TextStroke.Parent = TextLabel
    TextStroke.Thickness = 2
    TextStroke.Color = Color3.new(0, 0, 0)

    return BillboardGui
end

function UpdateBillboardESP(Name, Part, NameText, Color, TextSize)
    if not Part then return false end

    local esp = Part:FindFirstChild(Name)
    if esp and esp:FindFirstChildOfClass("TextLabel") then
        local label = esp:FindFirstChildOfClass("TextLabel")

        if Color then
            label.TextColor3 = Color
        end

        if TextSize then
            label.TextSize = TextSize
        end

        local distance = getDistanceFromPlayer(Part.Position)
        local name = NameText or Part.Parent and Part.Parent.Name or Part.Name
        label.Text = string.format("%s [%dm]", name, distance)

        return true
    end
    return false
end

function DestroyBillboardESP(Name, Part)
    if not Part then return false end

    local esp = Part:FindFirstChild(Name)
    if esp then
        esp:Destroy()
        return true
    end

    return false
end

local function scanForNextbots()
    local nextbots = {}

    local playersFolder = workspace:FindFirstChild("Players")
    if playersFolder then
        for _, model in ipairs(playersFolder:GetChildren()) do
            if model:IsA("Model") and isNextbotModel(model) then
                local hrp = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head")
                if hrp then
                    nextbots[model] = hrp
                end
            end
        end
    end

    local npcsFolder = workspace:FindFirstChild("NPCs")
    if npcsFolder then
        for _, model in ipairs(npcsFolder:GetChildren()) do
            if model:IsA("Model") and isNextbotModel(model) then
                local hrp = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head")
                if hrp then
                    nextbots[model] = hrp
                end
            end
        end
    end

    for model, hrp in pairs(nextbots) do
        if not NextbotBillboards[model] then
            local esp = CreateBillboardESP("NextbotESP", hrp, Color3.fromRGB(255, 0, 0), 16)
            if esp then
                UpdateBillboardESP("NextbotESP", hrp, model.Name, Color3.fromRGB(255, 0, 0), 16)
                NextbotBillboards[model] = { esp = esp, hrp = hrp }
            end
        else
            UpdateBillboardESP("NextbotESP", hrp, model.Name, Color3.fromRGB(255, 0, 0), 16)
        end
    end

    for model, data in pairs(NextbotBillboards) do
        if not nextbots[model] or not model.Parent then
            if data.hrp then
                DestroyBillboardESP("NextbotESP", data.hrp)
            end
            NextbotBillboards[model] = nil
        end
    end
end

local function scanForPlayers()
    for _, plr in pairs(Players:GetPlayers()) do
        if plr ~= player and plr.Character then
            local head = plr.Character:FindFirstChild("Head") or plr.Character:FindFirstChild("HumanoidRootPart")
            if head then
                if not PlayerBillboards[plr] then
                    local esp = CreateBillboardESP("PlayerESP", head, Color3.fromRGB(0, 255, 0), 14)
                    if esp then
                        UpdateBillboardESP("PlayerESP", head, plr.Name, Color3.fromRGB(0, 255, 0), 14)
                        PlayerBillboards[plr] = esp
                    end
                else
                    UpdateBillboardESP("PlayerESP", head, plr.Name, Color3.fromRGB(0, 255, 0), 14)
                end
            end
        elseif PlayerBillboards[plr] then
            if plr.Character then
                DestroyBillboardESP("PlayerESP",
                    plr.Character:FindFirstChild("Head") or plr.Character:FindFirstChild("HumanoidRootPart"))
            end
            PlayerBillboards[plr] = nil
        end
    end
end

local function scanForTickets()
    local tickets = workspace.Effects and workspace.Effects:FindFirstChild("Tickets")
    if tickets then
        for _, ticket in pairs(tickets:GetChildren()) do
            if ticket:IsA("BasePart") or ticket:IsA("Model") then
                local part = ticket:IsA("Model") and ticket:FindFirstChild("Head") or
                    ticket:IsA("BasePart") and ticket
                if part then
                    if not TicketBillboards[ticket] then
                        local esp = CreateBillboardESP("TicketESP", part, Color3.fromRGB(255, 255, 0), 12)
                        if esp then
                            UpdateBillboardESP("TicketESP", part, "Ticket", Color3.fromRGB(255, 255, 0), 12)
                            TicketBillboards[ticket] = esp
                        end
                    else
                        UpdateBillboardESP("TicketESP", part, "Ticket", Color3.fromRGB(255, 255, 0), 12)
                    end
                end
            end
        end
    end

    for ticket, esp in pairs(TicketBillboards) do
        if not ticket or not ticket.Parent then
            local part = ticket:IsA("Model") and ticket:FindFirstChild("Head") or ticket
            if part then
                DestroyBillboardESP("TicketESP", part)
            end
            TicketBillboards[ticket] = nil
        end
    end
end

-- Tracer ESP Functions
local function createTracerObject()
    local tracer = Drawing.new("Line")
    tracer.Visible = false
    tracer.Thickness = 1
    tracer.ZIndex = 1
    return tracer
end

local function updatePlayerTracers()
    local camera = workspace.CurrentCamera
    if not camera then return end

    local screenBottomCenter = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y)
    local currentTargets = {}

    for _, plr in pairs(Players:GetPlayers()) do
        if plr ~= player and plr.Character then
            local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
            if hrp then
                currentTargets[plr] = true

                if not playerTracerElements[plr] then
                    playerTracerElements[plr] = createTracerObject()
                end

                local tracer = playerTracerElements[plr]
                local vector, onScreen = camera:WorldToViewportPoint(hrp.Position)

                if onScreen then
                    tracer.Visible = true
                    tracer.From = screenBottomCenter
                    tracer.To = Vector2.new(vector.X, vector.Y)
                    tracer.Color = Color3.fromRGB(0, 255, 0)
                else
                    tracer.Visible = false
                end
            end
        end
    end

    for plr, tracer in pairs(playerTracerElements) do
        if not currentTargets[plr] then
            if tracer and tracer.Remove then
                tracer:Remove()
            end
            playerTracerElements[plr] = nil
        end
    end
end

local function updateBotTracers()
    local camera = workspace.CurrentCamera
    if not camera then return end

    local screenBottomCenter = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y)
    local currentTargets = {}

    local playersFolder = workspace:FindFirstChild("Players")
    if playersFolder then
        for _, model in pairs(playersFolder:GetChildren()) do
            if model:IsA("Model") and isNextbotModel(model) then
                local hrp = model:FindFirstChild("HumanoidRootPart")
                if hrp then
                    currentTargets[model] = true

                    if not botTracerElements[model] then
                        botTracerElements[model] = createTracerObject()
                    end

                    local tracer = botTracerElements[model]
                    local vector, onScreen = camera:WorldToViewportPoint(hrp.Position)

                    if onScreen then
                        tracer.Visible = true
                        tracer.From = screenBottomCenter
                        tracer.To = Vector2.new(vector.X, vector.Y)
                        tracer.Color = Color3.fromRGB(255, 0, 0)
                    else
                        tracer.Visible = false
                    end
                end
            end
        end
    end

    local npcsFolder = workspace:FindFirstChild("NPCs")
    if npcsFolder then
        for _, model in pairs(npcsFolder:GetChildren()) do
            if model:IsA("Model") and isNextbotModel(model) then
                local hrp = model:FindFirstChild("HumanoidRootPart")
                if hrp then
                    currentTargets[model] = true

                    if not botTracerElements[model] then
                        botTracerElements[model] = createTracerObject()
                    end

                    local tracer = botTracerElements[model]
                    local vector, onScreen = camera:WorldToViewportPoint(hrp.Position)

                    if onScreen then
                        tracer.Visible = true
                        tracer.From = screenBottomCenter
                        tracer.To = Vector2.new(vector.X, vector.Y)
                        tracer.Color = Color3.fromRGB(255, 0, 0)
                    else
                        tracer.Visible = false
                    end
                end
            end
        end
    end

    for model, tracer in pairs(botTracerElements) do
        if not currentTargets[model] then
            if tracer and tracer.Remove then
                tracer:Remove()
            end
            botTracerElements[model] = nil
        end
    end
end

local function startPlayerTracers()
    if playerTracerConnection then return end
    playerTracerConnection = RunService.RenderStepped:Connect(updatePlayerTracers)
end

local function stopPlayerTracers()
    if playerTracerConnection then
        playerTracerConnection:Disconnect()
        playerTracerConnection = nil
    end
    for plr, tracer in pairs(playerTracerElements) do
        if tracer and tracer.Remove then
            tracer:Remove()
        end
    end
    playerTracerElements = {}
end

local function startBotTracers()
    if botTracerConnection then return end
    botTracerConnection = RunService.RenderStepped:Connect(updateBotTracers)
end

local function stopBotTracers()
    if botTracerConnection then
        botTracerConnection:Disconnect()
        botTracerConnection = nil
    end
    for model, tracer in pairs(botTracerElements) do
        if tracer and tracer.Remove then
            tracer:Remove()
        end
    end
    botTracerElements = {}
end

local ESPTab = Window:Tab({ Icon = "eye", Title = "ESP" })

ESPTab:Section({ Title = "Billboard ESP", TextSize = 20 })
ESPTab:Divider()

ESPTab:Toggle({
    Title = "Nextbots ESP",
    Flag = "NextbotsESPToggle",
    Desc = "Show nextbots with distance",
    Value = false,
    Callback = function(state)
        if state then
            if not nextbotESPLoop then
                nextbotESPLoop = RunService.RenderStepped:Connect(function()
                    scanForNextbots()
                end)
            end
        else
            if nextbotESPLoop then
                nextbotESPLoop:Disconnect()
                nextbotESPLoop = nil
            end

            for model, data in pairs(NextbotBillboards) do
                if data.hrp then
                    DestroyBillboardESP("NextbotESP", data.hrp)
                end
            end
            NextbotBillboards = {}
        end
    end
})

ESPTab:Toggle({
    Title = "Players ESP",
    Flag = "PlayersESPToggle",
    Desc = "Show players with distance",
    Value = false,
    Callback = function(state)
        if state then
            if not playerESPLoop then
                playerESPLoop = RunService.RenderStepped:Connect(function()
                    scanForPlayers()
                end)
            end
        else
            if playerESPLoop then
                playerESPLoop:Disconnect()
                playerESPLoop = nil
            end

            for plr, esp in pairs(PlayerBillboards) do
                if plr.Character then
                    DestroyBillboardESP("PlayerESP",
                        plr.Character:FindFirstChild("Head") or plr.Character:FindFirstChild("HumanoidRootPart"))
                end
            end
            PlayerBillboards = {}
        end
    end
})

ESPTab:Toggle({
    Title = "Tickets ESP",
    Flag = "TicketsESPToggle",
    Desc = "Show summer event tickets with distance",
    Value = false,
    Callback = function(state)
        if state then
            if not ticketESPLoop then
                ticketESPLoop = RunService.RenderStepped:Connect(function()
                    scanForTickets()
                end)
            end
        else
            if ticketESPLoop then
                ticketESPLoop:Disconnect()
                ticketESPLoop = nil
            end

            for ticket, esp in pairs(TicketBillboards) do
                local part = ticket:IsA("Model") and ticket:FindFirstChild("Head") or ticket
                if part then
                    DestroyBillboardESP("TicketESP", part)
                end
            end
            TicketBillboards = {}
        end
    end
})

ESPTab:Divider()
ESPTab:Section({ Title = "Tracer ESP", TextSize = 20 })
ESPTab:Divider()

ESPTab:Toggle({
    Title = "Tracer Players",
    Flag = "TracerPlayersToggle",
    Desc = "Draw lines to players",
    Value = false,
    Callback = function(state)
        if state then
            startPlayerTracers()
        else
            stopPlayerTracers()
        end
    end
})

ESPTab:Toggle({
    Title = "Tracer Nextbots",
    Flag = "TracerNextbotsToggle",
    Desc = "Draw lines to nextbots",
    Value = false,
    Callback = function(state)
        if state then
            startBotTracers()
        else
            stopBotTracers()
        end
    end
})

-- -------------------------------------------------------------------------- --
--                               TAB AUTOMATION                               --
-- -------------------------------------------------------------------------- --

-- ---------------------------- VOTING FUNCTIONS ---------------------------- --

local selectedMapNumber = 1
local selectedGameMode = 1
local autoVoteEnabled = false
local autoVoteModeEnabled = false
local voteConnection = nil
local voteModeConnection = nil

local function fireVoteServer(number, isMode)
    local voteEvent = ReplicatedStorage.Events:FindFirstChild("Vote")
    if voteEvent then
        if voteEvent and typeof(voteEvent) == "Instance" and voteEvent:IsA("RemoteEvent") then
            if isMode then
                voteEvent:FireServer(number, true)
            else
                voteEvent:FireServer(number)
            end
        end
    end
end

-- --------------------------- AUTO FARM MODULE --------------------------- --


local AutoFarmModule = (function()
    local securityPart = nil
    local connections = {
        autoWin = nil,
        farmTickets = nil
    }
    local activeStates = {
        autoWin = false,
        farmTickets = false
    }

    -- Shared helper: Create security platform
    local function createSecurityPart()
        if workspace:FindFirstChild("SecurityPart") then
            return workspace.SecurityPart
        end

        securityPart = Instance.new("Part")
        securityPart.Name = "SecurityPart"
        securityPart.Size = Vector3.new(10, 1, 10)
        securityPart.Position = Vector3.new(5000, 5000, 5000)
        securityPart.Anchored = true
        securityPart.CanCollide = true
        securityPart.Transparency = 0.9
        securityPart.Material = Enum.Material.Neon
        securityPart.BrickColor = BrickColor.new("Bright green")
        securityPart.Parent = workspace

        return securityPart
    end

    -- Shared helper: Remove security platform if no farms active
    local function removeSecurityPart()
        if not activeStates.autoWin and not activeStates.farmTickets then
            if securityPart and securityPart.Parent then
                securityPart:Destroy()
            end
            securityPart = nil
        end
    end

    local farmCS = nil
    local function getFarmCS()
        if farmCS then return farmCS end
        pcall(function() farmCS = require(ReplicatedStorage.Services.Asset.CharacterService) end)
        return farmCS
    end

    -- Shared helper: Check if player is downed
    local function isPlayerDowned(pl)
        if not pl or not pl.Character then return false end
        local cs = getFarmCS()
        if cs then
            local charData = cs:GetCharacterFromPlayer(pl)
            if charData and charData.DataRegistry:Get("Downed") then
                return true
            end
        end
        local hum = pl.Character:FindFirstChild("Humanoid")
        if hum and hum.Health <= 0 then return true end
        return false
    end

    -- Shared helper: Get player from character model
    local function getPlayerFromModel(model)
        for _, pl in pairs(Players:GetPlayers()) do
            if pl.Character == model or (pl.Character and pl.Character.Name == model.Name) then
                return pl
            end
        end
        return nil
    end

    -- ---------- FARM TYPE: AUTO WIN ----------
    local function startAutoWin()
        if connections.autoWin then return end

        local security = createSecurityPart()
        activeStates.autoWin = true

        connections.autoWin = task.spawn(function()
            while activeStates.autoWin do
                local secPart = workspace:FindFirstChild("SecurityPart")
                if not secPart then break end

                local char = player.Character
                if char then
                    local hrp = char:FindFirstChild("HumanoidRootPart")
                    if hrp then
                        local cs = getFarmCS()
                        local isDown = false
                        if cs then
                            local charData = cs:GetCharacterFromPlayer(player)
                            isDown = charData and charData.DataRegistry:Get("Downed")
                        end
                        if not isDown then
                            hrp.CFrame = secPart.CFrame + Vector3.new(0, 3, 0)
                        end
                    end
                end

                task.wait(0.1)
            end
        end)
    end

    local function stopAutoWin()
        activeStates.autoWin = false
        if connections.autoWin then
            task.cancel(connections.autoWin)
            connections.autoWin = nil
        end
        removeSecurityPart()
    end


    -- ---------- FARM TYPE: FARM TICKETS ----------
    local function startFarmTickets()
        if connections.farmTickets then return end

        local security = createSecurityPart()
        activeStates.farmTickets = true

        local yOffset = 15
        local currentTicket = nil
        local ticketProcessedTime = 0

        connections.farmTickets = RunService.Heartbeat:Connect(function()
            local secPart = workspace:FindFirstChild("SecurityPart")
            if not secPart then return end

            local char = player.Character
            if not char then return end

            local hrp = char:FindFirstChild("HumanoidRootPart")
            if not hrp then return end

            local effects = workspace.Effects
            if effects then
                local tickets = effects:FindFirstChild("Tickets")
                if tickets and #tickets:GetChildren() > 0 then
                    if not currentTicket or not currentTicket.Parent then
                        local closestTicket = nil
                        local closestDist = math.huge

                        for _, ticket in pairs(tickets:GetChildren()) do
                            local ticketPos = ticket:IsA("Model") and ticket:GetPivot().Position or ticket.Position
                            local dist = (hrp.Position - ticketPos).Magnitude
                            if dist < closestDist then
                                closestDist = dist
                                closestTicket = ticket
                            end
                        end

                        currentTicket = closestTicket
                        ticketProcessedTime = tick()
                    end

                    if currentTicket and currentTicket.Parent then
                        local ticketPart = currentTicket:IsA("Model") and
                            (currentTicket:FindFirstChild("Root") or currentTicket.PrimaryPart) or currentTicket
                        if ticketPart then
                            local targetPosition = ticketPart.Position + Vector3.new(0, yOffset, 0)
                            hrp.CFrame = CFrame.new(targetPosition)

                            if tick() - ticketProcessedTime > 0.1 then
                                hrp.CFrame = ticketPart.CFrame
                            end
                        else
                            currentTicket = nil
                        end
                    else
                        hrp.CFrame = secPart.CFrame + Vector3.new(0, 3, 0)
                        currentTicket = nil
                    end
                else
                    hrp.CFrame = secPart.CFrame + Vector3.new(0, 3, 0)
                    currentTicket = nil
                end
            else
                hrp.CFrame = secPart.CFrame + Vector3.new(0, 3, 0)
                currentTicket = nil
            end
        end)
    end

    local function stopFarmTickets()
        activeStates.farmTickets = false
        if connections.farmTickets then
            connections.farmTickets:Disconnect()
            connections.farmTickets = nil
        end
        removeSecurityPart()
    end

    -- Public API
    return {
        StartAutoWin = startAutoWin,
        StopAutoWin = stopAutoWin,
        StartFarmTickets = startFarmTickets,
        StopFarmTickets = stopFarmTickets,
        StopAll = function()
            stopAutoWin()
            stopFarmTickets()
        end
    }
end)()

-- ----------------------------- VIP MENU MODULE ---------------------------- --

local VipMenuModule = (function()
    local autoSpecialRoundEnabled = false
    local specialRoundName = "Plushie Hell"
    local lastRoundsCompleted = 0

    local function setSpecialRound(roundName)
        if not roundName or roundName == "" then
            Error("Special Round Failed", "Please enter a special round name!", 2)
            return
        end

        task.spawn(function()
            local success, err = pcall(function()
                local args = {
                    [1] = "!specialround " .. roundName
                }
                game:GetService("ReplicatedStorage"):WaitForChild("Events"):WaitForChild("Admin"):WaitForChild("Command")
                    :InvokeServer(unpack(args))
            end)

            if success then
                print("[SpecialRound] Set to:", roundName)
            else
                warn("[SpecialRound] Failed:", err)
            end
        end)
    end

    -- Hook UpdateServerStateRegistry buat detect round changes
    local lastVoting = nil
    local lastLoading = nil

    local stateRegistry = ReplicatedStorage.Events:FindFirstChild("UpdateServerStateRegistry")
    if stateRegistry then
        stateRegistry.OnClientEvent:Connect(function(stateData)
            if not autoSpecialRoundEnabled then return end
            if not stateData or type(stateData) ~= "table" then return end

            -- RoundStarted: false = round ended, true = round started
            if stateData.RoundStarted == false and lastRoundsCompleted ~= (stateData.RoundsCompleted or 0) then
                lastRoundsCompleted = stateData.RoundsCompleted or 0
                task.spawn(function()
                    task.wait(2)
                    setSpecialRound(specialRoundName)
                    Success("Auto Special Round", "Special round set for this round!", 2)
                end)
            end

            -- Voting: false = voting ended / map loaded
            if stateData.Voting == false and lastVoting ~= false then
                task.spawn(function()
                    local loadWaitTime = 0
                    repeat
                        task.wait(0.5)
                        loadWaitTime = loadWaitTime + 0.5
                    until (not (stateData.Loading == true) and not (stateData.MapLoading == true)) or loadWaitTime > 15

                    local character = player.Character or player.CharacterAdded:Wait()
                    character:WaitForChild("HumanoidRootPart")
                    task.wait(2)
                    setSpecialRound(specialRoundName)
                    Success("Auto Special Round", "Special round set for new map!", 2)
                end)
            end

            lastVoting = stateData.Voting
            lastLoading = stateData.Loading
        end)
    end

    -- Public API
    return {
        SetSpecialRound = setSpecialRound,
        SetAutoEnabled = function(enabled)
            autoSpecialRoundEnabled = enabled
        end,
        GetSpecialRoundName = function()
            return specialRoundName
        end,
        SetSpecialRoundName = function(name)
            specialRoundName = name
        end
    }
end)()

-- -------------------------------------------------------------------------- --
--                         AUTO SELF REVIVE MODULE                           --
-- -------------------------------------------------------------------------- --

local AutoSelfReviveModule = (function()
    local enabled = false
    local method = "Spawnpoint" -- "Spawnpoint" or "Fake Revive"
    local connections = {}      -- { Heartbeat, Character }
    local lastSavedPosition = nil
    local hasRevived = false
    local isReviving = false

    local CharacterService = nil
    local function getCharacterService()
        if CharacterService then return CharacterService end
        local ok, result = pcall(function()
            return require(ReplicatedStorage.Services.Asset.CharacterService)
        end)
        if ok then CharacterService = result end
        return CharacterService
    end

    local function isPlayerDowned()
        local char = player.Character
        if not char then return false end
        local cs = getCharacterService()
        if not cs then return false end
        local charData = cs:GetCharacterFromPlayer(player)
        return charData and charData.DataRegistry:Get("Downed") or false
    end

    local function revive()
        local char = player.Character
        if not char or isReviving then return end
        if not isPlayerDowned() then return end

        isReviving = true

        if method == "Spawnpoint" then
            if not hasRevived then
                hasRevived = true
                pcall(function()
                    ReplicatedStorage.Events.SetPlayerMode:FireServer(true)
                end)
                Success("Auto Self Revive", "Reviving at spawnpoint...", 2)
                task.delay(10, function()
                    hasRevived = false
                end)
                task.delay(1, function()
                    isReviving = false
                end)
            else
                isReviving = false
            end
        elseif method == "Fake Revive" then
            local hrp = char:FindFirstChild("HumanoidRootPart")
            local savedPos = hrp and hrp.Position

            task.spawn(function()
                pcall(function()
                    ReplicatedStorage.Events.SetPlayerMode:FireServer(true)
                end)
                Success("Auto Self Revive", "Saving position and reviving...", 2)

                local newCharacter
                repeat
                    newCharacter = player.Character
                    task.wait()
                until newCharacter and newCharacter:FindFirstChild("HumanoidRootPart") and newCharacter ~= char

                if newCharacter and savedPos then
                    local newHRP = newCharacter:FindFirstChild("HumanoidRootPart")
                    if newHRP then
                        task.wait(0.1)
                        newHRP.CFrame = CFrame.new(savedPos)
                        Success("Auto Self Revive", "Teleported back to saved position!", 2)
                    end
                end
                isReviving = false
            end)
        end
    end

    local function start()
        if connections.Heartbeat then return end
        enabled = true

        connections.Heartbeat = RunService.Heartbeat:Connect(function()
            if not enabled then return end
            if isPlayerDowned() then
                revive()
            end
        end)

        connections.Character = player.CharacterAdded:Connect(function(newChar)
            hasRevived = false
            isReviving = false
            lastSavedPosition = nil
        end)

        Success("Auto Self Revive", "Enabled with method: " .. method, 2)
    end

    local function stop()
        enabled = false
        hasRevived = false
        isReviving = false
        lastSavedPosition = nil

        for name, conn in pairs(connections) do
            if conn then
                conn:Disconnect()
                connections[name] = nil
            end
        end
        Info("Auto Self Revive", "Disabled", 2)
    end

    return {
        Start = start,
        Stop = stop,
        SetMethod = function(newMethod)
            method = newMethod
            if enabled then
                Info("Auto Self Revive", "Method changed to: " .. newMethod, 2)
            end
        end,
        IsEnabled = function()
            return enabled
        end
    }
end)()

-- -------------------------------------------------------------------------- --
--                      AUTO RESPAWN WATCH AD MODULE                          --
-- -------------------------------------------------------------------------- --

local AutoRespawnWatchAd = (function()
    local enabled = false
    local monitorConnection = nil
    local lastKnownState = true

    local function checkPlayerAlive()
        local gamePlayers = workspace:FindFirstChild("Players")
        if gamePlayers then
            local ourChar = gamePlayers:FindFirstChild(player.Name)
            return ourChar ~= nil
        end
        return true
    end

    local function start()
        if enabled then return end
        enabled = true
        monitorConnection = RunService.Heartbeat:Connect(function()
            local isAlive = checkPlayerAlive()
            if lastKnownState == true and isAlive == false then
                Success("Auto Respawn", "Death detected! Watching ad to respawn...", 2)
                task.spawn(function()
                    pcall(function()
                        ReplicatedStorage:WaitForChild("RequestShowAdEvent"):FireServer()
                    end)
                end)
            end

            lastKnownState = isAlive
        end)

        Success("Auto Respawn Watch Ad", "Enabled - will auto respawn on death", 2)
    end

    local function stop()
        if not enabled then return end
        enabled = false

        if monitorConnection then
            monitorConnection:Disconnect()
            monitorConnection = nil
        end

        lastKnownState = true
        Info("Auto Respawn Watch Ad", "Disabled", 2)
    end

    return {
        Start = start,
        Stop = stop,
        IsEnabled = function()
            return enabled
        end
    }
end)()

-- -------------------------------------------------------------------------- --
--                              AUTO CARRY                                   --
-- -------------------------------------------------------------------------- --
local AutoCarryModule = (function()
    local enabled = false
    local connection = nil
    local lastAttempt = 0
    local lastRelease = 0
    local wasCarrying = false
    local releasePause = 8
    local buttonGui = nil
    local button = nil
    local CharacterService = nil

    local function getCharacterService()
        if CharacterService then return CharacterService end
        local ok, result = pcall(function()
            return require(ReplicatedStorage.Services.Asset.CharacterService)
        end)
        if ok then CharacterService = result end
        return CharacterService
    end

    local function isDowned(target)
        local service = getCharacterService()
        local data = service and service:GetCharacterFromPlayer(target)
        return data and data.DataRegistry and data.DataRegistry:Get("Downed") == true
    end

    local function isRagdolled(target)
        local character = target.Character
        if not character then return true end
        if character:FindFirstChild("RagdollConstraints") then return true end
        local service = getCharacterService()
        local data = service and service:GetCharacterFromPlayer(target)
        return data and data.DataRegistry and data.DataRegistry:Get("Ragdolling") == true
    end

    local function isCarrying()
        local service = getCharacterService()
        local data = service and service:GetCharacterFromPlayer(player)
        local state = data and data.Movement and data.Movement.State
        return state == "Carry" or state == "CarrySlide" or state == "CarrySlideAir"
            or state == "CarryAir" or state == "Carried" or state == "CarryMove" or state == "CarryIdle"
    end

    local function start()
        if connection then return end
        enabled = true
        connection = RunService.Heartbeat:Connect(function()
            if not enabled then return end
            if isCarrying() then
                wasCarrying = true
                return
            end
            if wasCarrying then
                wasCarrying = false
                lastRelease = os.clock()
                return
            end
            if os.clock() - lastRelease < releasePause then return end
            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if not root or os.clock() - lastAttempt < 0.5 then return end

            for _, target in ipairs(Players:GetPlayers()) do
                if target ~= player and isDowned(target) and not isRagdolled(target) then
                    local targetCharacter = target.Character
                    local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
                    local tag = targetCharacter and targetCharacter:GetAttribute("Tag")
                    if targetRoot and tag and (root.Position - targetRoot.Position).Magnitude <= 20 then
                        local interact = ReplicatedStorage:FindFirstChild("Events")
                            and ReplicatedStorage.Events:FindFirstChild("Interact")
                        if interact then pcall(interact.FireServer, interact, "Carry", tag) end
                        lastAttempt = os.clock()
                        break
                    end
                end
            end
        end)
    end

    local function stop()
        enabled = false
        wasCarrying = false
        if connection then connection:Disconnect(); connection = nil end
    end

    local module = {
        Start = start,
        Stop = stop,
        SetReleasePause = function(value) releasePause = value end,
        IsEnabled = function() return enabled end,
    }

    function module:SetButtonVisible(visible, toggle)
        if not UserInputService.TouchEnabled then return end
        if not visible then
            if buttonGui then buttonGui:Destroy(); buttonGui = nil; button = nil end
            return
        end
        if buttonGui then return end
        buttonGui = Instance.new("ScreenGui")
        buttonGui.Name = "BagahHubAutoCarry"
        buttonGui.ResetOnSpawn = false
        buttonGui.DisplayOrder = 999
        buttonGui.Parent = PlayerGui
        button = Instance.new("TextButton")
        button.Name = "Toggle"
        button.AnchorPoint = Vector2.new(0.5, 0.5)
        button.Position = UDim2.new(0.82, 0, 0.7, 0)
        button.Size = UDim2.fromOffset(128, 42)
        button.BackgroundColor3 = Color3.fromRGB(54, 45, 20)
        button.TextColor3 = Color3.fromRGB(250, 204, 21)
        button.Font = Enum.Font.GothamBold
        button.TextSize = 14
        button.Text = "AUTO CARRY: OFF"
        button.Parent = buttonGui
        Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
        local dragInput, dragStart, startPosition
        local moved = false
        local suppressClick = false
        button.InputBegan:Connect(function(input)
            if input.UserInputType ~= Enum.UserInputType.Touch then return end
            dragInput = input
            dragStart = input.Position
            startPosition = button.Position
            moved = false
        end)
        local dragConnection = UserInputService.InputChanged:Connect(function(input)
            if input ~= dragInput then return end
            local delta = input.Position - dragStart
            if delta.Magnitude > 8 then moved = true end
            button.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X,
                startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
        end)
        local endConnection = UserInputService.InputEnded:Connect(function(input)
            if input == dragInput then
                dragInput = nil
                suppressClick = moved
            end
        end)
        buttonGui.Destroying:Connect(function()
            dragConnection:Disconnect()
            endConnection:Disconnect()
        end)
        button.Activated:Connect(function()
            if suppressClick then
                suppressClick = false
                return
            end
            toggle:Set(not module.IsEnabled())
        end)
    end

    function module:UpdateButton()
        if button then
            button.Text = self.IsEnabled() and "AUTO CARRY: ON" or "AUTO CARRY: OFF"
            button.BackgroundColor3 = self.IsEnabled() and Color3.fromRGB(105, 85, 20) or Color3.fromRGB(54, 45, 20)
        end
    end

    return module
end)()


-- -------------------------- UI TAB AUTOMATION --------------------------- --

local AutoTab = Window:Tab({
    Icon = "zap",
    Title = "Auto"
})

AutoTab:Section({ Title = "Map Voting", TextSize = 20 })
AutoTab:Divider()

AutoTab:Dropdown({
    Title = "Select Map",
    Flag = "MapDropdown",
    Values = { "Map 1", "Map 2", "Map 3", "Map 4" },
    Value = "Map 1",
    Callback = function(option)
        if option == "Map 1" then
            selectedMapNumber = 1
        elseif option == "Map 2" then
            selectedMapNumber = 2
        elseif option == "Map 3" then
            selectedMapNumber = 3
        elseif option == "Map 4" then
            selectedMapNumber = 4
        end
    end
})

AutoTab:Button({
    Title = "Vote Map",
    Flag = "VoteButton",
    Icon = "check-circle",
    Callback = function()
        fireVoteServer(selectedMapNumber)
    end
})

AutoTab:Toggle({
    Title = "Auto Vote",
    Flag = "AutoVoteToggle",
    Desc = "Automatically vote for selected map",
    Value = false,
    Callback = function(state)
        autoVoteEnabled = state
        if autoVoteEnabled then
            if not voteConnection then
                voteConnection = task.spawn(function()
                    while autoVoteEnabled do
                        fireVoteServer(selectedMapNumber, false)
                        task.wait(1) -- Vote setiap 1 detik, bukan setiap frame
                    end
                end)
            end
        else
            if voteConnection then
                task.cancel(voteConnection)
                voteConnection = nil
            end
        end
    end
})

AutoTab:Divider()

AutoTab:Dropdown({
    Title = "Select Game Mode",
    Flag = "GameModeDropdown",
    Values = { "Mode 1", "Mode 2", "Mode 3", "Mode 4" },
    Value = "Mode 1",
    Callback = function(option)
        if option == "Mode 1" then
            selectedGameMode = 1
        elseif option == "Mode 2" then
            selectedGameMode = 2
        elseif option == "Mode 3" then
            selectedGameMode = 3
        elseif option == "Mode 4" then
            selectedGameMode = 4
        end
    end
})

AutoTab:Toggle({
    Title = "Auto Vote Game Mode",
    Flag = "AutoVoteModeToggle",
    Desc = "Automatically vote for selected game mode",
    Value = false,
    Callback = function(state)
        autoVoteModeEnabled = state
        if autoVoteModeEnabled then
            if not voteModeConnection then
                voteModeConnection = task.spawn(function()
                    while autoVoteModeEnabled do
                        fireVoteServer(selectedGameMode, true)
                        task.wait(1) -- Vote setiap 1 detik
                    end
                end)
            end
        else
            if voteModeConnection then
                task.cancel(voteModeConnection)
                voteModeConnection = nil
            end
        end
    end
})


AutoTab:Section({ Title = "Revive", TextSize = 20 })
AutoTab:Divider()



AutoTab:Button({
    Title = "Revive Yourself",
    Flag = "ReviveButton",
    Icon = "heart",
    Callback = function()
        pcall(function()
            local CharacterService = require(ReplicatedStorage.Services.Asset.CharacterService)
            local charData = CharacterService:GetCharacterFromPlayer(player)
            local isDowned = charData and charData.DataRegistry:Get("Downed")
            if isDowned then
                ReplicatedStorage.Events.SetPlayerMode:FireServer(true)
                Success("Revive", "Revived!", 2)
            else
                Info("Revive", "You are not downed!", 2)
            end
        end)
    end
})

AutoTab:Space()

AutoTab:Dropdown({
    Title = "Self Revive Method",
    Flag = "SelfReviveMethodDropdown",
    Values = { "Spawnpoint", "Fake Revive" },
    Value = "Spawnpoint",
    Callback = function(value)
        AutoSelfReviveModule.SetMethod(value)
    end
})

AutoTab:Toggle({
    Title = "Auto Self Revive",
    Flag = "AutoSelfReviveToggle",
    Desc = "Automatically revive yourself when downed",
    Value = false,
    Callback = function(state)
        if state then
            AutoSelfReviveModule.Start()
        else
            AutoSelfReviveModule.Stop()
        end
    end
})

AutoTab:Space()

AutoTab:Toggle({
    Title = "Auto Respawn Watch Ad",
    Flag = "AutoRespawnWatchAdToggle",
    Desc = "Auto watch ad to respawn when you die",
    Value = false,
    Callback = function(state)
        if state then
            AutoRespawnWatchAd.Start()
        else
            AutoRespawnWatchAd.Stop()
        end
    end
})

AutoTab:Space()

AutoTab:Section({ Title = "Carry", TextSize = 20 })

local AutoCarryToggle = AutoTab:Toggle({
    Title = "Auto Carry",
    Flag = "AutoCarryToggle",
    Desc = "Carry nearby downed players",
    Value = false,
    Callback = function(state)
        if state then
            AutoCarryModule.Start()
        else
            AutoCarryModule.Stop()
        end
        AutoCarryModule:UpdateButton()
    end
})

AutoTab:Slider({
    Title = "Carry Release Pause (s)",
    Flag = "AutoCarryReleasePause",
    Desc = "Wait after releasing a carry before auto carrying again",
    Value = { Min = 0, Max = 15, Default = 8, Step = 1 },
    Callback = function(value)
        AutoCarryModule.SetReleasePause(value)
    end
})

AutoTab:Toggle({
    Title = "Show Carry Button",
    Flag = "ShowAutoCarryButton",
    Desc = "Mobile-only on-screen shortcut for Auto Carry",
    Value = false,
    Callback = function(state)
        AutoCarryModule:SetButtonVisible(state, AutoCarryToggle)
    end
})

AutoTab:Divider()
AutoTab:Section({ Title = "Auto Farming", TextSize = 20 })
AutoTab:Divider()

AutoTab:Toggle({
    Title = "Auto Win",
    Flag = "AutoWinToggle",
    Desc = "Stay at security part to avoid bots and win",
    Value = false,
    Callback = function(state)
        if state then
            AutoFarmModule.StartAutoWin()
            Success("Auto Win", "Farming wins at safe zone!", 2)
        else
            AutoFarmModule.StopAutoWin()
            Success("Auto Win", "Stopped auto win", 2)
        end
    end
})


AutoTab:Toggle({
    Title = "Auto Farm Tickets",
    Flag = "AutoFarmTicketsToggle",
    Desc = "Collect tickets Event",
    Value = false,
    Callback = function(state)
        if state then
            AutoFarmModule.StartFarmTickets()
            Success("Auto Farm Tickets", "Collecting event tickets!", 2)
        else
            AutoFarmModule.StopFarmTickets()
            Success("Auto Farm Tickets", "Stopped ticket farming", 2)
        end
    end
})


AutoTab:Divider()
AutoTab:Section({ Title = "VIP MENU", TextSize = 20 })
AutoTab:Divider()


AutoTab:Input({
    Title = "Special Round Name",
    Flag = "SpecialRoundNameInput",
    Placeholder = "e.g., Plushie Hell",
    Value = VipMenuModule.GetSpecialRoundName(),
    Callback = function(value)
        VipMenuModule.SetSpecialRoundName(value)
    end
})

AutoTab:Button({
    Title = "Set Special Round",
    Flag = "SetSpecialRoundButton",
    Desc = "Manually set special round now",
    Icon = "zap",
    Callback = function()
        local roundName = VipMenuModule.GetSpecialRoundName()
        if roundName == "" then
            Error("Special Round", "Please enter a special round name first!", 2)
            return
        end

        VipMenuModule.SetSpecialRound(roundName)
        Success("Special Round", "Setting special round: " .. roundName, 2)
    end
})

AutoTab:Toggle({
    Title = "Auto Special Round",
    Flag = "AutoSpecialRoundToggle",
    Desc = "Automatically set special round every new round",
    Value = false,
    Callback = function(state)
        VipMenuModule.SetAutoEnabled(state)
        if state then
            Success("Auto Special Round Enabled",
                "Will set '" .. VipMenuModule.GetSpecialRoundName() .. "' on each new round", 3)
        end
    end
})

-- -------------------------------------------------------------------------- --
--                                 TAB VISUALS                                --
-- -------------------------------------------------------------------------- --
-- ----------------------------- COSMETIC MODULE ---------------------------- --

local CosmeticModule = (function()
    -- Private Variables
    local headlessEnabled = false
    local korbloxEnabled = false
    local loopFakeBundleConnection = nil
    local loopFakeBundleEnabled = false

    local headMeshId = "134082579"
    local headTextureId = "134082627"
    local korbloxMeshId = "101851696"
    local korbloxTextureId = "101851254"

    -- Private Functions
    local function applyHeadless()
        local char = player.Character
        if not char then return end

        local head = char:FindFirstChild("Head")
        if not head then return end

        for _, child in pairs(head:GetChildren()) do
            if child:IsA("Decal") or child:IsA("SpecialMesh") then
                child:Destroy()
            end
        end

        local mesh = Instance.new("SpecialMesh")
        mesh.MeshType = Enum.MeshType.FileMesh
        mesh.MeshId = "rbxassetid://" .. headMeshId
        mesh.TextureId = "rbxassetid://" .. headTextureId
        mesh.Scale = Vector3.new(1.25, 1.25, 1.25)
        mesh.Offset = Vector3.new(0, 0, 0)
        mesh.Parent = head

        head.Transparency = 0.1
        head.BrickColor = BrickColor.new("Really black")
        head.Material = Enum.Material.Plastic

        for _, accessory in pairs(char:GetChildren()) do
            if accessory:IsA("Accessory") then
                local handle = accessory:FindFirstChild("Handle")
                if handle then
                    local attachment = handle:FindFirstChildOfClass("Attachment")
                    if attachment then
                        local attachName = attachment.Name:lower()
                        if attachName:find("hair") or attachName:find("hat") or attachName:find("face") then
                            accessory:Destroy()
                        end
                    end
                end
            end
        end
    end

    local function removeHeadless()
        local char = player.Character
        if not char then return end

        local head = char:FindFirstChild("Head")
        if head then
            for _, child in pairs(head:GetChildren()) do
                if child:IsA("SpecialMesh") then
                    child:Destroy()
                end
            end

            head.Transparency = 0
            head.BrickColor = BrickColor.new("Light orange")
            head.Material = Enum.Material.Plastic

            local face = Instance.new("Decal")
            face.Texture = "rbxasset://textures/face.png"
            face.Face = Enum.NormalId.Front
            face.Parent = head
        end
    end

    local function applyKorbloxRightLeg()
        local char = player.Character
        if not char then return end

        local rightLeg = char:FindFirstChild("Right Leg") or char:FindFirstChild("RightLowerLeg")
        if not rightLeg then return end

        local existingFake = char:FindFirstChild("FakeKorbloxLeg")
        if existingFake then
            existingFake:Destroy()
        end

        for _, child in pairs(rightLeg:GetChildren()) do
            if child:IsA("SpecialMesh") then
                child:Destroy()
            end
        end

        local mesh = Instance.new("SpecialMesh")
        mesh.MeshType = Enum.MeshType.FileMesh
        mesh.MeshId = "rbxassetid://" .. korbloxMeshId
        mesh.TextureId = "rbxassetid://" .. korbloxTextureId
        mesh.Scale = Vector3.new(1, 1, 1)
        mesh.Offset = Vector3.new(0, 0, 0)
        mesh.Parent = rightLeg

        rightLeg.Transparency = 0.1
        rightLeg.BrickColor = BrickColor.new("Really black")
        rightLeg.Material = Enum.Material.Plastic
    end

    local function removeKorbloxRightLeg()
        local char = player.Character
        if not char then return end

        local rightLeg = char:FindFirstChild("Right Leg") or char:FindFirstChild("RightLowerLeg")
        if rightLeg then
            for _, child in pairs(rightLeg:GetChildren()) do
                if child:IsA("SpecialMesh") then
                    child:Destroy()
                end
            end

            rightLeg.Transparency = 0
            rightLeg.BrickColor = BrickColor.new("Light orange")
            rightLeg.Material = Enum.Material.Plastic
        end

        local fakeLeg = char:FindFirstChild("FakeKorbloxLeg")
        if fakeLeg then
            fakeLeg:Destroy()
        end
    end

    -- Public API
    return {
        SetFakeHeadless = function(enabled)
            headlessEnabled = enabled
            if enabled then
                applyHeadless()
                Success("Fake Headless", "Fake headless enabled!", 2)
            else
                removeHeadless()
                Info("Fake Headless", "Fake headless disabled", 2)
            end
        end,

        SetFakeKorblox = function(enabled)
            korbloxEnabled = enabled
            if enabled then
                applyKorbloxRightLeg()
                Success("Fake Korblox", "Fake Korblox enabled!", 2)
            else
                removeKorbloxRightLeg()
                Info("Fake Korblox", "Fake Korblox disabled", 2)
            end
        end,

        SetLoopEnabled = function(enabled, interval)
            loopFakeBundleEnabled = enabled

            if loopFakeBundleConnection then
                loopFakeBundleConnection:Disconnect()
                loopFakeBundleConnection = nil
            end

            if enabled then
                local loopInterval = interval or 5
                loopFakeBundleConnection = task.spawn(function()
                    while loopFakeBundleEnabled do
                        task.wait(loopInterval)
                        if headlessEnabled then
                            pcall(applyHeadless)
                        end
                        if korbloxEnabled then
                            pcall(applyKorbloxRightLeg)
                        end
                    end
                end)
                Success("Loop Fake Bundle", "Loop started! Interval: " .. loopInterval .. "s", 2)
            else
                Info("Loop Fake Bundle", "Loop stopped", 2)
            end
        end,

        GetLoopStatus = function()
            return loopFakeBundleEnabled
        end
    }
end)()

-- ====================== EMOTE CHANGER (v5 - yo.lua method, EmoteClass wrapper) ====================== --
-- Wrap EmoteClass.Activate → firesignal OnClientEvent with replacement ID
-- NO metatable hooks → NO movement break → NO game corruption

local currentEmotes = table.create(6, "")
local selectEmotes = table.create(6, "")

local emoteNameToId = {} -- "boldmarch" → 14
local emoteIdToName = {} -- 14 → "BoldMarch"
local cacheReady = false
local recentlySwapped = false

local function normalize(name)
    return name:gsub("%s+", ""):lower()
end

local function getAllEmotes()
    local itemsFolder = ReplicatedStorage:FindFirstChild("Items")
    if not itemsFolder then return {} end

    local allEmotes = {}
    local function findEmotesFolders(parent)
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("Folder") then
                if child.Name == "Emotes" then
                    for _, emote in ipairs(child:GetChildren()) do
                        if emote:IsA("ModuleScript") and emote:GetAttribute("ID") then
                            table.insert(allEmotes, {
                                Name = emote.Name,
                                ID = emote:GetAttribute("ID")
                            })
                        end
                    end
                else
                    findEmotesFolders(child)
                end
            end
        end
    end
    findEmotesFolders(itemsFolder)
    return allEmotes
end

local function buildCache()
    if cacheReady then return end
    cacheReady = true

    local allEmotes = getAllEmotes()
    for _, e in ipairs(allEmotes) do
        local norm = normalize(e.Name)
        if not emoteNameToId[norm] then
            emoteNameToId[norm] = e.ID
            emoteIdToName[e.ID] = e.Name
        end
    end
end

local function findEmoteInfo(input)
    buildCache()
    if not input or input == "" then return nil end
    local num = tonumber(input)
    if num then
        local name = emoteIdToName[num]
        if name then return { Name = name, ID = num } end
        return nil
    end
    local lower = input:lower()
    for id, name in pairs(emoteIdToName) do
        if name:lower() == lower then
            return { Name = name, ID = id }
        end
    end
    return nil
end

local function setEmote(emoteID)
    if not emoteID then return end
    local char = player.Character
    if not char then return end
    local tagValue = char:GetAttribute("Tag")
    if not tagValue then return end
    local tagBuf = buffer.create(2)
    buffer.writeu16(tagBuf, 0, tagValue)

    firesignal(ReplicatedStorage.Events.UpdateCharacterDataRegistry.OnClientEvent, {
        buffer.fromstring("\24\1"),
        emoteID,
        tagBuf
    })
end

local emoteReplacements = {} -- { currentName = replacementID }
local hookInstalled = false
local origActivate = nil
local origDeactivate = nil
local emoteWarmupUntil = 0 -- timestamp: jangan swap emote sampai waktu ini lewat

local function startEmoteHook()
    -- RESET state setiap kali masuk server baru (prevents stale refs)
    if origActivate then
        -- Restore original functions pada old EmoteClass sebelum reset
        pcall(function()
            local EmoteClass = require(ReplicatedStorage.Objects.Items.Emote)
            EmoteClass.Activate = origActivate
            EmoteClass.Deactivate = origDeactivate
        end)
    end
    origActivate = nil
    origDeactivate = nil
    recentlySwapped = false
    hookInstalled = false

    buildCache()

    -- Build replacement table
    emoteReplacements = {}
    for i = 1, 6 do
        local curr = currentEmotes[i] or ""
        local sel = selectEmotes[i] or ""
        if curr ~= "" and sel ~= "" then
            local cInfo = findEmoteInfo(curr)
            local sInfo = findEmoteInfo(sel)
            if cInfo and sInfo and cInfo.ID ~= sInfo.ID then
                emoteReplacements[cInfo.Name] = sInfo.ID
            end
        end
    end

    if next(emoteReplacements) == nil then
        hookInstalled = false
        return
    end

    -- Wrap EmoteClass (fresh dari server baru)
    local ok = pcall(function()
        local EmoteClass = require(ReplicatedStorage.Objects.Items.Emote)

        origActivate = EmoteClass.Activate
        origDeactivate = EmoteClass.Deactivate

        EmoteClass.Activate = function(self, p2, p3)
            origActivate(self, p2, p3)

            -- Skip swap selama warmup (game auto-idle pas round start)
            if tick() < emoteWarmupUntil then return end

            local module = self.EmoteModule
            local currentName = module and module.Name

            if currentName and not recentlySwapped then
                local replacementId = emoteReplacements[currentName]
                if replacementId then
                    task.defer(function()
                        if player.Character then
                            recentlySwapped = true
                            setEmote(replacementId)
                        end
                    end)
                end
            end
        end

        EmoteClass.Deactivate = function(self, ...)
            origDeactivate(self, ...)
            recentlySwapped = false
        end

        hookInstalled = true
    end)
end

local function stopEmoteHook()
    hookInstalled = false
    recentlySwapped = false
    emoteReplacements = {}

    if origActivate and origDeactivate then
        pcall(function()
            local EmoteClass = require(ReplicatedStorage.Objects.Items.Emote)
            EmoteClass.Activate = origActivate
            EmoteClass.Deactivate = origDeactivate
        end)
    end
end

-- Auto-hook on respawn
player.CharacterAdded:Connect(function()
    -- Warmup 3 detik: biarin game settle, jangan swap emote auto-idle
    emoteWarmupUntil = tick() + 3
    stopEmoteHook()
    task.wait(1)
    startEmoteHook()
end)

local currentEmoteInputs = {}
local selectEmoteInputs = {}

-- Cosmetics variables
local cosmetic1 = ""
local cosmetic2 = ""
local originalCosmetic1 = ""
local originalCosmetic2 = ""
local isSwappedCosmetic = false

-- Helper: crawl semua folder "Cosmetics" di bawah Items (support struktur ItemPacks.Events.*.*.Cosmetics)
local function getAllCosmeticsFolders()
    local items = ReplicatedStorage:FindFirstChild("Items")
    if not items then return {} end
    local folders = {}
    local function crawl(parent)
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("Folder") and child.Name == "Cosmetics" then
                table.insert(folders, child)
            elseif child:IsA("Folder") or child:IsA("Model") then
                crawl(child)
            end
        end
    end
    crawl(items)
    return folders
end

-- Cari cosmetic folder by name: cek children langsung di Cosmetics, lalu children di Tier folder
-- PENTING: cosmetic bisa Folder (berisi model + ModuleScript) atau ModuleScript (metadata doang)
local function findCosmeticAnywhere(name)
    local lower = name:lower():gsub("%s+", "")
    for _, cosFolder in ipairs(getAllCosmeticsFolders()) do
        for _, child in ipairs(cosFolder:GetChildren()) do
            -- Case 1: cosmetic langsung di Cosmetics/ (e.g. Cosmetics/WebTraps)
            if child.Name:lower():gsub("%s+", "") == lower then
                -- Kalo ini Folder, return folder-nya (buat swap children model)
                if child:IsA("Folder") then
                    return child
                end
                -- Kalo ModuleScript tanpa folder, return parent Cosmetics
                if child:IsA("ModuleScript") then
                    return child
                end
            end
            -- Case 2: Tier folder, cek children-nya
            if child:IsA("Folder") then
                for _, subChild in ipairs(child:GetChildren()) do
                    if subChild.Name:lower():gsub("%s+", "") == lower then
                        if subChild:IsA("Folder") then
                            return subChild
                        end
                        if subChild:IsA("ModuleScript") then
                            return subChild
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- Fuzzy find cosmetic (cuma cek di Cosmetics/ dan Cosmetics/Tier/)
local function findSimilarCosmetic(name)
    local allCosFolders = getAllCosmeticsFolders()
    if #allCosFolders == 0 then return nil end

    local function levenshtein(s, t)
        local m, n = #s, #t
        if m == 0 then return n end
        if n == 0 then return m end
        local d = {}
        for i = 0, m do d[i] = { [0] = i } end
        for j = 0, n do d[0][j] = j end
        for i = 1, m do
            for j = 1, n do
                local cost = s:sub(i, i) == t:sub(j, j) and 0 or 1
                d[i][j] = math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            end
        end
        return d[m][n]
    end

    local nName = name:lower():gsub("%s+", "")
    local bestMatch, bestScore = nil, 9999

    local function checkItem(item)
        if not item then return end
        local itemNorm = item.Name:lower():gsub("%s+", "")
        if itemNorm == nName then
            bestMatch = item
            bestScore = 0
            return true
        end
        local dist = levenshtein(nName, itemNorm)
        if dist < bestScore then
            bestScore = dist
            bestMatch = item
        end
    end

    for _, cosFolder in ipairs(allCosFolders) do
        for _, child in ipairs(cosFolder:GetChildren()) do
            -- Priority: Folder dulu (buat swap model)
            if child:IsA("Folder") then
                if checkItem(child) and bestScore == 0 then return bestMatch end
                for _, subChild in ipairs(child:GetChildren()) do
                    if checkItem(subChild) and bestScore == 0 then return bestMatch end
                end
            else
                if checkItem(child) and bestScore == 0 then return bestMatch end
            end
        end
    end
    if bestScore <= 3 and bestMatch then return bestMatch end
    return nil
end

-- Swap model children (Character, CharacterClassic, dll) antara dua cosmetic
-- item1 & item2 bisa ModuleScript atau Folder — model children ada DI DALAM item tersebut
-- Contoh: ScarletSlash (ModuleScript) punya anak Character & CharacterClassic
local function swapCosmeticModels(item1, item2)
    -- Container = item itu sendiri (ModuleScript atau Folder) — bukan Parent-nya!
    -- Karena Character & CharacterClassic ada sebagai anak langsung dari ModuleScript
    local container1 = item1
    local container2 = item2

    -- Tukar semua children model (bukan script) antar container
    local temp1 = Instance.new("Folder")
    local temp2 = Instance.new("Folder")

    for _, c in ipairs(container1:GetChildren()) do
        if not c:IsA("ModuleScript") and not c:IsA("LocalScript") and not c:IsA("Script") then
            c.Parent = temp1
        end
    end
    for _, c in ipairs(container2:GetChildren()) do
        if not c:IsA("ModuleScript") and not c:IsA("LocalScript") and not c:IsA("Script") then
            c.Parent = temp2
        end
    end

    for _, c in ipairs(temp1:GetChildren()) do
        c.Parent = container2
    end
    for _, c in ipairs(temp2:GetChildren()) do
        c.Parent = container1
    end

    temp1:Destroy()
    temp2:Destroy()
end

-- ---------------------------- SHOW TIMER HELPER --------------------------- --

local function setupGui()
    local function CreateTimerGUI()
        local MainInterface = Instance.new("ScreenGui")
        local TimerContainer = Instance.new("Frame")
        local AspectRatio = Instance.new("UIAspectRatioConstraint")
        local SizeLimit = Instance.new("UISizeConstraint")
        local TimerDisplay = Instance.new("Frame")
        local RoundedCorners = Instance.new("UICorner")
        local BorderOutline = Instance.new("UIStroke")
        local PanelBackground = Instance.new("ImageLabel")
        local BackgroundCorners = Instance.new("UICorner")
        local OverlayImage = Instance.new("ImageLabel")
        local StatusText = Instance.new("TextLabel")
        local TextGradient = Instance.new("UIGradient")
        local StatusBorder = Instance.new("UIStroke")
        local CountdownText = Instance.new("TextLabel")
        local TimerGradient = Instance.new("UIGradient")
        local CountdownBorder = Instance.new("UIStroke")

        MainInterface.Name = "BagahHubTimerGUI"
        MainInterface.Parent = PlayerGui
        MainInterface.ResetOnSpawn = false
        MainInterface.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        MainInterface.Enabled = true
        MainInterface.DisplayOrder = 2
        TimerContainer.Name = "TimerContainer"
        TimerContainer.Parent = MainInterface
        TimerContainer.AnchorPoint = Vector2.new(0.5, 0)
        TimerContainer.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        TimerContainer.BackgroundTransparency = 1.000
        TimerContainer.BorderColor3 = Color3.fromRGB(27, 42, 53)
        TimerContainer.Position = UDim2.new(0.5, 0, 0, 0)
        TimerContainer.Size = UDim2.new(1, 0, 1, 0)
        TimerContainer.Visible = false

        AspectRatio.Parent = TimerContainer

        SizeLimit.Parent = TimerContainer
        SizeLimit.MaxSize = Vector2.new(900, 900)

        TimerDisplay.Name = "TimerDisplay"
        TimerDisplay.Parent = TimerContainer
        TimerDisplay.AnchorPoint = Vector2.new(0.5, 0)
        TimerDisplay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        TimerDisplay.BackgroundTransparency = 0.600
        TimerDisplay.BorderColor3 = Color3.fromRGB(27, 42, 53)
        TimerDisplay.BorderSizePixel = 0
        TimerDisplay.Position = UDim2.new(0.5, 0, 0.0399999991, 0)
        TimerDisplay.Size = UDim2.new(0.25, 0, 0.100000001, 0)
        TimerDisplay.ZIndex = 10000

        RoundedCorners.CornerRadius = UDim.new(0, 4)
        RoundedCorners.Parent = TimerDisplay

        BorderOutline.Parent = TimerDisplay
        BorderOutline.Thickness = 1
        BorderOutline.Color = Color3.fromRGB(0, 0, 0)
        BorderOutline.Transparency = 0.8

        PanelBackground.Name = "PanelBackground"
        PanelBackground.Parent = TimerDisplay
        PanelBackground.AnchorPoint = Vector2.new(0.5, 0.5)
        PanelBackground.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        PanelBackground.BackgroundTransparency = 1.000
        PanelBackground.BorderColor3 = Color3.fromRGB(27, 42, 53)
        PanelBackground.Position = UDim2.new(0.5, 0, 0.5, 0)
        PanelBackground.Size = UDim2.new(1, 0, 1, 0)
        PanelBackground.ZIndex = 9999
        PanelBackground.Image = "rbxassetid://196969716"
        PanelBackground.ImageColor3 = Color3.fromRGB(21, 21, 21)
        PanelBackground.ImageTransparency = 0.700

        BackgroundCorners.CornerRadius = UDim.new(0, 4)
        BackgroundCorners.Parent = PanelBackground

        OverlayImage.Parent = TimerDisplay
        OverlayImage.AnchorPoint = Vector2.new(0.5, 0.5)
        OverlayImage.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        OverlayImage.BackgroundTransparency = 1.000
        OverlayImage.BorderColor3 = Color3.fromRGB(27, 42, 53)
        OverlayImage.Position = UDim2.new(0.5, 0, 0.5, 0)
        OverlayImage.Size = UDim2.new(0.800000012, 0, 1, 0)
        OverlayImage.ZIndex = 10001
        OverlayImage.Image = "rbxassetid://6761866149"
        OverlayImage.ImageColor3 = Color3.fromRGB(165, 194, 255)
        OverlayImage.ImageTransparency = 0.900
        OverlayImage.ScaleType = Enum.ScaleType.Crop

        StatusText.Name = "StatusText"
        StatusText.Parent = TimerDisplay
        StatusText.AnchorPoint = Vector2.new(0.5, 0.5)
        StatusText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        StatusText.BackgroundTransparency = 1.000
        StatusText.BorderColor3 = Color3.fromRGB(27, 42, 53)
        StatusText.Position = UDim2.new(0.5, 0, 0.25, 0)
        StatusText.Size = UDim2.new(0.800000012, 0, 0.25, 0)
        StatusText.ZIndex = 10002
        StatusText.Font = Enum.Font.GothamBold
        StatusText.Text = "ROUND ACTIVE"
        StatusText.TextColor3 = Color3.fromRGB(165, 194, 255)
        StatusText.TextScaled = true
        StatusText.TextSize = 14.000
        StatusText.TextStrokeTransparency = 0.950
        StatusText.TextWrapped = true

        TextGradient.Color = ColorSequence.new { ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 255, 255)), ColorSequenceKeypoint.new(1.00, Color3.fromRGB(193, 193, 193)) }
        TextGradient.Rotation = 90
        TextGradient.Parent = StatusText

        StatusBorder.Parent = StatusText
        StatusBorder.Thickness = 2
        StatusBorder.Color = Color3.fromRGB(0, 0, 0)
        StatusBorder.Transparency = 0.5

        CountdownText.Name = "CountdownText"
        CountdownText.Parent = TimerDisplay
        CountdownText.AnchorPoint = Vector2.new(0.5, 0.5)
        CountdownText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        CountdownText.BackgroundTransparency = 1.000
        CountdownText.BorderColor3 = Color3.fromRGB(27, 42, 53)
        CountdownText.Position = UDim2.new(0.5, 0, 0.649999976, 0)
        CountdownText.Size = UDim2.new(0.5, 0, 0.5, 0)
        CountdownText.ZIndex = 10002
        CountdownText.Font = Enum.Font.GothamBold
        CountdownText.Text = "0:00"
        CountdownText.TextColor3 = Color3.fromRGB(165, 194, 255)
        CountdownText.TextScaled = true
        CountdownText.TextSize = 14.000
        CountdownText.TextStrokeTransparency = 0.950
        CountdownText.TextWrapped = true

        TimerGradient.Color = ColorSequence.new { ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 255, 255)), ColorSequenceKeypoint.new(1.00, Color3.fromRGB(193, 193, 193)) }
        TimerGradient.Rotation = 90
        TimerGradient.Parent = CountdownText

        CountdownBorder.Parent = CountdownText
        CountdownBorder.Thickness = 2
        CountdownBorder.Color = Color3.fromRGB(0, 0, 0)
        CountdownBorder.Transparency = 0.5

        return CountdownText, StatusText, MainInterface, TimerContainer
    end

    local TimerLabel, StatusLabel, MainInterface, TimerContainer = CreateTimerGUI()

    local timerConnection

    local function formatTime(seconds)
        if not seconds then return "0:00" end

        seconds = math.floor(tonumber(seconds) or 0)
        local minutes = math.floor(seconds / 60)
        local remainingSeconds = seconds % 60

        return string.format("%d:%02d", minutes, remainingSeconds)
    end

    local function updateTimerDisplay()
        local registry = ServerStateRegistryService and ServerStateRegistryService.Registry
        local timerValue = registry and registry.Time or GameState.Get("Timer")
        local roundStatus = registry and registry.RoundStatus
        local roundStarted = roundStatus == 2 or GameState.Get("RoundStarted")

        TimerLabel.Text = formatTime(timerValue)

        TimerLabel.TextColor3 = timerValue and timerValue <= 5 and Color3.fromRGB(215, 100, 100) or
            Color3.fromRGB(165, 194, 255)

        StatusLabel.Text = roundStarted and "ROUND ACTIVE" or roundStatus == 1 and "INTERMISSION" or "WAITING"
    end

    local function setupTimerConnection()
        -- Initial display
        updateTimerDisplay()

        local lastTimer, lastRoundStatus
        timerConnection = RunService.Heartbeat:Connect(function()
            local registry = ServerStateRegistryService and ServerStateRegistryService.Registry
            local timerValue = registry and registry.Time or GameState.Get("Timer")
            local roundStatus = registry and registry.RoundStatus or GameState.Get("RoundStarted")
            if timerValue ~= lastTimer or roundStatus ~= lastRoundStatus then
                lastTimer, lastRoundStatus = timerValue, roundStatus
                updateTimerDisplay()
            end
        end)
    end

    setupTimerConnection()

    local function cleanupTimer()
        if timerConnection then
            timerConnection:Disconnect()
            timerConnection = nil
        end
    end
end

setupGui()
-- ------------------------------ UI TAB VISUAL ----------------------------- --
local VisualsTab = Window:Tab({
    Icon = "palette",
    Title = "Visual"
})

VisualsTab:Section({ Title = "Utilities", TextSize = 20 })
VisualsTab:Divider()

VisualsTab:Toggle({
    Title = "Timer Display",
    Flag = "TimerDisplayToggle",
    Value = false,
    Callback = function(state)
        featureStates.TimerDisplay = state

        local function getRoundTimer()
            local pg = player.PlayerGui
            local shared = pg:FindFirstChild("Shared")
            local hud = shared and shared:FindFirstChild("HUD")
            local overlay = hud and hud:FindFirstChild("Overlay")
            local default = overlay and overlay:FindFirstChild("Default")
            local ro = default and default:FindFirstChild("RoundOverlay")
            local round = ro and ro:FindFirstChild("Round")
            return round and round:FindFirstChild("RoundTimer")
        end


        local function setContainerVisible(visible)
            local main = PlayerGui:FindFirstChild("BagahHubTimerGUI")
            if main then
                local container = main:FindFirstChild("TimerContainer")
                if container then
                    container.Visible = visible
                end
            end
        end

        if state then
            task.spawn(function()
                while featureStates.TimerDisplay do
                    local timer = getRoundTimer()
                    if timer then
                        setContainerVisible(not timer.Visible)
                    else
                        setContainerVisible(true)
                    end
                    task.wait(0.1)
                end
                setContainerVisible(false)
            end)
        else
            setContainerVisible(false)
        end
    end
})


VisualsTab:Section({ Title = "Emote Changer", TextSize = 20 })
VisualsTab:Divider()


-- Current Emote Inputs (1-6)
for i = 1, 6 do
    currentEmoteInputs[i] = VisualsTab:Input({
        Title = "Current Emote " .. i,
        Flag = "CurrentEmote" .. i,
        Placeholder = "Enter current emote name",
        Value = currentEmotes[i],
        Callback = function(v)
            currentEmotes[i] = v:gsub("%s+", "")
        end
    })
end

VisualsTab:Divider()

-- Select Emote Inputs (1-6)
for i = 1, 6 do
    selectEmoteInputs[i] = VisualsTab:Input({
        Title = "Select Emote " .. i,
        Flag = "SelectEmote" .. i,
        Placeholder = "Enter select emote name",
        Value = selectEmotes[i],
        Callback = function(v)
            selectEmotes[i] = v:gsub("%s+", "")
        end
    })
end

-- Emote Option
VisualsTab:Input({
    Title = "Emote Possible option",
    Flag = "EmoteOptionInput",
    Desc = "Higher Value may break emote animation (recommended 1-3)",
    Placeholder = "1",
    Callback = function(v)
        local num = tonumber(v) or 1

        local function setupCharacter(character)
            if character == player.Character then
                character:SetAttribute("EmoteNum", num)
            end
        end

        local function monitorCharacter()
            while true do
                wait(1)
                local character = player.Character
                if character and character:GetAttribute("EmoteNum") ~= num then
                    character:SetAttribute("EmoteNum", num)
                end
            end
        end

        if player.Character then
            setupCharacter(player.Character)
        end

        player.CharacterAdded:Connect(function(character)
            wait(1)
            setupCharacter(character)
        end)

        spawn(monitorCharacter)
    end
})

-- Apply Button
VisualsTab:Button({
    Title = "Apply Emote Mappings",
    Flag = "ApplyEmoteMappings",
    Icon = "check",
    Callback = function()
        local hasAnyEmote = false

        for i = 1, 6 do
            if currentEmotes[i] ~= "" or selectEmotes[i] ~= "" then
                hasAnyEmote = true
                break
            end
        end

        if not hasAnyEmote then
            ObsidianUI:Notify({
                Title = "Emote Changer",
                Content = "Please enter your emote",
                Duration = 3
            })
            return
        end

        local function isValidEmote(emoteName)
            if emoteName == "" then return false, "" end

            buildCache()
            local info = findEmoteInfo(emoteName)
            if info then
                return true, info.Name
            end
            return false, ""
        end

        local sameEmoteSlots = {}
        local missingEmoteSlots = {}
        local invalidEmoteSlots = {}
        local successfulSlots = {}

        for i = 1, 6 do
            if currentEmotes[i] ~= "" and selectEmotes[i] ~= "" then
                local currentValid, currentActual = isValidEmote(currentEmotes[i])
                local selectValid, selectActual = isValidEmote(selectEmotes[i])

                if not currentValid and not selectValid then
                    table.insert(invalidEmoteSlots,
                        {
                            slot = i,
                            currentInvalid = true,
                            currentName = currentEmotes[i],
                            selectInvalid = true,
                            selectName =
                                selectEmotes[i]
                        })
                elseif not currentValid then
                    table.insert(invalidEmoteSlots,
                        {
                            slot = i,
                            currentInvalid = true,
                            currentName = currentEmotes[i],
                            selectInvalid = false,
                            selectName =
                                selectEmotes[i]
                        })
                elseif not selectValid then
                    table.insert(invalidEmoteSlots,
                        {
                            slot = i,
                            currentInvalid = false,
                            currentName = currentEmotes[i],
                            selectInvalid = true,
                            selectName =
                                selectEmotes[i]
                        })
                elseif currentActual:lower() == selectActual:lower() then
                    table.insert(sameEmoteSlots, i)
                else
                    table.insert(successfulSlots, { slot = i, current = currentActual, select = selectActual })
                end
            elseif currentEmotes[i] ~= "" or selectEmotes[i] ~= "" then
                table.insert(missingEmoteSlots, i)
            end
        end

        local message = ""

        if #successfulSlots > 0 then
            message = message .. "✓ Successfully applied emote on:\n"
            for _, data in ipairs(successfulSlots) do
                message = message .. "Slot " .. data.slot .. " Emote: " .. data.current .. " → " .. data.select .. "\n"
            end
            message = message .. "\n"
        end

        if #sameEmoteSlots > 0 then
            message = message .. "✗ Failed (same emote):\n"
            for _, slot in ipairs(sameEmoteSlots) do
                message = message .. "Slot " .. slot .. "\n"
            end
            message = message .. "\n"
        end

        if #invalidEmoteSlots > 0 then
            message = message .. "✗ Failed (invalid emote):\n"
            for _, data in ipairs(invalidEmoteSlots) do
                message = message .. "Slot " .. data.slot
                if data.currentInvalid and data.selectInvalid then
                    message = message .. " - Both invalid\n"
                elseif data.currentInvalid then
                    message = message .. " - Current invalid\n"
                else
                    message = message .. " - Select invalid\n"
                end
            end
            message = message .. "\n"
        end

        if #missingEmoteSlots > 0 then
            message = message .. "✗ Failed (missing text):\n"
            for _, slot in ipairs(missingEmoteSlots) do
                message = message .. "Slot " .. slot .. "\n"
            end
        end

        ObsidianUI:Notify({
            Title = "Emote Changer",
            Content = message,
            Duration = 8
        })

        -- Restart hook dengan mapping baru
        stopEmoteHook()
        startEmoteHook()
    end
})

-- Reset Button
VisualsTab:Button({
    Title = "Reset All Emotes",
    Flag = "ResetAllEmotes",
    Icon = "trash-2",
    Callback = function()
        stopEmoteHook()
        for i = 1, 6 do
            currentEmotes[i] = ""
            selectEmotes[i] = ""

            if currentEmoteInputs[i] and currentEmoteInputs[i].Set then
                currentEmoteInputs[i]:Set("")
            end
            if selectEmoteInputs[i] and selectEmoteInputs[i].Set then
                selectEmoteInputs[i]:Set("")
            end
        end

        ObsidianUI:Notify({
            Title = "Emote Changer",
            Content = "All emotes have been reset!",
            Duration = 3
        })
    end
})

VisualsTab:Divider()
VisualsTab:Section({ Title = "Cosmetics Changer", TextSize = 20 })
VisualsTab:Divider()

VisualsTab:Input({
    Title = "Cosmetic to Replace",
    Flag = "CosmeticToReplace",
    Desc = "Enter the cosmetic NAME you want to REPLACE (e.g., 'Jolly Crown')",
    Value = "",
    Placeholder = "Cosmetic that will be replaced",
    Callback = function(Value)
        cosmetic1 = Value
        if not isSwappedCosmetic then
            originalCosmetic1 = Value
        end
    end
})

VisualsTab:Input({
    Title = "Replace With",
    Flag = "ReplaceWith",
    Desc = "Enter what cosmetic you want to USE instead (e.g., 'Toxic Inferno')",
    Value = "",
    Placeholder = "Cosmetic to use as replacement",
    Callback = function(Value)
        cosmetic2 = Value
        if not isSwappedCosmetic then
            originalCosmetic2 = Value
        end
    end
})

VisualsTab:Button({
    Title = "Apply Cosmetics Swap",
    Flag = "ApplyCosmeticsSwap",
    Icon = "refresh-cw",
    Callback = function()
        pcall(function()
            if cosmetic1 == "" or cosmetic2 == "" or cosmetic1 == cosmetic2 then
                ObsidianUI:Notify({
                    Title = "Cosmetics Changer",
                    Content = "Please enter valid cosmetic names!",
                    Duration = 3
                })
                return
            end

            -- Cari cosmetic (Folder atau ModuleScript) — swap model children-nya
            local result1 = findSimilarCosmetic(cosmetic1)
            local result2 = findSimilarCosmetic(cosmetic2)

            if not result1 or not result2 then
                ObsidianUI:Notify({
                    Title = "Cosmetics Changer",
                    Content = "Could not find: " .. cosmetic1 .. " or " .. cosmetic2,
                    Duration = 3
                })
                return
            end

            cosmetic1 = result1.Name
            cosmetic2 = result2.Name

            if not isSwappedCosmetic then
                originalCosmetic1 = cosmetic1
                originalCosmetic2 = cosmetic2
            end

            swapCosmeticModels(result1, result2)
            isSwappedCosmetic = true

            ObsidianUI:Notify({
                Title = "Cosmetics Changer",
                Content = "Replaced: " .. cosmetic1 .. " → " .. cosmetic2 ..
                    "\n(Equip '" .. cosmetic1 .. "' to see '" .. cosmetic2 .. "')",
                Duration = 5
            })
        end)
    end
})

VisualsTab:Button({
    Title = "Reset Cosmetics",
    Flag = "ResetCosmetics",
    Desc = "Reset cosmetics to original state",
    Icon = "rotate-ccw",
    Callback = function()
        pcall(function()
            if not isSwappedCosmetic then
                ObsidianUI:Notify({
                    Title = "Cosmetics Changer",
                    Content = "No cosmetics have been swapped yet!",
                    Duration = 3
                })
                return
            end

            if originalCosmetic1 == "" or originalCosmetic2 == "" then
                ObsidianUI:Notify({
                    Title = "Cosmetics Changer",
                    Content = "Original cosmetic names not found!",
                    Duration = 3
                })
                return
            end

            local a = findCosmeticAnywhere(cosmetic1)
            local b = findCosmeticAnywhere(cosmetic2)

            if a and b then
                swapCosmeticModels(a, b)
                isSwappedCosmetic = false

                ObsidianUI:Notify({
                    Title = "Cosmetics Changer",
                    Content = "Reset cosmetics to original state!",
                    Duration = 3
                })
            else
                ObsidianUI:Notify({
                    Title = "Cosmetics Changer",
                    Content = "Could not find swapped cosmetics!",
                    Duration = 3
                })
            end
        end)
    end
})


VisualsTab:Divider()
VisualsTab:Section({ Title = "Fake Cosmetics", TextSize = 20 })
VisualsTab:Divider()

VisualsTab:Toggle({
    Title = "Fake Headless",
    Flag = "FakeHeadlessToggle",
    Desc = "Makes your head invisible",
    Value = false,
    Callback = function(state)
        CosmeticModule.SetFakeHeadless(state)
    end
})

VisualsTab:Toggle({
    Title = "Fake Korblox",
    Flag = "FakeKorbloxToggle",
    Desc = "Fake Korblox deathwalker right leg",
    Value = false,
    Callback = function(state)
        CosmeticModule.SetFakeKorblox(state)
    end
})

local loopIntervalValue = 5

VisualsTab:Input({
    Title = "Loop Interval (seconds)",
    Flag = "LoopIntervalInput",
    Placeholder = "Default: 5",
    Value = "5",
    Callback = function(value)
        local num = tonumber(value)
        if num and num > 0 then
            loopIntervalValue = num
        end
    end
})

VisualsTab:Toggle({
    Title = "Loop Fake Cosmetics",
    Flag = "LoopFakeCosmeticsToggle",
    Desc = "Auto reapply fake cosmetics every interval",
    Value = false,
    Callback = function(state)
        CosmeticModule.SetLoopEnabled(state, loopIntervalValue)
    end
})

-- -------------------------------------------------------------------------- --
--                                TELEPORT TAB                                --
-- -------------------------------------------------------------------------- --
-- ------------------------ TELEPORT FEATURES MODULE ----------------------- --

local TeleportFeaturesModule = (function()
    -- PRIVATE HELPERS
    local function validateCharacter()
        local char = player.Character
        if not char then
            Error("Teleport", "Character not found!", 2)
            return nil, nil
        end

        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then
            Error("Teleport", "HumanoidRootPart not found!", 2)
            return nil, nil
        end

        return char, hrp
    end

    local function safeTeleport(hrp, targetPosition, filterInstances)
        filterInstances = filterInstances or {}

        -- Use raycast for safe positioning
        local teleportPos = targetPosition + Vector3.new(0, 5, 0)

        local raycastParams = RaycastParams.new()
        raycastParams.FilterDescendantsInstances = filterInstances
        raycastParams.FilterType = Enum.RaycastFilterType.Blacklist

        local ray = workspace:Raycast(teleportPos, Vector3.new(0, -10, 0), raycastParams)
        if ray then
            teleportPos = ray.Position + Vector3.new(0, 3, 0)
        end

        hrp.CFrame = CFrame.new(teleportPos)
        return true
    end

    local function findNearestTicketInternal()
        local tickets = workspace.Effects and workspace.Effects:FindFirstChild("Tickets")
        if not tickets then return nil end

        local char = player.Character
        if not char or not char:FindFirstChild("HumanoidRootPart") then return nil end

        local hrp = char.HumanoidRootPart
        local nearestTicket = nil
        local nearestDistance = math.huge

        for _, ticket in pairs(tickets:GetChildren()) do
            if ticket:IsA("BasePart") or ticket:IsA("Model") then
                local ticketPart = ticket:IsA("Model") and ticket:FindFirstChild("HumanoidRootPart") or ticket
                if ticketPart and ticketPart:IsA("BasePart") then
                    local dist = (hrp.Position - ticketPart.Position).Magnitude
                    if dist < nearestDistance then
                        nearestDistance = dist
                        nearestTicket = ticketPart
                    end
                end
            end
        end

        return nearestTicket
    end

    -- Helper for checking if player is downed
    local function isPlayerDowned(pl)
        if not pl or not pl.Character then return false end
        local ok, cs = pcall(function() return require(ReplicatedStorage.Services.Asset.CharacterService) end)
        if ok and cs then
            local charData = cs:GetCharacterFromPlayer(pl)
            if charData and charData.DataRegistry:Get("Downed") then
                return true
            end
        end
        local hum = pl.Character:FindFirstChild("Humanoid")
        if hum and hum.Health <= 0 then return true end
        return false
    end

    -- Helper for finding nearest downed player
    local function findNearestDownedPlayer()
        local char, hrp = validateCharacter()
        if not char or not hrp then return nil end

        local nearestPlayer = nil
        local nearestDistance = math.huge

        for _, pl in pairs(Players:GetPlayers()) do
            if pl ~= player and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart") then
                if isPlayerDowned(pl) then
                    local dist = (hrp.Position - pl.Character.HumanoidRootPart.Position).Magnitude
                    if dist < nearestDistance then
                        nearestDistance = dist
                        nearestPlayer = pl
                    end
                end
            end
        end

        return nearestPlayer, nearestDistance
    end

    -- PUBLIC API
    return {
        -- OBJECTIVE TELEPORT
        TeleportToRandomObjective = function()
            local char, hrp = validateCharacter()
            if not char or not hrp then return false end

            local objectives = {}
            local mapFolder = workspace:FindFirstChild("Map")
            if not mapFolder then
                Error("Teleport", "Map folder not found!", 2)
                return false
            end

            local partsFolder = mapFolder:FindFirstChild("Parts")
            if not partsFolder then
                Error("Teleport", "Parts folder not found!", 2)
                return false
            end

            local objectivesFolder = partsFolder:FindFirstChild("Objectives")
            if not objectivesFolder then
                Error("Teleport", "Objectives folder not found!", 2)
                return false
            end

            -- Collect all objectives
            for _, obj in pairs(objectivesFolder:GetChildren()) do
                if obj:IsA("Model") then
                    local primaryPart = obj.PrimaryPart
                    if not primaryPart then
                        for _, part in pairs(obj:GetChildren()) do
                            if part:IsA("BasePart") then
                                primaryPart = part
                                break
                            end
                        end
                    end

                    if primaryPart then
                        table.insert(objectives, {
                            Name = obj.Name,
                            Part = primaryPart
                        })
                    end
                end
            end

            if #objectives == 0 then
                Error("Teleport", "No objectives found!", 2)
                return false
            end

            local selectedObjective = objectives[math.random(1, #objectives)]
            safeTeleport(hrp, selectedObjective.Part.Position, { char })
            Success("Teleport", "Teleported to " .. selectedObjective.Name, 2)
            return true
        end,

        -- TICKET TELEPORT
        FindNearestTicket = findNearestTicketInternal,

        TeleportToNearestTicket = function()
            local char, hrp = validateCharacter()
            if not char or not hrp then return false end

            local ticket = findNearestTicketInternal()
            if not ticket then
                Error("Teleport", "No tickets found!", 2)
                return false
            end

            safeTeleport(hrp, ticket.Position, { char })
            Success("Teleport", "Teleported to nearest ticket!", 2)
            return true
        end,

        -- PLAYER TELEPORTS
        GetPlayerList = function()
            local playerNames = {}
            for _, pl in pairs(Players:GetPlayers()) do
                if pl ~= player then
                    table.insert(playerNames, pl.Name)
                end
            end
            table.sort(playerNames)
            return #playerNames > 0 and playerNames or { "No players available" }
        end,

        TeleportToPlayer = function(playerName)
            if not playerName or playerName == "No players available" then
                Error("Teleport", "No player selected!", 2)
                return false
            end

            local char, hrp = validateCharacter()
            if not char or not hrp then return false end

            local targetPlayer = Players:FindFirstChild(playerName)
            if not targetPlayer or not targetPlayer.Character or not targetPlayer.Character:FindFirstChild("HumanoidRootPart") then
                Error("Teleport", playerName .. " not found or no character!", 2)
                return false
            end

            local targetHRP = targetPlayer.Character.HumanoidRootPart
            safeTeleport(hrp, targetHRP.Position, { char, targetPlayer.Character })
            Success("Teleport", "Teleported to " .. playerName, 2)
            return true
        end,

        TeleportToRandomPlayer = function()
            local char, hrp = validateCharacter()
            if not char or not hrp then return false end

            local players = {}
            for _, pl in pairs(Players:GetPlayers()) do
                if pl ~= player and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart") then
                    table.insert(players, pl)
                end
            end

            if #players == 0 then
                Error("Teleport", "No other players found!", 2)
                return false
            end

            local randomPlayer = players[math.random(1, #players)]
            local targetHRP = randomPlayer.Character.HumanoidRootPart
            safeTeleport(hrp, targetHRP.Position, { char, randomPlayer.Character })
            Success("Teleport", "Teleported to " .. randomPlayer.Name, 2)
            return true
        end,


        -- DOWNED PLAYER TELEPORTS (Public API)
        IsPlayerDowned = isPlayerDowned,                   -- Expose local helper
        FindNearestDownedPlayer = findNearestDownedPlayer, -- Expose local helper

        TeleportToNearestDowned = function()
            local char, hrp = validateCharacter()
            if not char or not hrp then return false end

            local nearestPlayer, distance = findNearestDownedPlayer() -- Use local helper
            if not nearestPlayer then
                Error("Teleport", "No downed players found!", 2)
                return false
            end

            local targetHRP = nearestPlayer.Character.HumanoidRootPart
            safeTeleport(hrp, targetHRP.Position, { char, nearestPlayer.Character })
            Success("Teleport", "Teleported to " .. nearestPlayer.Name .. " (" .. math.floor(distance) .. " studs)", 2)
            return true
        end,
    }
end)()

local TeleportTab = Window:Tab({
    Icon = "navigation",
    Title = "Teleport"
})

TeleportTab:Divider()
TeleportTab:Section({ Title = "Objective Teleports", TextSize = 20 })
TeleportTab:Divider()

TeleportTab:Button({
    Title = "Teleport to Objective",
    Flag = "TeleportToObjectiveButton",
    Icon = "map-pin",
    Desc = "Teleport to a random objective",
    Callback = function()
        TeleportFeaturesModule.TeleportToRandomObjective()
    end
})

TeleportTab:Button({
    Title = "Teleport to Nearest Ticket",
    Flag = "TeleportToNearestTicketButton",
    Icon = "star",
    Desc = "Teleport to the closest ticket",
    Callback = function()
        TeleportFeaturesModule.TeleportToNearestTicket()
    end
})


TeleportTab:Divider()
TeleportTab:Section({ Title = "Player Teleports", TextSize = 20 })
TeleportTab:Divider()


local selectedPlayerName = nil
local PlayerListDropdown = nil

local function getPlayerList()
    return TeleportFeaturesModule.GetPlayerList()
end

local function refreshPlayerDropdown()
    if PlayerListDropdown then
        local playerList = getPlayerList()
        PlayerListDropdown:Refresh(playerList)
        if playerList[1] and playerList[1] ~= "No players available" then
            if not selectedPlayerName or not table.find(playerList, selectedPlayerName) then
                selectedPlayerName = playerList[1]
                PlayerListDropdown:Select(selectedPlayerName)
            end
        else
            selectedPlayerName = nil
        end
    end
end

PlayerListDropdown = TeleportTab:Dropdown({
    Title = "Select Player",
    Flag = "PlayerListDropdown",
    Values = getPlayerList(),
    SearchBarEnabled = true,
    Value = getPlayerList()[1] or "No players available",
    Callback = function(value)
        if value ~= "No players available" then
            selectedPlayerName = value
        end
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

TeleportTab:Button({
    Title = "Teleport to Selected Player",
    Flag = "TeleportToSelectedPlayerButton",
    Icon = "user",
    Desc = "Teleport to the player selected in dropdown",
    Variant = "Primary",
    Callback = function()
        if TeleportFeaturesModule.TeleportToPlayer(selectedPlayerName) then
        else
            refreshPlayerDropdown()
        end
    end
})

TeleportTab:Button({
    Title = "Refresh Player List",
    Flag = "RefreshPlayerListButton",
    Icon = "refresh-cw",
    Desc = "Update the player list manually",
    Variant = "Secondary",
    Callback = function()
        refreshPlayerDropdown()
        Info("Player List", "Player list refreshed!", 2)
    end
})

TeleportTab:Divider()

TeleportTab:Button({
    Title = "Teleport to Random Player",
    Flag = "TeleportToRandomPlayerButton",
    Icon = "users",
    Desc = "Teleport to a random player",
    Callback = function()
        TeleportFeaturesModule.TeleportToRandomPlayer()
    end
})

TeleportTab:Divider()
TeleportTab:Section({ Title = "Downed Player Teleports", TextSize = 20 })
TeleportTab:Divider()



TeleportTab:Button({
    Title = "Teleport to Nearest Downed Player",
    Flag = "TeleportToNearestDownedButton",
    Icon = "navigation",
    Desc = "Automatically teleport to the closest downed player",
    Callback = function()
        TeleportFeaturesModule.TeleportToNearestDowned()
    end
})

-- -------------------------------------------------------------------------- --
--                              SERVER UTILITIES                              --
-- -------------------------------------------------------------------------- --

-- ------------------------- Helper Function Server ------------------------- --

local function getServerLink()
    return string.format("https://www.roblox.com/games/start?placeId=%d&jobId=%s", placeId, jobId)
end

local function joinServerByPlaceId(targetPlaceId, modeName)
    local success, servers = pcall(function()
        return HttpService:JSONDecode(game:HttpGet("https://games.roblox.com/v1/games/" ..
            targetPlaceId .. "/servers/Public?sortOrder=Asc&limit=100"))
    end)

    if success and servers and servers.data and #servers.data > 0 then
        local availableServers = {}
        for _, server in ipairs(servers.data) do
            if server.playing < server.maxPlayers then
                table.insert(availableServers, server)
            end
        end

        if #availableServers > 0 then
            table.sort(availableServers, function(a, b) return a.playing > b.playing end)
            local targetServer = availableServers[1]

            ObsidianUI:Notify({
                Title = "Joining " .. modeName,
                Content = "Teleporting to server with " ..
                    targetServer.playing .. "/" .. targetServer.maxPlayers .. " players",
                Duration = 3
            })

            TeleportService:TeleportToPlaceInstance(targetPlaceId, targetServer.id, player)
        else
            ObsidianUI:Notify({
                Title = "Join Failed",
                Content = "No available " .. modeName .. " servers found!",
                Duration = 3
            })
        end
    else
        ObsidianUI:Notify({
            Title = "Join Failed",
            Content = "Could not fetch " .. modeName .. " servers!",
            Duration = 3
        })
    end
end


-- ------------------------------ TAB UI SERVER ----------------------------- --

local ServerTab = Window:Tab({
    Icon = "server",
    Title = "Server Utilities"
})

ServerTab:Section({ Title = "Server Info", TextSize = 20 })
ServerTab:Divider()

local gameModeName = "Loading..."
local GameModeParagraph = ServerTab:Paragraph({
    Title = "Game Mode",
    Desc = gameModeName
})

task.spawn(function()
    local success, productInfo = pcall(function()
        return MarketplaceService:GetProductInfo(placeId)
    end)
    if success and productInfo then
        local fullName = productInfo.Name
        if fullName:find("Evade %- ") then
            gameModeName = fullName:match("Evade %- (.+)") or fullName
        else
            gameModeName = fullName
        end
        if GameModeParagraph and GameModeParagraph.SetDesc then
            GameModeParagraph:SetDesc(gameModeName)
        end
    else
        gameModeName = "Unknown"
        if GameModeParagraph and GameModeParagraph.SetDesc then
            GameModeParagraph:SetDesc(gameModeName)
        end
    end
end)

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

local numPlayers = #Players:GetPlayers()
local maxPlayers = Players.MaxPlayers

ServerTab:Paragraph({
    Title = "Current Players",
    Desc = numPlayers .. " / " .. maxPlayers
})

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
    Title = "Rejoin Server",
    Desc = "Rejoin the current server",
    Icon = "refresh-cw",
    Callback = function()
        TeleportService:Teleport(game.PlaceId, player)
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
            -- Filter servers with at least 5 players
            local filteredServers = {}
            for _, server in ipairs(servers.data) do
                if server.playing >= 5 then
                    table.insert(filteredServers, server)
                end
            end

            if #filteredServers > 0 then
                local randomServer = filteredServers[math.random(1, #filteredServers)]
                TeleportService:TeleportToPlaceInstance(placeId, randomServer.id, player)
            else
                ObsidianUI:Notify({
                    Title = "Server Hop Failed",
                    Content = "No servers with 5+ players found!",
                    Duration = 3
                })
            end
        else
            ObsidianUI:Notify({
                Title = "Server Hop Failed",
                Content = "Could not fetch servers!",
                Duration = 3
            })
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
                TeleportService:TeleportToPlaceInstance(placeId, servers.data[1].id, player)
            end
        else
            ObsidianUI:Notify({
                Title = "Server Hop Failed",
                Content = "Could not fetch servers!",
                Duration = 3
            })
        end
    end
})

ServerTab:Divider()
ServerTab:Section({ Title = "Join Server", TextSize = 20 })
ServerTab:Divider()

ServerTab:Button({
    Title = "Join Big Team",
    Desc = "Join the most populated Big Team server",
    Icon = "users",
    Callback = function()
        joinServerByPlaceId(10324346056, "Big Team")
    end
})

ServerTab:Button({
    Title = "Join Casual",
    Desc = "Join the most populated Casual server",
    Icon = "coffee",
    Callback = function()
        joinServerByPlaceId(10662542523, "Casual")
    end
})

ServerTab:Button({
    Title = "Join Social Space",
    Desc = "Join the most populated Social Space server",
    Icon = "message-square",
    Callback = function()
        joinServerByPlaceId(10324347967, "Social Space")
    end
})

ServerTab:Button({
    Title = "Join Player Nextbots",
    Desc = "Join the most populated Player Nextbots server",
    Icon = "ghost",
    Callback = function()
        joinServerByPlaceId(121271605799901, "Player Nextbots")
    end
})

ServerTab:Button({
    Title = "Join VC Only",
    Desc = "Join the most populated VC Only server",
    Icon = "mic",
    Callback = function()
        joinServerByPlaceId(10808838353, "VC Only")
    end
})

ServerTab:Button({
    Title = "Join Pro",
    Desc = "Join the most populated Pro server",
    Icon = "award",
    Callback = function()
        joinServerByPlaceId(11353528705, "Pro")
    end
})

ServerTab:Divider()

local customServerCode = ""

ServerTab:Input({
    Title = "Custom Server Code",
    Placeholder = "Enter custom server passcode",
    Value = "",
    Callback = function(value)
        customServerCode = value
    end
})

ServerTab:Button({
    Title = "Join Custom Server",
    Desc = "Join custom server with the code above",
    Icon = "key",
    Callback = function()
        if customServerCode == "" then
            ObsidianUI:Notify({
                Title = "Join Failed",
                Content = "Please enter a custom server code!",
                Duration = 3
            })
            return
        end

        local success, result = pcall(function()
            return game:GetService("ReplicatedStorage"):WaitForChild("Events"):WaitForChild("CustomServers")
                :WaitForChild("JoinPasscode"):InvokeServer(customServerCode)
        end)

        if success then
            ObsidianUI:Notify({
                Title = "Joining Custom Server",
                Content = "Attempting to join with code: " .. customServerCode,
                Duration = 3
            })
        else
            ObsidianUI:Notify({
                Title = "Join Failed",
                Content = "Invalid code or server unavailable!",
                Duration = 3
            })
        end
    end
})


ServerTab:Divider()

-- -------------------------------------------------------------------------- --
--                                  TAB MISC                                  --
-- -------------------------------------------------------------------------- --

-- -------------------------------------------------------------------------- --
--                             ANTI LAG MODULE                                --
-- -------------------------------------------------------------------------- --

local AntiLagModule = (function()
    local function applyFPSBoost()
        Success("FPS Boost", "Applying aggressive optimizations...", 2)
        local Lighting = game:GetService("Lighting")
        local Terrain = workspace:FindFirstChildOfClass("Terrain")
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 1e10
        Lighting.Brightness = 1
        if Terrain then
            Terrain.WaterWaveSize = 0
            Terrain.WaterWaveSpeed = 0
            Terrain.WaterReflectance = 0
            Terrain.WaterTransparency = 1
        end

        for _, obj in ipairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") then
                obj.Material = Enum.Material.Plastic
                obj.Reflectance = 0
            elseif obj:IsA("Decal") or obj:IsA("Texture") then
                obj:Destroy()
            elseif obj:IsA("ParticleEmitter") or obj:IsA("Trail") then
                obj:Destroy()
            elseif obj:IsA("PointLight") or obj:IsA("SpotLight") or obj:IsA("SurfaceLight") then
                obj:Destroy()
            end
        end

        for _, plr in ipairs(Players:GetPlayers()) do
            local char = plr.Character
            if char then
                for _, part in ipairs(char:GetDescendants()) do
                    if part:IsA("Accessory") or part:IsA("Clothing") then
                        part:Destroy()
                    end
                end
            end
        end

        Success("FPS Boost", "Optimizations applied successfully!", 2)
    end

    local function applyAntiLag1()
        Success("Anti Lag 1", "Applying material optimizations...", 2)

        local Lighting = game:GetService("Lighting")
        local Terrain = workspace:FindFirstChildOfClass("Terrain")

        Lighting.GlobalShadows = false
        Lighting.FogEnd = 1e10
        Lighting.Brightness = 1

        if Terrain then
            Terrain.WaterWaveSize = 0
            Terrain.WaterWaveSpeed = 0
            Terrain.WaterReflectance = 0
            Terrain.WaterTransparency = 1
        end

        for _, obj in ipairs(workspace:GetDescendants()) do
            if obj:IsA("BasePart") then
                obj.Material = Enum.Material.Plastic
                obj.Reflectance = 0
            elseif obj:IsA("Decal") or obj:IsA("Texture") then
                obj:Destroy()
            elseif obj:IsA("ParticleEmitter") or obj:IsA("Trail") then
                obj:Destroy()
            elseif obj:IsA("PointLight") or obj:IsA("SpotLight") or obj:IsA("SurfaceLight") then
                obj:Destroy()
            end
        end

        for _, plr in ipairs(Players:GetPlayers()) do
            local char = plr.Character
            if char then
                for _, part in ipairs(char:GetDescendants()) do
                    if part:IsA("Accessory") or part:IsA("Clothing") then
                        part:Destroy()
                    end
                end
            end
        end

        Success("Anti Lag 1", "Material optimizations complete!", 2)
    end


    local function applyAntiLag2()
        Success("Anti Lag 2", "Disabling visual effects...", 2)

        local settings = {
            Textures = true,
            VisualEffects = true,
            Parts = true,
            Particles = true,
            Spot = true
        }

        for _, v in next, game:GetDescendants() do
            if settings.Parts then
                if v:IsA("Part") or v:IsA("UnionOperation") or v:IsA("BasePart") then
                    v.Material = Enum.Material.SmoothPlastic
                end
            end

            if settings.Particles then
                if v:IsA("ParticleEmitter") or v:IsA("Smoke") or v:IsA("Explosion") or v:IsA("Sparkles") or v:IsA("Fire") then
                    v.Enabled = false
                end
            end

            if settings.VisualEffects then
                if v:IsA("BloomEffect") or v:IsA("BlurEffect") or v:IsA("DepthOfFieldEffect") or v:IsA("SunRaysEffect") then
                    v.Enabled = false
                end
            end

            if settings.Textures then
                if v:IsA("Decal") or v:IsA("Texture") then
                    v.Texture = ""
                end
            end


            if settings.Sky then
                if v:IsA("Sky") then
                    v.Parent = nil
                end
            end
        end

        Success("Anti Lag 2", "Visual effects disabled!", 2)
    end

    local function applyRemoveTexture()
        for _, part in ipairs(workspace:GetDescendants()) do
            if part:IsA("Part") or part:IsA("MeshPart") or part:IsA("UnionOperation") or part:IsA("WedgePart") or part:IsA("CornerWedgePart") then
                if part:IsA("Part") then
                    part.Material = Enum.Material.SmoothPlastic
                end
                if part:FindFirstChildWhichIsA("Texture") then
                    local texture = part:FindFirstChildWhichIsA("Texture")
                    texture.Texture = "rbxassetid://0"
                end
                if part:FindFirstChildWhichIsA("Decal") then
                    local decal = part:FindFirstChildWhichIsA("Decal")
                    decal.Texture = "rbxassetid://0"
                end
            end
        end
    end


    return {
        ApplyFPSBoost = applyFPSBoost,
        ApplyAntiLag1 = applyAntiLag1,
        ApplyAntiLag2 = applyAntiLag2,
        ApplyRemoveTexture = applyRemoveTexture
    }
end)()

-- -------------------------- HELPER FUNCTION MISC -------------------------- --


local originalBrightness = game:GetService("Lighting").Brightness
local originalOutdoorAmbient = game:GetService("Lighting").OutdoorAmbient
local originalAmbient = game:GetService("Lighting").Ambient
local originalGlobalShadows = game:GetService("Lighting").GlobalShadows
local originalFogEnd = game:GetService("Lighting").FogEnd
local originalFogStart = game:GetService("Lighting").FogStart


local function applyFullBrightness()
    game:GetService("Lighting").Brightness = 2
    game:GetService("Lighting").OutdoorAmbient = Color3.fromRGB(255, 255, 255)
    game:GetService("Lighting").Ambient = Color3.fromRGB(255, 255, 255)
    game:GetService("Lighting").GlobalShadows = false
end

local function removeFullBrightness()
    game:GetService("Lighting").Brightness = originalBrightness
    game:GetService("Lighting").OutdoorAmbient = originalOutdoorAmbient
    game:GetService("Lighting").Ambient = originalAmbient
    game:GetService("Lighting").GlobalShadows = originalGlobalShadows
end

local function applySuperFullBrightness()
    game:GetService("Lighting").Brightness = 15
    game:GetService("Lighting").OutdoorAmbient = Color3.fromRGB(255, 255, 255)
    game:GetService("Lighting").Ambient = Color3.fromRGB(255, 255, 255)
    game:GetService("Lighting").GlobalShadows = false
end

local function applyNoFog()
    game:GetService("Lighting").FogEnd = 1000000
    game:GetService("Lighting").FogStart = 999999
end

local function removeNoFog()
    game:GetService("Lighting").FogEnd = originalFogEnd
    game:GetService("Lighting").FogStart = originalFogStart
end

local AntiAFKConnection

local function startAntiAFK()
    AntiAFKConnection = player.Idled:Connect(function()
        VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        task.wait(1)
        VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    end)
end

local function stopAntiAFK()
    if AntiAFKConnection then
        AntiAFKConnection:Disconnect()
        AntiAFKConnection = nil
    end
end

-- ------------------------------- TAB UI MISC ------------------------------ --
local MiscTab = Window:Tab({
    Icon = "settings",
    Title = "Misc"
})

MiscTab:Divider()
MiscTab:Section({ Title = "Performance Optimization", TextSize = 20 })
MiscTab:Divider()

MiscTab:Button({
    Title = "FPS Boost",
    Desc = "Most aggressive optimization (removes all lag)",
    Icon = "zap",
    Callback = function()
        AntiLagModule.ApplyFPSBoost()
    end
})

MiscTab:Button({
    Title = "Anti Lag 1",
    Desc = "Aggressive material and effect removal",
    Icon = "trending-up",
    Callback = function()
        AntiLagModule.ApplyAntiLag1()
    end
})

MiscTab:Button({
    Title = "Anti Lag 2",
    Desc = "Disable visual effects and textures",
    Icon = "sliders",
    Callback = function()
        AntiLagModule.ApplyAntiLag2()
    end
})

MiscTab:Button({
    Title = "Remove Texture",
    Desc = "Remove all textures",
    Icon = "sliders",
    Callback = function()
        AntiLagModule.ApplyRemoveTexture()
    end
})

MiscTab:Section({ Title = "Visual Enhancements", TextSize = 20 })
MiscTab:Divider()

MiscTab:Toggle({
    Title = "Full Brightness",
    Desc = "Brighten the game",
    Flag = "FullBrightnessToggle",
    Value = false,
    Callback = function(state)
        if state then
            applyFullBrightness()
        else
            removeFullBrightness()
        end
    end
})

MiscTab:Toggle({
    Title = "Super Full Brightness",
    Desc = "Brighten the game",
    Flag = "SuperFullBrightnessToggle",
    Value = false,
    Callback = function(state)
        if state then
            applySuperFullBrightness()
        else
            removeFullBrightness()
        end
    end
})

MiscTab:Toggle({
    Title = "No Fog",
    Desc = "Remove all fog",
    Flag = "NoFogToggle",
    Value = false,
    Callback = function(state)
        if state then
            applyNoFog()
        else
            removeNoFog()
        end
    end
})

MiscTab:Toggle({
    Title = "FPS Display",
    Desc = "Show FPS, Ping, Mem, and CPU stats",
    Flag = "FPSDisplayToggle",
    Value = false,
    Callback = function(state)
        if state then
            local success, err = pcall(function()
                loadstring(game:HttpGet(
                    "https://raw.githubusercontent.com/Bagah-Project/bagah-hub-public/refs/heads/main/universal/fps_display.lua"))()
            end)
            if success then
                Success("FPS Display", "Performance monitor loaded!", 2)
            else
                Error("FPS Display", "Failed to load script: " .. tostring(err), 2)
            end
        else
            local success, err = pcall(function()
                local pg = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
                local gui = pg:FindFirstChild("BagahHub_FPSDisplay")
                if gui then
                    gui:Destroy()
                end
            end)
            Info("FPS Display", "Performance monitor hidden", 2)
        end
    end
})

MiscTab:Divider()
MiscTab:Section({ Title = "Utilities", TextSize = 20 })
MiscTab:Divider()


MiscTab:Toggle({
    Title = "Anti-AFK",
    Desc = "Prevent auto-kick",
    Flag = "AntiAfkToggle",
    Value = featureStates.AntiAFK,
    Callback = function(state)
        featureStates.AntiAFK = state
        if state then
            startAntiAFK()
        else
            stopAntiAFK()
        end
    end
})

if featureStates.AntiAFK then
    startAntiAFK()
end

MiscTab:Button({
    Title = "Remove Invisible Walls",
    Desc = "Remove all invisible barriers in the map",
    Icon = "trash-2",
    Callback = function()
        local mapFolder = workspace:FindFirstChild("Map")
        if mapFolder then
            local invisParts = mapFolder:FindFirstChild("InvisParts")
            if invisParts then
                local count = 0
                for _, wall in pairs(invisParts:GetChildren()) do
                    wall:Destroy()
                    count = count + 1
                end
                Success("Removed " .. count .. " invisible walls!")
            else
                Error("InvisParts folder not found!")
            end
        end
    end
})

MiscTab:Input({
    Title = "Set FOV",
    Desc = "Set FOV value (0-120)",
    Placeholder = "Enter FOV value (0-120)",
    Value = "",
    Callback = function(value)
        local num = tonumber(value)
        if num then
            ChangeSettingRemote:InvokeServer(2, num)
            UpdatedEvent:Fire(2, num)
            Success("FOV set to: " .. num, "FOV set to: " .. num, 2)
        end
    end
})

MiscTab:Toggle({
    Title = "Toggle Exchange Menu",
    Desc = "Show/hide event exchange menu",
    Value = false,
    Callback = function(state)
        local success, err = pcall(function()
            player.PlayerGui.Menu.Views.Battlepass.Exchange.Visible = state
        end)
        if not success then
            warn("Exchange menu not found:", err)
        end
    end
})



MiscTab:Divider()
MiscTab:Section({ Title = "Lag Switch", TextSize = 20 })
MiscTab:Divider()

local lagSwitchMethod = "Metode 1"
local lagSwitchDuration = 0.5
local lagSwitchKey = Enum.KeyCode.L
local lagSwitchGui = nil
local setfflag = rawget(_G, "setfflag")
local lagSwitchButton = nil

local function triggerLagSwitch()
    local duration = lagSwitchDuration
    local method = lagSwitchMethod
    task.spawn(function()
        if method == "Metode 1" then
            pcall(function() setfflag("MaxMissedWorldStepsRemembered", "1") end)
            local start = tick()
            while tick() - start < duration do
                local a = math.random(1, 1000000) * math.random(1, 1000000)
                a = a / math.random(1, 10000)
            end
        elseif method == "Metode 2" then
            pcall(function() setfflag("MaxMissedWorldStepsRemembered", "10000001000000") end)
            local start = os.clock()
            while os.clock() - start < duration do end
        end
    end)
end

local lagSwitchKeyConn = UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == lagSwitchKey then
        triggerLagSwitch()
    end
end)

local function setLagButtonVisible(visible)
    if not UserInputService.TouchEnabled then return end
    if not visible then
        if lagSwitchGui then lagSwitchGui:Destroy(); lagSwitchGui = nil; lagSwitchButton = nil end
        return
    end
    if lagSwitchGui then return end
    lagSwitchGui = Instance.new("ScreenGui")
    lagSwitchGui.Name = "BagahHubLagSwitch"
    lagSwitchGui.ResetOnSpawn = false
    lagSwitchGui.DisplayOrder = 999
    lagSwitchGui.Parent = PlayerGui
    lagSwitchButton = Instance.new("TextButton")
    lagSwitchButton.Name = "LagButton"
    lagSwitchButton.AnchorPoint = Vector2.new(0.5, 0.5)
    lagSwitchButton.Position = UDim2.new(0.82, 0, 0.55, 0)
    lagSwitchButton.Size = UDim2.fromOffset(110, 42)
    lagSwitchButton.BackgroundColor3 = Color3.fromRGB(54, 45, 20)
    lagSwitchButton.TextColor3 = Color3.fromRGB(250, 204, 21)
    lagSwitchButton.Font = Enum.Font.GothamBold
    lagSwitchButton.TextSize = 14
    lagSwitchButton.Text = "LAG"
    lagSwitchButton.Parent = lagSwitchGui
    Instance.new("UICorner", lagSwitchButton).CornerRadius = UDim.new(0, 8)
    local dragInput, dragStart, startPosition, moved, suppressClick
    lagSwitchButton.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.Touch then return end
        dragInput = input
        dragStart = input.Position
        startPosition = lagSwitchButton.Position
        moved = false
    end)
    local dragConn = UserInputService.InputChanged:Connect(function(input)
        if input ~= dragInput then return end
        local delta = input.Position - dragStart
        if delta.Magnitude > 8 then moved = true end
        lagSwitchButton.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X,
            startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
    end)
    local endConn = UserInputService.InputEnded:Connect(function(input)
        if input == dragInput then
            dragInput = nil
            suppressClick = moved
        end
    end)
    lagSwitchGui.Destroying:Connect(function()
        dragConn:Disconnect()
        endConn:Disconnect()
    end)
    lagSwitchButton.Activated:Connect(function()
        if suppressClick then suppressClick = false; return end
        triggerLagSwitch()
    end)
end

MiscTab:Dropdown({
    Title = "Lag Method",
    Flag = "LagMethodDropdown",
    Values = { "Metode 1", "Metode 2" },
    Value = "Metode 1",
    Callback = function(value)
        lagSwitchMethod = value
    end
})

MiscTab:Slider({
    Title = "Lag Duration (s)",
    Flag = "LagDurationSlider",
    Value = { Min = 1, Max = 5, Default = 1, Step = 1 },
    Callback = function(value)
        lagSwitchDuration = value / 10
    end
})

MiscTab:Input({
    Title = "Lag Keybind (PC)",
    Flag = "LagKeybindInput",
    Desc = "Key name to trigger lag switch (e.g. L, G, F, V)",
    Placeholder = "L",
    Value = "L",
    Callback = function(value)
        local keyName = tostring(value):gsub("%s+", ""):upper()
        local ok, keyCode = pcall(function() return Enum.KeyCode[keyName] end)
        if ok and keyCode then
            lagSwitchKey = keyCode
        end
    end
})

MiscTab:Button({
    Title = "Trigger Lag Switch",
    Desc = "Freeze client briefly (PC keybind: L)",
    Icon = "zap",
    Callback = triggerLagSwitch
})

MiscTab:Toggle({
    Title = "Show Lag Button",
    Flag = "ShowLagButton",
    Desc = "Mobile-only on-screen button for Lag Switch",
    Value = false,
    Callback = function(state)
        setLagButtonVisible(state)
    end
})

MiscTab:Divider()
MiscTab:Section({ Title = "Community", TextSize = 20 })
MiscTab:Divider()

MiscTab:Button({
    Title = "Join Discord Server",
    Desc = "Copy Discord invite link",
    Icon = "message-circle",
    Callback = function()
        local discordLink = "https://discord.gg/kJ552CMBx4"
        local success = pcall(function()
            setclipboard(discordLink)
        end)

        if success then
            Success("Discord Link Copied!", "Discord link copied to clipboard!", 2)
        else
            Error("Copy Failed", "Your executor doesn't support clipboard", 2)
            warn("Discord Link:", discordLink)
        end
    end
})




-- -------------------------------------------------------------------------- --
--                              FINAL SETUP                                   --
-- -------------------------------------------------------------------------- --

local function unloadEvade()
    State.Player.FlyEnabled = false
    State.Player.NoclipEnabled = false
    State.Player.SpeedEnabled = false
    State.Player.BhopHoldEnabled = false
    State.Player.BhopToggleEnabled = false
    pcall(FlyingModule.Stop)
    pcall(NoclipModule.Disable)
    pcall(CFrameSpeedModule.Stop)
    pcall(BhopModule.Stop)
    pcall(BhopToggleModule.Stop)

    autoVoteEnabled = false
    autoVoteModeEnabled = false
    if voteConnection then task.cancel(voteConnection); voteConnection = nil end
    if voteModeConnection then task.cancel(voteModeConnection); voteModeConnection = nil end
    pcall(AutoSelfReviveModule.Stop)
    pcall(AutoRespawnWatchAd.Stop)
    pcall(AutoCarryModule.Stop)
    pcall(AutoCarryModule.SetButtonVisible, AutoCarryModule, false)
    pcall(VipMenuModule.SetAutoEnabled, false)
    featureStates.TimerDisplay = false
    featureStates.AntiAFK = false
    pcall(stopAntiAFK)
pcall(function()
        local fpsGui = player.PlayerGui:FindFirstChild("BagahHub_FPSDisplay")
        if fpsGui then fpsGui:Destroy() end
    end)
    if lagSwitchKeyConn then lagSwitchKeyConn:Disconnect(); lagSwitchKeyConn = nil end
    if lagSwitchGui then lagSwitchGui:Destroy(); lagSwitchGui = nil; lagSwitchButton = nil end
    Library:Unload()
end

local ConfigTab = ObsidianWindow:AddTab("Configs", "folder-cog")
SaveManager:BuildConfigSection(ConfigTab)
ConfigTab:AddRightGroupbox("Script"):AddButton({
    Text = "Unload Bagah",
    Tooltip = "Disable active Bagah features and close the UI",
    Func = unloadEvade,
})
SaveManager:LoadAutoloadConfig()

Window:SelectTab(1)
Success("Script Loaded", "BagahHub Evade loaded successfully!", 3)
