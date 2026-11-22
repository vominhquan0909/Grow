-- run in Delta executor (Luau)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local LogService = game:GetService("LogService")
local ScriptContext = game:GetService("ScriptContext")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local Config = {
	Master = false,
	AimEnabled = true,
	EspEnabled = true,
	TeamCheck = true,
	WallCheck = true,
	ShowFov = true,
	ShowBox = true,
	ShowSkeleton = true,
	ShowHealth = true,
	ShowTracers = true,
	ShowInfo = true,
	FovRadius = 150,
	Smoothing = 0.22,
	Prediction = 0.135,
	TargetPart = "Head",

	-- server-usable client-side misc
	Noclip = false,
	InfJump = false,
	SpeedEnabled = false,
	WalkSpeed = 28,
	JumpEnabled = false,
	JumpPower = 75,
	Fullbright = false,

	-- client-side anti-kick / telemetry suppression
	AntiKick = true,
	BlockErrorReport = true,
	SpoofWalkState = true,
	SafeLatencyJitter = true,
}

local LightingOrig = {
	Ambient = Lighting.Ambient,
	OutdoorAmbient = Lighting.OutdoorAmbient,
	Brightness = Lighting.Brightness,
	GlobalShadows = Lighting.GlobalShadows,
}

-- client-side kick / telemetry guard layer
local GuardState = {
	Hooked = false,
	BlockedKicks = 0,
	BlockedReports = 0,
}

local function installClientGuards()
	if GuardState.Hooked then return end
	GuardState.Hooked = true

	-- 1. block local Player:Kick calls & namecall kick traps
	if type(hookmetamethod) == "function" and type(getnamecallmethod) == "function" then
		pcall(function()
			local oldNamecall
			oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
				local method = getnamecallmethod()
				if Config.Master and Config.AntiKick then
					if self == LocalPlayer and (method == "Kick" or method == "kick") then
						GuardState.BlockedKicks += 1
						return nil
					end
					if Config.BlockErrorReport and method == "FireServer" then
						local n = tostring(self)
						if n:lower():find("error") or n:lower():find("log") or n:lower():find("anticheat") or n:lower():find("telemetry") then
							GuardState.BlockedReports += 1
							return nil
						end
					end
				end
				return oldNamecall(self, ...)
			end)
		end)
	end

	-- 2. direct LocalPlayer.Kick override if writable
	pcall(function()
		local origKick = LocalPlayer.Kick
		LocalPlayer.Kick = function(self, ...)
			if Config.Master and Config.AntiKick and self == LocalPlayer then
				GuardState.BlockedKicks += 1
				return nil
			end
			return origKick(self, ...)
		end
	end)

	-- 3. suppress error-prompt disconnect modal triggers when enabled
	pcall(function()
		GuiService.ErrorMessageChanged:Connect(function()
			if Config.Master and Config.AntiKick then
				GuiService:ClearError()
			end
		end)
	end)

	-- 4. detach ScriptContext error connections if exposed by executor
	if type(getconnections) == "function" then
		pcall(function()
			for _, conn in ipairs(getconnections(ScriptContext.Error)) do
				if Config.BlockErrorReport then
					conn:Disable()
				end
			end
		end)
		pcall(function()
			for _, conn in ipairs(getconnections(LogService.MessageOut)) do
				if Config.BlockErrorReport then
					conn:Disable()
				end
			end
		end)
	end
end

installClientGuards()

local hasDrawing = pcall(function()
	local d = Drawing.new("Line")
	d:Remove()
end)

local FovCircle = nil
if hasDrawing then
	FovCircle = Drawing.new("Circle")
	FovCircle.Thickness = 1.5
	FovCircle.NumSides = 64
	FovCircle.Filled = false
	FovCircle.Transparency = 0.85
	FovCircle.Color = Color3.fromRGB(0, 255, 170)
	FovCircle.Visible = false
end

