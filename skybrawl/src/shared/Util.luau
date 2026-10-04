--[[
    Small helpers shared by server and client.
]]

local Util = {}

-- Signal ------------------------------------------------------------------

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(fn)
	local handler = { fn = fn, connected = true }
	table.insert(self._handlers, handler)
	local handlers = self._handlers
	return {
		Disconnect = function()
			handler.connected = false
			local index = table.find(handlers, handler)
			if index then
				table.remove(handlers, index)
			end
		end,
	}
end

function Signal:Fire(...)
	for _, handler in table.clone(self._handlers) do
		if handler.connected then
			task.spawn(handler.fn, ...)
		end
	end
end

Util.Signal = Signal

-- Tables ------------------------------------------------------------------

function Util.deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = Util.deepCopy(v)
	end
	return out
end

-- Fills missing keys in `target` from `defaults` (recursively).
function Util.reconcile(target, defaults)
	for k, v in defaults do
		if target[k] == nil then
			target[k] = Util.deepCopy(v)
		elseif type(v) == "table" and type(target[k]) == "table" then
			Util.reconcile(target[k], v)
		end
	end
	return target
end

function Util.shuffle(list, rng)
	rng = rng or Random.new()
	for i = #list, 2, -1 do
		local j = rng:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

function Util.pick(list, rng)
	rng = rng or Random.new()
	return list[rng:NextInteger(1, #list)]
end

-- Formatting --------------------------------------------------------------

function Util.formatTime(seconds)
	seconds = math.max(0, math.floor(seconds + 0.5))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

function Util.formatNumber(n)
	local s = tostring(math.floor(n))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return formatted
end

local CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

function Util.randomCode(length, rng)
	rng = rng or Random.new()
	local chars = table.create(length)
	for i = 1, length do
		local index = rng:NextInteger(1, #CODE_CHARS)
		chars[i] = CODE_CHARS:sub(index, index)
	end
	return table.concat(chars)
end

-- Characters --------------------------------------------------------------

-- Distance from HumanoidRootPart's center down to the soles of the feet.
function Util.feetOffset(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		return 3
	end
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		return humanoid.HipHeight + root.Size.Y / 2
	end
	local leg = model:FindFirstChild("Left Leg")
	return root.Size.Y / 2 + (leg and leg.Size.Y or 2)
end

-- The hand a weapon goes in: the legend rig's hand if it has one.
function Util.getHand(model, side)
	local rig = model:FindFirstChild("VisualRig")
	if rig then
		local hand = rig:FindFirstChild(side == "Left" and "LeftHand" or "RightHand")
		if hand then
			return hand
		end
	end
	if side == "Left" then
		return model:FindFirstChild("LeftHand") or model:FindFirstChild("Left Arm")
	end
	return model:FindFirstChild("RightHand") or model:FindFirstChild("Right Arm")
end

-- Root CFrame for a fighter whose feet are at local (x, y), facing ±X.
function Util.fighterCFrame(origin, x, y, feetOffset, facing)
	local pos = origin + Vector3.new(x, y + feetOffset, 0)
	return CFrame.lookAt(pos, pos + Vector3.new(facing >= 0 and 1 or -1, 0, 0))
end

return Util
