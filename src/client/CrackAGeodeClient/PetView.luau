-- PetView: renders the local player's equipped rebirth pet as a glowing
-- companion that hovers beside the avatar and bobs. Driven by snapshot.pets.active.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local PetView = {}
local player = Players.LocalPlayer
local current = nil -- { model, body, name }

-- Build a small faceted crystal-golem model themed to `color`. Parts are anchored
-- and stored with a local offset from the pet's origin; PetView.Init moves the whole
-- golem by re-placing each part relative to a smoothed origin CFrame each frame.
function PetView.Set(active)
	if not active then
		if current then current.model:Destroy() end
		current = nil
		return
	end
	if current and current.name == active.name then return end -- unchanged
	if current then current.model:Destroy() end

	local color = Color3.fromRGB(active.color[1], active.color[2], active.color[3])
	local light = color:Lerp(Color3.new(1, 1, 1), 0.3)
	local bright = color:Lerp(Color3.new(1, 1, 1), 0.55)
	local dark = color:Lerp(Color3.fromRGB(35, 32, 55), 0.45) -- shade toward deep slate, not black

	local model = Instance.new("Model")
	model.Name = "GeodePet"
	local parts = {}
	local function crystal(size, offset, col, mat)
		local p = Instance.new("Part")
		p.Size = size
		p.Material = mat or Enum.Material.Glass -- real specular glint; Neon only for true emissives
		if p.Material == Enum.Material.Glass then
			p.Reflectance = 0.08
			p.Transparency = 0.08
		end
		p.Color = col
		p.Anchored = true
		p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
		p.Parent = model
		parts[#parts + 1] = { p, offset }
		return p
	end

	-- Authored mesh template (ReplicatedStorage.PetModels.<pet name>) wins; the
	-- procedural crystal golem below is the fallback for pets without one yet.
	local tmplFolder = game:GetService("ReplicatedStorage"):FindFirstChild("PetModels")
	local tmpl = tmplFolder and tmplFolder:FindFirstChild(active.name)
	local torso
	if tmpl then
		local m = tmpl:Clone()
		local pivot = m:GetPivot()
		local moved = {}
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") then moved[#moved + 1] = d end
		end
		for _, d in ipairs(moved) do
			d.Anchored = true
			d.CanCollide = false; d.CanQuery = false; d.CanTouch = false; d.CastShadow = false
			parts[#parts + 1] = { d, pivot:ToObjectSpace(d.CFrame) }
			d.Parent = model
			if not torso or d.Size.Magnitude > torso.Size.Magnitude then torso = d end
		end
		m:Destroy()
	end

	if not tmpl then
		-- torso (faceted crystal block), then head + facial + limbs + back spikes
		torso = crystal(Vector3.new(1.25, 1.5, 0.95), CFrame.Angles(0, math.rad(12), math.rad(6)), color)
		crystal(Vector3.new(0.55, 0.72, 0.55), CFrame.new(0, 0.05, 0.42) * CFrame.Angles(0, 0, math.rad(45)), bright, Enum.Material.Neon) -- chest heart (true emissive)
		crystal(Vector3.new(0.85, 0.8, 0.8), CFrame.new(0, 1.15, 0) * CFrame.Angles(0, math.rad(-10), 0), light) -- head
		crystal(Vector3.new(0.15, 0.18, 0.1), CFrame.new(-0.2, 1.22, 0.4), bright, Enum.Material.Neon) -- L eye
		crystal(Vector3.new(0.15, 0.18, 0.1), CFrame.new(0.2, 1.22, 0.4), bright, Enum.Material.Neon)  -- R eye
		crystal(Vector3.new(0.32, 0.95, 0.32), CFrame.new(-0.82, 0.15, 0) * CFrame.Angles(0, 0, math.rad(28)), color) -- L arm
		crystal(Vector3.new(0.32, 0.95, 0.32), CFrame.new(0.82, 0.15, 0) * CFrame.Angles(0, 0, math.rad(-28)), color) -- R arm
		crystal(Vector3.new(0.36, 0.6, 0.36), CFrame.new(-0.34, -0.98, 0), dark) -- L leg
		crystal(Vector3.new(0.36, 0.6, 0.36), CFrame.new(0.34, -0.98, 0), dark)  -- R leg
		for i = 1, 3 do -- back / shoulder crystal spikes
			local hgt = 0.9 + i * 0.18
			local xx = ({ -0.5, 0.55, 0 })[i]
			crystal(Vector3.new(0.26, hgt, 0.26), CFrame.new(xx, 0.55, -0.42)
				* CFrame.Angles(math.rad(-24), math.rad((i - 2) * 20), math.rad((i - 2) * 10)), bright)
		end
	end

	-- glow + sparkle + name on the torso
	local pl = Instance.new("PointLight")
	pl.Color = color; pl.Range = 5; pl.Brightness = 0.8; pl.Shadows = false; pl.Parent = torso
	local att = Instance.new("Attachment"); att.Parent = torso
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(bright); pe.Rate = 6; pe.LightEmission = 1
	pe.Lifetime = NumberRange.new(0.6, 1.1); pe.Speed = NumberRange.new(0.4, 1.2)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0) })
	pe.Parent = att
	local bb = Instance.new("BillboardGui")
	-- name-tag sized, hugging the pet (QA: label floated detached over empty space)
	bb.Size = UDim2.fromScale(2.8, 0.8)
	bb.StudsOffset = Vector3.new(0, (torso and torso.Size.Y / 2 or 1) + 0.9, 0)
	bb.AlwaysOnTop = true; bb.MaxDistance = 60; bb.Parent = torso
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1); tl.BackgroundTransparency = 1
	tl.Text = active.emoji .. " " .. active.name
	tl.TextColor3 = light; tl.TextStrokeTransparency = 0.2; tl.TextScaled = true
	tl.Font = Enum.Font.GothamBold; tl.Parent = bb

	model.Parent = workspace.CurrentCamera
	current = { model = model, parts = parts, name = active.name, origin = nil }
end

function PetView.Init()
	RunService.RenderStepped:Connect(function()
		if not current then return end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		local t = os.clock()
		-- hover to the player's right-and-behind, gently bobbing + swaying
		-- closer, livelier hover: tighter follow offset, bigger bob, gentle sway
		local target = hrp.CFrame * CFrame.new(2.6, 1.5 + math.sin(t * 2.2) * 0.5, 1.9)
			* CFrame.Angles(math.rad(math.sin(t * 1.4) * 4), math.rad(math.sin(t * 0.8) * 16), 0)
		current.origin = current.origin and current.origin:Lerp(target, 0.14) or target
		for _, pd in ipairs(current.parts) do
			pd[1].CFrame = current.origin * pd[2]
		end
	end)
end

return PetView