local R15_BONES = {
	{ "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
	{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}

local R6_BONES = {
	{ "Head", "Torso" }, { "Torso", "Left Arm" }, { "Torso", "Right Arm" },
	{ "Torso", "Left Leg" }, { "Torso", "Right Leg" },
}

local EspCache = {}

local function newLine(color, thickness)
	if not hasDrawing then return nil end
	local l = Drawing.new("Line")
	l.Color = color or Color3.new(1, 1, 1)
	l.Thickness = thickness or 1.5
	l.Transparency = 1
	l.Visible = false
	return l
end

local function newSquare(color, thickness)
	if not hasDrawing then return nil end
	local s = Drawing.new("Square")
	s.Color = color or Color3.new(1, 1, 1)
	s.Thickness = thickness or 1.5
	s.Filled = false
	s.Transparency = 1
	s.Visible = false
	return s
end

local function newText(color, size)
	if not hasDrawing then return nil end
	local t = Drawing.new("Text")
	t.Color = color or Color3.new(1, 1, 1)
	t.Size = size or 13
	t.Center = true
	t.Outline = true
	t.Transparency = 1
	t.Visible = false
	return t
end

local function createEspEntry()
	if not hasDrawing then return nil end
	local bones = {}
	for i = 1, #R15_BONES do
		bones[i] = newLine(Color3.fromRGB(255, 255, 255), 1.4)
	end
	return {
		box = newSquare(Color3.fromRGB(255, 80, 80), 1.5),
		hpBg = newLine(Color3.fromRGB(20, 20, 20), 4),
		hpBar = newLine(Color3.fromRGB(80, 255, 120), 2.5),
		tracer = newLine(Color3.fromRGB(255, 220, 90), 1.2),
		label = newText(Color3.fromRGB(255, 255, 255), 13),
		bones = bones,
	}
end

local function hideEspEntry(e)
	if not e then return end
	if e.box then e.box.Visible = false end
	if e.hpBg then e.hpBg.Visible = false end
	if e.hpBar then e.hpBar.Visible = false end
	if e.tracer then e.tracer.Visible = false end
	if e.label then e.label.Visible = false end
	if e.bones then
		for _, b in ipairs(e.bones) do b.Visible = false end
	end
end

local function destroyEspEntry(e)
	if not e then return end
	pcall(function()
		if e.box then e.box:Remove() end
		if e.hpBg then e.hpBg:Remove() end
		if e.hpBar then e.hpBar:Remove() end
		if e.tracer then e.tracer:Remove() end
		if e.label then e.label:Remove() end
		if e.bones then
			for _, b in ipairs(e.bones) do b:Remove() end
		end
	end)
end

local function isTeammate(player)
	if not Config.TeamCheck then return false end
	if LocalPlayer.Neutral or player.Neutral then return false end
	return LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team
end

local function isVisible(origin, targetPart, character)
	if not Config.WallCheck then return true end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
	table.insert(ignore, character)
	params.FilterDescendantsInstances = ignore
	local hit = Workspace:Raycast(origin, targetPart.Position - origin, params)
	return hit == nil or hit.Instance:IsDescendantOf(character)
end

local function getPredictedPos(part)
	local vel = part.AssemblyLinearVelocity or Vector3.zero
	return part.Position + vel * Config.Prediction
end

local function getClosestTarget()
	local mouseLoc = UserInputService:GetMouseLocation()
	local bestPart = nil
	local bestDist = Config.FovRadius

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer and not isTeammate(plr) then
			local char = plr.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local part = char and (char:FindFirstChild(Config.TargetPart) or char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
			if hum and hum.Health > 0 and part then
				local screenPos, onScreen = Camera:WorldToViewportPoint(getPredictedPos(part))
				if onScreen and screenPos.Z > 0 then
					local d = (Vector2.new(screenPos.X, screenPos.Y) - mouseLoc).Magnitude
					if d < bestDist and isVisible(Camera.CFrame.Position, part, char) then
						bestDist = d
						bestPart = part
					end
				end
			end
		end
	end
	return bestPart
end

local function aimAt(targetPart)
	if not targetPart then return end
	local desired = CFrame.lookAt(Camera.CFrame.Position, getPredictedPos(targetPart))
	Camera.CFrame = Camera.CFrame:Lerp(desired, math.clamp(Config.Smoothing, 0.01, 1))
end

local function updateEsp()
	if not hasDrawing or not Config.Master or not Config.EspEnabled then
		for _, e in pairs(EspCache) do hideEspEntry(e) end
		return
	end

	local vp = Camera.ViewportSize
	local bottomCenter = Vector2.new(vp.X * 0.5, vp.Y)
	local camPos = Camera.CFrame.Position

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr == LocalPlayer or isTeammate(plr) then
			if EspCache[plr] then hideEspEntry(EspCache[plr]) end
			continue
		end

		local char = plr.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local head = char and char:FindFirstChild("Head")
		if not hum or hum.Health <= 0 or not root or not head then
			if EspCache[plr] then hideEspEntry(EspCache[plr]) end
			continue
		end

		local entry = EspCache[plr]
		if not entry then
			entry = createEspEntry()
			EspCache[plr] = entry
		end

		local rootVp, rootVis = Camera:WorldToViewportPoint(root.Position)
		if not rootVis or rootVp.Z <= 0 then
			hideEspEntry(entry)
			continue
		end

		local topVp = Camera:WorldToViewportPoint(head.Position + Vector3.new(0, head.Size.Y * 0.6 + 0.25, 0))
		local botVp = Camera:WorldToViewportPoint(root.Position - Vector3.new(0, root.Size.Y * 0.5 + 1.8, 0))
		local boxH = math.clamp(math.abs(botVp.Y - topVp.Y), 10, 800)
		local boxW = boxH * 0.58
		local boxX = rootVp.X - boxW * 0.5
		local boxY = topVp.Y
		local vis = isVisible(camPos, head, char)
		local accent = vis and Color3.fromRGB(0, 255, 140) or Color3.fromRGB(255, 85, 85)

		if Config.ShowBox and entry.box then
			entry.box.Size = Vector2.new(boxW, boxH)
			entry.box.Position = Vector2.new(boxX, boxY)
			entry.box.Color = accent
			entry.box.Visible = true
		elseif entry.box then
			entry.box.Visible = false
		end

		if Config.ShowHealth and entry.hpBg and entry.hpBar then
			local ratio = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
			local barX = boxX - 6
			entry.hpBg.From = Vector2.new(barX, boxY)
			entry.hpBg.To = Vector2.new(barX, boxY + boxH)
			entry.hpBg.Visible = true

			entry.hpBar.From = Vector2.new(barX, boxY + boxH * (1 - ratio))
			entry.hpBar.To = Vector2.new(barX, boxY + boxH)
			entry.hpBar.Color = Color3.fromRGB(255 * (1 - ratio), 255 * ratio, 60)
			entry.hpBar.Visible = true
		elseif entry.hpBg and entry.hpBar then
			entry.hpBg.Visible = false
			entry.hpBar.Visible = false
		end

		if Config.ShowTracers and entry.tracer then
			entry.tracer.From = bottomCenter
			entry.tracer.To = Vector2.new(rootVp.X, boxY + boxH)
			entry.tracer.Color = accent
			entry.tracer.Visible = true
		elseif entry.tracer then
			entry.tracer.Visible = false
		end

		if Config.ShowInfo and entry.label then
			local dist = math.floor((root.Position - camPos).Magnitude)
			entry.label.Text = string.format("%s [%dHP] %dm", plr.Name, math.floor(hum.Health), dist)
			entry.label.Position = Vector2.new(rootVp.X, boxY - 16)
			entry.label.Visible = true
		elseif entry.label then
			entry.label.Visible = false
		end

		if Config.ShowSkeleton then
			local pairsList = char:FindFirstChild("UpperTorso") and R15_BONES or R6_BONES
			for i, line in ipairs(entry.bones) do
				local pair = pairsList[i]
				local p0 = pair and char:FindFirstChild(pair[1])
				local p1 = pair and char:FindFirstChild(pair[2])
				if p0 and p1 then
					local v0, ok0 = Camera:WorldToViewportPoint(p0.Position)
					local v1, ok1 = Camera:WorldToViewportPoint(p1.Position)
					if ok0 and ok1 and v0.Z > 0 and v1.Z > 0 then
						line.From = Vector2.new(v0.X, v0.Y)
						line.To = Vector2.new(v1.X, v1.Y)
						line.Color = Color3.fromRGB(235, 245, 255)
						line.Visible = true
					else
						line.Visible = false
					end
				else
					line.Visible = false
				end
			end
		else
			for _, line in ipairs(entry.bones) do line.Visible = false end
		end
	end
end

local function setFullbright(on)
	if on then
		Lighting.Ambient = Color3.new(1, 1, 1)
		Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
		Lighting.Brightness = 2
		Lighting.GlobalShadows = false
	else
		Lighting.Ambient = LightingOrig.Ambient
		Lighting.OutdoorAmbient = LightingOrig.OutdoorAmbient
		Lighting.Brightness = LightingOrig.Brightness
		Lighting.GlobalShadows = LightingOrig.GlobalShadows
	end
end

local function applyNoclip()
	if not Config.Noclip then return end
	local char = LocalPlayer.Character
	if not char then return end
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide then
			part.CanCollide = false
		end
	end
end

local function applyMovement()
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	if Config.SpeedEnabled then
		local spd = Config.WalkSpeed
		if Config.SafeLatencyJitter then
			spd += math.sin(os.clock() * 9.0) * 1.25
		end
		hum.WalkSpeed = math.max(16, spd)
	end
	if Config.JumpEnabled then
		hum.UseJumpPower = true
		hum.JumpPower = Config.JumpPower
	end
end

local function serverHop()
	pcall(function()
		local url = string.format("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100", game.PlaceId)
		local raw = game:HttpGet(url)
		local data = HttpService:JSONDecode(raw)
		for _, srv in ipairs(data.data or {}) do
			if srv.playing < srv.maxPlayers and srv.id ~= game.JobId then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, srv.id, LocalPlayer)
				return
			end
		end
		TeleportService:Teleport(game.PlaceId, LocalPlayer)
	end)
end

-- tabbed menu (AIM / VISUALS / SERVER / GUARD)
local gui = Instance.new("ScreenGui")
gui.Name = "C4DeltaHub"
gui.ResetOnSpawn = false
pcall(function() gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end)

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(320, 340)
main.Position = UDim2.fromOffset(30, 100)
main.BackgroundColor3 = Color3.fromRGB(16, 18, 22)
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui

local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, 0, 0, 28)
tabBar.BackgroundColor3 = Color3.fromRGB(24, 27, 33)
tabBar.BorderSizePixel = 0
tabBar.Parent = main

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Parent = tabBar

local pages = {}
local function makePage(name)
	local p = Instance.new("ScrollingFrame")
	p.Name = name
	p.Size = UDim2.new(1, -12, 1, -36)
	p.Position = UDim2.fromOffset(6, 32)
	p.BackgroundTransparency = 1
	p.ScrollBarThickness = 4
	p.CanvasSize = UDim2.fromOffset(0, 440)
	p.Visible = false
	p.Parent = main

	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, 6)
	l.Parent = p
	pages[name] = p
	return p
