-- run in Delta executor (Luau)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local Config = {
	Master = false,
	AimEnabled = true,
	StickyTarget = true,
	TeamCheck = true,
	WallCheck = true,
	ShowFov = true,
	FovRadius = 150,
	FovStep = 25,
	MinFov = 30,
	MaxFov = 500,
	Smoothing = 0.22,
	Prediction = 0.135,
	TargetPart = "Head",
	AimKey = Enum.UserInputType.MouseButton2,
	ToggleMenuKey = Enum.KeyCode.LeftControl,
	FovUpKey = Enum.KeyCode.Equals,
	FovDownKey = Enum.KeyCode.Minus,
}

local LockedPart = nil

local hasDrawing = pcall(function()
	local d = Drawing.new("Circle")
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

local function getScreenCenter()
	local vp = Camera and Camera.ViewportSize or Vector2.new(1280, 720)
	return Vector2.new(vp.X * 0.5, vp.Y * 0.5)
end

local function setFovRadius(val)
	Config.FovRadius = math.clamp(val, Config.MinFov, Config.MaxFov)
end

local function isTeammate(plr)
	if not Config.TeamCheck then return false end
	if LocalPlayer.Neutral or plr.Neutral then return false end
	return LocalPlayer.Team ~= nil and plr.Team == LocalPlayer.Team
end

local function isVisible(origin, targetPart, char)
	if not Config.WallCheck then return true end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
	table.insert(ignore, char)
	params.FilterDescendantsInstances = ignore
	local hit = Workspace:Raycast(origin, targetPart.Position - origin, params)
	return hit == nil or hit.Instance:IsDescendantOf(char)
end

local function isValidPart(part)
	if not part or not part:IsA("BasePart") or not part.Parent then return false end
	local char = part.Parent
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false end
	local plr = Players:GetPlayerFromCharacter(char)
	if plr and (plr == LocalPlayer or isTeammate(plr)) then return false end
	return true
end

local function getClosestTarget()
	local center = getScreenCenter()

	if Config.StickyTarget and isValidPart(LockedPart) then
		local char = LockedPart.Parent
		local pred = LockedPart.Position + (LockedPart.AssemblyLinearVelocity or Vector3.zero) * Config.Prediction
		local sp, onScreen = Camera:WorldToViewportPoint(pred)
		if onScreen and sp.Z > 0 then
			local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
			if d <= Config.FovRadius * 1.25 and isVisible(Camera.CFrame.Position, LockedPart, char) then
				return LockedPart
			end
		end
	end

	local bestPart = nil
	local bestDist = Config.FovRadius

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer and not isTeammate(plr) then
			local char = plr.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local part = char and (char:FindFirstChild(Config.TargetPart) or char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
			if hum and hum.Health > 0 and part then
				local pred = part.Position + (part.AssemblyLinearVelocity or Vector3.zero) * Config.Prediction
				local sp, onScreen = Camera:WorldToViewportPoint(pred)
				if onScreen and sp.Z > 0 then
					local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
					if d < bestDist and isVisible(Camera.CFrame.Position, part, char) then
						bestDist = d
						bestPart = part
					end
				end
			end
		end
	end

	LockedPart = bestPart
	return bestPart
end

local function aimAt(targetPart)
	if not targetPart then return end
	local pred = targetPart.Position + (targetPart.AssemblyLinearVelocity or Vector3.zero) * Config.Prediction
	local desired = CFrame.lookAt(Camera.CFrame.Position, pred)
	Camera.CFrame = Camera.CFrame:Lerp(desired, math.clamp(Config.Smoothing, 0.01, 1))
end

-- compact menu toggled via LeftControl
local gui = Instance.new("ScreenGui")
gui.Name = "C4AimMenu"
gui.ResetOnSpawn = false
pcall(function() gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end)

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(230, 220)
frame.Position = UDim2.fromOffset(24, 120)
frame.BackgroundColor3 = Color3.fromRGB(16, 18, 22)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Visible = false
frame.Parent = gui

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.Parent = frame

local fovBtn = Instance.new("TextButton")
fovBtn.Size = UDim2.new(1, 0, 0, 26)
fovBtn.BackgroundColor3 = Color3.fromRGB(30, 34, 42)
fovBtn.TextColor3 = Color3.fromRGB(240, 245, 250)
fovBtn.Font = Enum.Font.Code
fovBtn.TextSize = 12
fovBtn.Parent = frame

local function refreshFovLabel()
	fovBtn.Text = string.format("FOV: %d px ([-] / [+])", Config.FovRadius)
end
refreshFovLabel()

fovBtn.MouseButton1Click:Connect(function()
	setFovRadius(Config.FovRadius + Config.FovStep)
	refreshFovLabel()
end)

fovBtn.MouseButton2Click:Connect(function()
	setFovRadius(Config.FovRadius - Config.FovStep)
	refreshFovLabel()
end)

local function addToggle(label, getter, setter)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 26)
	b.BackgroundColor3 = Color3.fromRGB(30, 34, 42)
	b.TextColor3 = Color3.fromRGB(240, 245, 250)
	b.Font = Enum.Font.Code
	b.TextSize = 12
	b.Parent = frame

	local function refresh()
		local on = getter()
		b.Text = string.format("[%s] %s", on and "ON" or "OFF", label)
		b.BackgroundColor3 = on and Color3.fromRGB(25, 82, 56) or Color3.fromRGB(30, 34, 42)
	end

	b.MouseButton1Click:Connect(function()
		setter(not getter())
		refresh()
	end)
	refresh()
end

addToggle("MASTER", function() return Config.Master end, function(v) Config.Master = v end)
addToggle("AIMBOT", function() return Config.AimEnabled end, function(v) Config.AimEnabled = v end)
addToggle("STICKY LOCK", function() return Config.StickyTarget end, function(v)
	Config.StickyTarget = v
	if not v then LockedPart = nil end
end)
addToggle("WALL CHECK", function() return Config.WallCheck end, function(v) Config.WallCheck = v end)
addToggle("TEAM CHECK", function() return Config.TeamCheck end, function(v) Config.TeamCheck = v end)
addToggle("FOV CIRCLE", function() return Config.ShowFov end, function(v) Config.ShowFov = v end)

UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.KeyCode == Config.ToggleMenuKey then
		frame.Visible = not frame.Visible
	elseif input.KeyCode == Config.FovUpKey then
		setFovRadius(Config.FovRadius + Config.FovStep)
		refreshFovLabel()
	elseif input.KeyCode == Config.FovDownKey then
		setFovRadius(Config.FovRadius - Config.FovStep)
		refreshFovLabel()
	end
end)

RunService.RenderStepped:Connect(function()
	Camera = Workspace.CurrentCamera
	if not Camera then return end

	local center = getScreenCenter()
	if FovCircle then
		FovCircle.Visible = Config.Master and Config.ShowFov
		FovCircle.Position = center
		FovCircle.Radius = Config.FovRadius
	end

	if Config.Master and Config.AimEnabled and UserInputService:IsMouseButtonPressed(Config.AimKey) then
		aimAt(getClosestTarget())
	else
		LockedPart = nil
	end
end)
