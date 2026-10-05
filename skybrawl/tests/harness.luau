--[[
    Loads Skybrawl's shared modules outside Roblox (under Lune) by faking
    `script.Parent.X` requires and providing Roblox datatypes.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local harness = {}

-- Lune has no Random datatype; a small deterministic stand-in.
local RandomShim = {}
RandomShim.__index = RandomShim

function RandomShim.new(seed)
	return setmetatable({ state = math.max(1, math.floor(seed or 12345) % 2147483647) }, RandomShim)
end

function RandomShim:_next()
	self.state = (self.state * 48271) % 2147483647
	return self.state / 2147483647
end

function RandomShim:NextNumber(min, max)
	min, max = min or 0, max or 1
	return min + (max - min) * self:_next()
end

function RandomShim:NextInteger(min, max)
	return math.min(max, math.floor(min + (max - min + 1) * self:_next()))
end

local root = process.cwd .. "/src/shared/"
local cache = {}
local loadModule

-- Just enough of `game` for modules that do
-- game:GetService("ReplicatedStorage"):WaitForChild("Shared").X
local sharedProxy = setmetatable({}, {
	__index = function(_, child)
		return { __module = child }
	end,
})
local fakeGame = {
	GetService = function()
		return {
			WaitForChild = function()
				return sharedProxy
			end,
		}
	end,
}

local function loadFile(path, name, globals, folder)
	local source = fs.readFile(path)
	local parent = setmetatable({}, {
		__index = function(_, child)
			return { __module = child }
		end,
	})
	-- A folder module's init.luau requires its children as script.<Child>.
	local script = { Parent = parent, Name = name }
	if folder then
		setmetatable(script, {
			__index = function(_, child)
				return { __module = folder .. "/" .. child }
			end,
		})
	end
	local env = {
		script = script,
		game = fakeGame,
		require = function(target)
			return loadModule(target.__module)
		end,
		Color3 = roblox.Color3,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		CFrame = roblox.CFrame,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
		Instance = roblox.Instance,
		Random = RandomShim,
	}
	for key, value in globals or {} do
		env[key] = value
	end
	local chunk = luau.load(source, { debugName = name, environment = env })
	return chunk()
end

function loadModule(name)
	if cache[name] == nil then
		local path = root .. name .. ".luau"
		if fs.isFile(path) then
			cache[name] = loadFile(path, name)
		else
			-- a folder module (src/shared/<name>/init.luau)
			cache[name] = loadFile(root .. name .. "/init.luau", name, nil, name)
		end
	end
	return cache[name]
end

harness.require = loadModule

-- Loads a server module (its own requires still resolve to shared modules).
function harness.requireServer(name)
	return loadFile(process.cwd .. "/src/server/Services/" .. name .. ".luau", name)
end

-- Loads a client controller. `globals` adds or replaces globals (game,
-- workspace, Instance, Enum, ...) with the test's own fakes.
function harness.requireClient(name, globals)
	return loadFile(process.cwd .. "/src/client/Controllers/" .. name .. ".luau", name, globals)
end

local passed, failed = 0, 0

function harness.test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("  ok   " .. name)
	else
		failed += 1
		print("  FAIL " .. name .. "\n       " .. tostring(err))
	end
end

function harness.expect(cond, message)
	if not cond then
		error(message or "expectation failed", 2)
	end
end

function harness.near(a, b, tolerance, message)
	if math.abs(a - b) > tolerance then
		error(string.format("%s: expected %.3f to be within %.3f of %.3f", message or "near", a, tolerance, b), 2)
	end
end

function harness.finish()
	print(string.format("\n%d passed, %d failed", passed, failed))
	if failed > 0 then
		process.exit(1)
	end
end

return harness