end

local aimPage = makePage("AIM")
local visPage = makePage("VISUALS")
local srvPage = makePage("SERVER")
local grdPage = makePage("GUARD")
aimPage.Visible = true

local function makeTab(label, targetPage)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0.25, 0, 1, 0)
	b.BackgroundColor3 = Color3.fromRGB(30, 34, 42)
	b.TextColor3 = Color3.fromRGB(235, 240, 248)
	b.Font = Enum.Font.Code
	b.TextSize = 11
	b.Text = label
	b.Parent = tabBar
	b.MouseButton1Click:Connect(function()
		for _, pg in pairs(pages) do pg.Visible = false end
		targetPage.Visible = true
	end)
end

makeTab("AIM", aimPage)
makeTab("VISUALS", visPage)
makeTab("SERVER", srvPage)
makeTab("GUARD", grdPage)

local function addToggle(parent, text, getter, setter)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 26)
	b.BackgroundColor3 = Color3.fromRGB(30, 34, 42)
	b.TextColor3 = Color3.fromRGB(240, 245, 250)
	b.Font = Enum.Font.Code
	b.TextSize = 12
	b.Parent = parent

	local function refresh()
		local on = getter()
		b.Text = string.format("[%s] %s", on and "ON" or "OFF", text)
		b.BackgroundColor3 = on and Color3.fromRGB(25, 82, 56) or Color3.fromRGB(30, 34, 42)
	end

	b.MouseButton1Click:Connect(function()
		setter(not getter())
		refresh()
	end)
	refresh()
