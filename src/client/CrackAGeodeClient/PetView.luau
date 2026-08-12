-- PetView: renders the local player's equipped rebirth pet as a glowing
-- companion that hovers beside the avatar and bobs. Driven by snapshot.pets.active.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local PetView = {}
local player = Players.LocalPlayer
local current = nil -- { model, body, name }

function PetView.Set(active)
	if not active then
		if current then current.model:Destroy() end
		current = nil
		return
	end
	if current and current.name == active.name then return end -- unchanged
	if current then current.model:Destroy() end

	local color = Color3.fromRGB(active.color[1], active.color[2], active.color[3])
	local model = Instance.new("Model")
	model.Name = "GeodePet"
	local body = Instance.new("Part")
	body.Shape = Enum.PartType.Ball
	body.Size = Vector3.new(1.9, 1.9, 1.9)
	body.Material = Enum.Material.Neon
	body.Color = color
	body.Anchored = true
	body.CanCollide = false
	body.CanQuery = false
	body.CanTouch = false
	body.CastShadow = false
	body.Parent = model
	local pl = Instance.new("PointLight")
	pl.Color = color; pl.Range = 7; pl.Brightness = 1.2; pl.Parent = body
	local att = Instance.new("Attachment"); att.Parent = body
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(color); pe.Rate = 8; pe.LightEmission = 1
	pe.Lifetime = NumberRange.new(0.6, 1.1); pe.Speed = NumberRange.new(0.5, 1.5)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	pe.Parent = att
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(4, 1.3); bb.StudsOffset = Vector3.new(0, 2, 0)
	bb.AlwaysOnTop = true; bb.MaxDistance = 90; bb.Parent = body
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1); tl.BackgroundTransparency = 1
	tl.Text = active.emoji .. " " .. active.name
	tl.TextColor3 = color; tl.TextStrokeTransparency = 0.2; tl.TextScaled = true
	tl.Font = Enum.Font.GothamBold; tl.Parent = bb

	model.Parent = workspace.CurrentCamera
	current = { model = model, body = body, name = active.name }
end

function PetView.Init()
	RunService.RenderStepped:Connect(function()
		if not current then return end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		local t = os.clock()
		-- hover to the player's right-and-behind, gently bobbing
		local target = hrp.CFrame * CFrame.new(3.4, 1.3 + math.sin(t * 2) * 0.4, 2.6)
		current.body.CFrame = current.body.CFrame:Lerp(target, 0.14)
	end)
end

return PetView
