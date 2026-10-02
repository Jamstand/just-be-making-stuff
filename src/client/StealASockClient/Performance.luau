-- Performance: the settings that change the 3D world, on this client only (ClientSettings).
--  * lowGraphics: no global shadows; Bloom / DepthOfField / SunRays off and the Atmosphere's haze and
--    glare off; every ParticleEmitter under workspace runs at 35% of its rate (including emitters
--    that appear later); lights lose their shadows and only the 12 nearest the camera stay on
--    (re-checked every 3 s). Turning it off puts back exactly what was changed - unless the game
--    changed that value itself in the meantime, which then wins.
--  * sockLabels "All" / "Mine" / "Off": the floating name tag on each sock model (the "NameLabel"
--    BillboardGui Factory puts on the Leg). "Mine" = socks whose OwnerId is this player; follows
--    socks that stream in later and OwnerId changes (a sock moving into or out of your drawer).
--  * hideOthersFX is read by SockFX itself (bursts far from you, other players' outlines).
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")

local ClientSettings = require(script.Parent:WaitForChild("ClientSettings"))

local Performance = {}

local player = Players.LocalPlayer
local PARTICLE_FACTOR = 0.35
local LIGHT_BUDGET = 12
local LIGHT_CHECK = 3 -- seconds

-- ---------- low graphics ----------

local low = false
local lowToken = 0
local conns = {} :: { RBXScriptConnection }
local lights = {} :: { Light }
local tracked = {} :: { [Light]: boolean }
-- property overrides on Lighting and its effects: what it was, and what we set
local saved = {} :: { [Instance]: { [string]: { from: any, to: any } } }

local function override(inst: Instance, prop: string, value: any)
	local entry = saved[inst]
	if not entry then
		entry = {}
		saved[inst] = entry
	end
	local current = (inst :: any)[prop]
	if entry[prop] == nil then
		entry[prop] = { from = current, to = value }
	else
		entry[prop].to = value
	end
	if current ~= value then
		(inst :: any)[prop] = value
	end
end

local function restoreOverrides()
	for inst, props in pairs(saved) do
		for prop, rec in pairs(props) do
			-- only put it back if it still holds our value (the game may have changed it since)
			if (inst :: any)[prop] == rec.to then
				(inst :: any)[prop] = rec.from
			end
		end
	end
	table.clear(saved)
end

local function lowEffect(inst: Instance)
	if inst:IsA("BloomEffect") or inst:IsA("DepthOfFieldEffect") or inst:IsA("SunRaysEffect") then
		override(inst, "Enabled", false)
	elseif inst:IsA("Atmosphere") then
		override(inst, "Haze", 0)
		override(inst, "Glare", 0)
	end
end

local function lowEmitter(e: ParticleEmitter)
	if e:GetAttribute("PerfRate") == nil then
		e:SetAttribute("PerfRate", e.Rate)
		e.Rate = e.Rate * PARTICLE_FACTOR
	end
end

local function restoreEmitter(e: ParticleEmitter)
	local original = e:GetAttribute("PerfRate")
	if typeof(original) == "number" then
		if math.abs(e.Rate - original * PARTICLE_FACTOR) < 1e-3 then
			e.Rate = original
		end
		e:SetAttribute("PerfRate", nil)
	end
end

local function trackLight(l: Light)
	if tracked[l] then
		return
	end
	tracked[l] = true
	table.insert(lights, l)
	if l.Shadows then
		l:SetAttribute("PerfShadows", true)
		l.Shadows = false
	end
end

local function restoreLight(l: Light)
	if l:GetAttribute("PerfShadows") then
		l.Shadows = true
		l:SetAttribute("PerfShadows", nil)
	end
	if l:GetAttribute("PerfOff") then
		l.Enabled = true
		l:SetAttribute("PerfOff", nil)
	end
end

local function onDescendant(d: Instance)
	if d:IsA("ParticleEmitter") then
		lowEmitter(d)
	elseif d:IsA("Light") then
		trackLight(d)
	end
end

local function lightPosition(l: Light): Vector3?
	local parent = l.Parent
	if parent and parent:IsA("BasePart") then
		return parent.Position
	elseif parent and parent:IsA("Attachment") then
		return parent.WorldPosition
	end
	return nil
end

-- Keeps the LIGHT_BUDGET lights nearest the camera on; turns off (and marks) the rest. Lights the
-- game itself switched off are left alone.
local function budgetLights()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local camPos = camera.CFrame.Position
	local ranked = {}
	local kept = {} :: { Light }
	for _, l in ipairs(lights) do
		if l.Parent and l:IsDescendantOf(workspace) then
			table.insert(kept, l)
			if l.Enabled or l:GetAttribute("PerfOff") then
				local pos = lightPosition(l)
				table.insert(ranked, { light = l, d = if pos then (pos - camPos).Magnitude else math.huge })
			end
		else
			tracked[l] = nil
		end
	end
	lights = kept
	table.sort(ranked, function(a, b)
		return a.d < b.d
	end)
	for i, entry in ipairs(ranked) do
		local l = entry.light
		if i <= LIGHT_BUDGET then
			if l:GetAttribute("PerfOff") then
				l:SetAttribute("PerfOff", nil)
				l.Enabled = true
			end
		elseif l.Enabled then
			l:SetAttribute("PerfOff", true)
			l.Enabled = false
		end
	end
end

local function setLow(on: boolean)
	if on == low then
		return
	end
	low = on
	lowToken += 1
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
	if on then
		override(Lighting, "GlobalShadows", false)
		for _, child in ipairs(Lighting:GetChildren()) do
			lowEffect(child)
		end
		table.insert(conns, Lighting.ChildAdded:Connect(lowEffect))
		for _, d in ipairs(workspace:GetDescendants()) do
			onDescendant(d)
		end
		table.insert(conns, workspace.DescendantAdded:Connect(onDescendant))
		local token = lowToken
		task.spawn(function()
			while low and token == lowToken do
				budgetLights()
				task.wait(LIGHT_CHECK)
			end
		end)
	else
		restoreOverrides()
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("ParticleEmitter") then
				restoreEmitter(d)
			elseif d:IsA("Light") then
				restoreLight(d)
			end
		end
		table.clear(lights)
		table.clear(tracked)
	end
end

-- ---------- sock name tags ----------

local labelMode = "All"

local function nameLabel(model: Instance): BillboardGui?
	local leg = model:FindFirstChild("Leg")
	local gui = (leg and leg:FindFirstChild("NameLabel")) or model:FindFirstChild("NameLabel", true)
	if gui and gui:IsA("BillboardGui") then
		return gui
	end
	return nil
end

local function applyLabel(model: Instance)
	local gui = nameLabel(model)
	if gui then
		gui.Enabled = labelMode == "All" or (labelMode == "Mine" and model:GetAttribute("OwnerId") == player.UserId)
	end
end

local function watchSock(model: Instance)
	applyLabel(model)
	model:GetAttributeChangedSignal("OwnerId"):Connect(function()
		applyLabel(model)
	end)
	-- with streaming the Leg (and its label) can arrive after the model
	model.DescendantAdded:Connect(function(d)
		if d.Name == "NameLabel" and d:IsA("BillboardGui") then
			applyLabel(model)
		end
	end)
end

local function setLabels(mode: any)
	local valid = mode == "All" or mode == "Mine" or mode == "Off"
	local nextMode = if valid then mode else "All"
	if nextMode == labelMode then
		return
	end
	labelMode = nextMode
	for _, model in ipairs(CollectionService:GetTagged("Sock")) do
		applyLabel(model)
	end
end

-- ---------- public API ----------

function Performance.Init()
	for _, model in ipairs(CollectionService:GetTagged("Sock")) do
		watchSock(model)
	end
	CollectionService:GetInstanceAddedSignal("Sock"):Connect(watchSock)

	setLabels(ClientSettings.Get("sockLabels"))
	setLow(ClientSettings.Get("lowGraphics") == true)
	ClientSettings.Changed:Connect(function(key, value)
		if key == "lowGraphics" then
			setLow(value == true)
		elseif key == "sockLabels" then
			setLabels(value)
		end
	end)
end

return Performance