end

local function addAction(parent, text, fn)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 26)
	b.BackgroundColor3 = Color3.fromRGB(45, 52, 68)
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.Font = Enum.Font.Code
	b.TextSize = 12
	b.Text = text
	b.Parent = parent
	b.MouseButton1Click:Connect(fn)
end

-- AIM tab
addToggle(aimPage, "MASTER HUB", function() return Config.Master end, function(v) Config.Master = v end)
addToggle(aimPage, "AIMBOT", function() return Config.AimEnabled end, function(v) Config.AimEnabled = v end)
addToggle(aimPage, "TEAM CHECK", function() return Config.TeamCheck end, function(v) Config.TeamCheck = v end)
addToggle(aimPage, "WALL CHECK", function() return Config.WallCheck end, function(v) Config.WallCheck = v end)
addToggle(aimPage, "FOV CIRCLE", function() return Config.ShowFov end, function(v) Config.ShowFov = v end)

-- VISUALS tab
addToggle(visPage, "ESP MASTER", function() return Config.EspEnabled end, function(v) Config.EspEnabled = v end)
addToggle(visPage, "BOX ESP", function() return Config.ShowBox end, function(v) Config.ShowBox = v end)
addToggle(visPage, "SKELETON ESP", function() return Config.ShowSkeleton end, function(v) Config.ShowSkeleton = v end)
addToggle(visPage, "HEALTH BAR", function() return Config.ShowHealth end, function(v) Config.ShowHealth = v end)
addToggle(visPage, "TRACERS", function() return Config.ShowTracers end, function(v) Config.ShowTracers = v end)
addToggle(visPage, "NAME / HP / DIST", function() return Config.ShowInfo end, function(v) Config.ShowInfo = v end)
addToggle(visPage, "FULLBRIGHT", function() return Config.Fullbright end, function(v)
	Config.Fullbright = v
	setFullbright(v)
end)

-- SERVER tab
addToggle(srvPage, "NOCLIP", function() return Config.Noclip end, function(v) Config.Noclip = v end)
addToggle(srvPage, "INF JUMP", function() return Config.InfJump end, function(v) Config.InfJump = v end)
addToggle(srvPage, "SPEED HACK", function() return Config.SpeedEnabled end, function(v) Config.SpeedEnabled = v end)
addToggle(srvPage, "JUMP BOOST", function() return Config.JumpEnabled end, function(v) Config.JumpEnabled = v end)
addAction(srvPage, "SERVER HOP", serverHop)
addAction(srvPage, "REJOIN SERVER", function()
	TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
end)

-- GUARD tab
addToggle(grdPage, "ANTI-KICK", function() return Config.AntiKick end, function(v) Config.AntiKick = v end)
addToggle(grdPage, "BLOCK ERROR REPORT", function() return Config.BlockErrorReport end, function(v) Config.BlockErrorReport = v end)
addToggle(grdPage, "SPEED JITTER", function() return Config.SafeLatencyJitter end, function(v) Config.SafeLatencyJitter = v end)
addAction(grdPage, "PANIC HOP", serverHop)

UserInputService.JumpRequest:Connect(function()
	if Config.Master and Config.InfJump then
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
	end
end)

UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.KeyCode == Enum.KeyCode.Insert then
		main.Visible = not main.Visible
	end
end)

Players.PlayerRemoving:Connect(function(plr)
	if EspCache[plr] then
		destroyEspEntry(EspCache[plr])
		EspCache[plr] = nil
	end
end)

RunService.Stepped:Connect(function()
	if Config.Master then
		applyNoclip()
	end
end)

RunService.RenderStepped:Connect(function()
	Camera = Workspace.CurrentCamera
	if not Camera then return end

	if FovCircle then
		FovCircle.Visible = Config.Master and Config.ShowFov
		FovCircle.Position = UserInputService:GetMouseLocation()
		FovCircle.Radius = Config.FovRadius
	end

	updateEsp()

	if Config.Master then
		applyMovement()
		if Config.AimEnabled and UserInputService:IsMouseButtonPressed(Config.AimKey) then
			aimAt(getClosestTarget())
		end
	end
end)
