--[[
    Loads Skybrawl's modules outside Roblox (under Lune) by faking
    `script.Parent.X` requires and providing Roblox datatypes.

      h.require(name)                     a shared module (src/shared), cached
      h.requireServer(name, globals?)     src/server/Services/<name>.luau
      h.requireClientFile(path, globals?) src/client/<path>.luau ("UI/Layout")
      h.requireClient(name, globals?)     src/client/Controllers/<name>.luau

    Server and client files are loaded fresh on every call. Inside them
    `script.Parent.X` (and `script.Parent.Parent.X`, WaitForChild,
    FindFirstChild, folders) resolves to the file X.luau there when it
    exists (loaded once per call, with the same globals), else to X/init.luau,
    else to the shared module X.

    Every load gets these globals (a test's `globals` replace them):
      task        @lune/task
      workspace   h.workspace: workspace:GetServerTimeNow() returns os.time()
      game        h.game (h.fakeGame()): GetService(name) returns one stub per
                  name. Players has PlayerAdded / PlayerRemoving signals,
                  GetPlayers(), LocalPlayer and _add(p) / _remove(p) to drive
                  them; RunService has Heartbeat / Stepped / PreRender signals;
                  ReplicatedStorage resolves Shared to the shared modules and
                  Remotes to fake remotes (h.remote(name)); everything else
                  answers WaitForChild with a shared-module proxy and
                  FindFirstChild with nil.
    A fake remote records every Fire*/Invoke* call in remote.calls
    ({ method, player?, args }) and has OnServerEvent / OnClientEvent signals
    a test can Fire; h.resetRemotes() starts them all afresh.

    h.fakeGame({ shared = { Net = fakeNet } }) builds a separate fake game
    whose Shared hands out the given values instead of those modules. Also:
    h.Random (the deterministic Random stand-in every load gets),
    h.signal() (a synchronous Signal) and h.fakePlayer(userId, name) (a
    stand-in Player whose Parent is h.game's Players).
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local harness = {}

-- Lune has no Random datatype; a small deterministic stand-in.
local RandomShim = {}
RandomShim.__index = RandomShim

function RandomShim.new(seed)
	-- Scramble the seed and skip a few draws, so nearby seeds (1, 2, 3...) don't start on nearly the same draw.
	local scrambled = ((math.floor(seed or 12345) % 2147483647) * 16807 + 12345) % 2147483647
	local self = setmetatable({ state = math.max(1, scrambled) }, RandomShim)
	for _ = 1, 3 do
		self:_next()
	end
	return self
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

harness.Random = RandomShim

-- Fakes ----------------------------------------------------------------------

-- A tiny Signal for fakes. Fire calls the handlers synchronously, in order; Wait yields until the next Fire.
function harness.signal()
	local handlers = {}
	local waiting = {}
	local signal = {}
	function signal:Connect(fn)
		local handler = { fn = fn }
		table.insert(handlers, handler)
		local connection = { Connected = true }
		function connection.Disconnect()
			connection.Connected = false
			local index = table.find(handlers, handler)
			if index then
				table.remove(handlers, index)
			end
		end
		return connection
	end
	function signal:Once(fn)
		local connection
		connection = self:Connect(function(...)
			connection.Disconnect()
			fn(...)
		end)
		return connection
	end
	function signal:Wait()
		table.insert(waiting, coroutine.running())
		return coroutine.yield()
	end
	function signal:Fire(...)
		for _, handler in table.clone(handlers) do
			if table.find(handlers, handler) then
				handler.fn(...)
			end
		end
		local threads = waiting
		waiting = {}
		for _, thread in threads do
			task.spawn(thread, ...)
		end
	end
	return signal
end

local function newPlayer(userId, name, parent)
	name = name or ("Player" .. tostring(userId))
	local attributes = {}
	local player = {
		Name = name,
		DisplayName = name,
		UserId = userId,
		ClassName = "Player",
		Parent = parent,
		_friends = {},
	}
	function player:IsFriendsWithAsync(otherId)
		return self._friends[otherId] == true
	end
	function player:GetAttribute(key)
		return attributes[key]
	end
	function player:SetAttribute(key, value)
		attributes[key] = value
	end
	function player:IsA(className)
		return className == "Player" or className == "Instance"
	end
	return player
end

--[[
    A stand-in Player: Name, DisplayName, UserId, IsFriendsWithAsync (friends
    in player._friends[userId]) and attributes. Parent is h.game's fake Players
    (so services see the player as on the server) without joining its list:
    players:_add(p) on any fake game adds it and sets Parent to that Players,
    players:_remove(p) fires PlayerRemoving and sets Parent to nil.
]]
function harness.fakePlayer(userId, name)
	return newPlayer(userId, name, harness.game:GetService("Players"))
end

local remotes = {}

local function newRemote(name)
	local remote = {
		Name = name,
		calls = {},
		OnServerEvent = harness.signal(),
		OnClientEvent = harness.signal(),
		OnServerInvoke = nil,
		OnClientInvoke = nil,
	}
	function remote:FireClient(player, ...)
		table.insert(self.calls, { method = "FireClient", player = player, args = table.pack(...) })
	end
	function remote:FireAllClients(...)
		table.insert(self.calls, { method = "FireAllClients", args = table.pack(...) })
	end
	function remote:FireServer(...)
		table.insert(self.calls, { method = "FireServer", args = table.pack(...) })
	end
	function remote:InvokeServer(...)
		table.insert(self.calls, { method = "InvokeServer", args = table.pack(...) })
		return nil
	end
	function remote:InvokeClient(player, ...)
		table.insert(self.calls, { method = "InvokeClient", player = player, args = table.pack(...) })
		return nil
	end
	return remote
end

-- The fake remote `name` (shared by every fake game).
function harness.remote(name)
	if not remotes[name] then
		remotes[name] = newRemote(name)
	end
	return remotes[name]
end

-- Forgets every recorded call and handler.
function harness.resetRemotes()
	table.clear(remotes)
end

local remotesFolder = {
	Name = "Remotes",
	WaitForChild = function(_, name)
		return harness.remote(name)
	end,
	FindFirstChild = function(_, name)
		return harness.remote(name)
	end,
}

-- A proxy whose children are shared-module references; `values` overrides some of them with plain values.
local function sharedFolder(values)
	return setmetatable({}, {
		__index = function(_, child)
			if values and values[child] ~= nil then
				return { __value = values[child] }
			end
			return { __module = child }
		end,
	})
end

local function newPlayers()
	local players = {
		Name = "Players",
		PlayerAdded = harness.signal(),
		PlayerRemoving = harness.signal(),
		_list = {},
	}
	players.LocalPlayer = newPlayer(1, "LocalPlayer", players)
	function players:GetPlayers()
		return table.clone(self._list)
	end
	function players:GetPlayerByUserId(userId)
		for _, player in self._list do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end
	-- test helpers: a player joins / leaves (fires the signal like Roblox does)
	function players:_add(player)
		table.insert(self._list, player)
		player.Parent = self
		self.PlayerAdded:Fire(player)
	end
	function players:_remove(player)
		self.PlayerRemoving:Fire(player)
		local index = table.find(self._list, player)
		if index then
			table.remove(self._list, index)
		end
		player.Parent = nil
	end
	return players
end

-- A fake `game`. opts.shared = { [moduleName] = value } replaces those shared modules in this game's Shared.
function harness.fakeGame(opts)
	opts = opts or {}
	local shared = sharedFolder(opts.shared)
	local services = {}
	local function genericService(name)
		return {
			Name = name,
			WaitForChild = function(_, child)
				if child == "Remotes" then
					return remotesFolder
				end
				return shared
			end,
			FindFirstChild = function(_, child)
				if child == "Shared" then
					return shared
				elseif child == "Remotes" then
					return remotesFolder
				end
				return nil
			end,
		}
	end
	local fake = {
		JobId = "harness",
		PlaceId = 0,
		Loaded = harness.signal(),
	}
	function fake:GetService(name)
		if not services[name] then
			local service
			if name == "Players" then
				service = newPlayers()
			elseif name == "RunService" then
				service = genericService(name)
				service.Heartbeat = harness.signal()
				service.Stepped = harness.signal()
				service.PreRender = harness.signal()
				service.IsStudio = function()
					return false
				end
				service.IsServer = function()
					return true
				end
				service.IsClient = function()
					return true
				end
			else
				service = genericService(name)
			end
			services[name] = service
		end
		return services[name]
	end
	function fake:IsLoaded()
		return true
	end
	function fake:BindToClose(_fn) end
	return fake
end

harness.game = harness.fakeGame()
harness.workspace = {
	Name = "Workspace",
	GetServerTimeNow = function()
		return os.time()
	end,
}

-- Loading -------------------------------------------------------------------

local cwd = process.cwd
if string.sub(cwd, -1) ~= "/" then
	cwd ..= "/"
end
local sharedRoot = cwd .. "src/shared/"
local cache = {}
local loadModule
local loadFile

--[[
    A lazy reference to a server/client file or folder by absolute path (no
    extension). Indexing it never touches the disk (Lune's fs calls yield,
    and a metamethod can't): `ref.Child`, `ref.Parent`, `ref:WaitForChild`
    just build more references, and require resolves them.
]]
local refMeta = {}

local function makeRef(path, ctx)
	return setmetatable({ __ref = path, __ctx = ctx }, refMeta)
end

refMeta.__index = function(ref, key)
	local path, ctx = rawget(ref, "__ref"), rawget(ref, "__ctx")
	if key == "Parent" then
		local parent = string.match(path, "^(.*)/[^/]+$")
		return parent and makeRef(parent, ctx) or nil
	elseif key == "Name" then
		return string.match(path, "([^/]+)$")
	elseif key == "WaitForChild" or key == "FindFirstChild" then
		return function(_, child)
			return makeRef(path .. "/" .. child, ctx)
		end
	end
	return makeRef(path .. "/" .. key, ctx)
end

-- require(): a fake's value, a server/client file (X.luau, else X/init.luau, else the shared module X), or a
-- shared module.
local function requireTarget(target)
	if type(target) ~= "table" then
		error("harness can't require " .. tostring(target), 2)
	end
	local value = rawget(target, "__value")
	if value ~= nil then
		return value
	end
	local ref = rawget(target, "__ref")
	if ref then
		local name = string.match(ref, "([^/]+)$")
		local file = ref .. ".luau"
		if not fs.isFile(file) then
			if not fs.isFile(ref .. "/init.luau") then
				return loadModule(name)
			end
			file = ref .. "/init.luau"
		end
		local ctx = rawget(target, "__ctx")
		if ctx.cache[file] == nil then
			ctx.cache[file] = loadFile(file, name, ctx.globals, nil, ctx)
		end
		return ctx.cache[file]
	end
	local module = rawget(target, "__module")
	if module then
		return loadModule(module)
	end
	error("harness can't require this table (not a module reference)", 2)
end

--[[
    Loads one file. `folder` (shared folder modules) makes script.<Child> the
    shared module folder/<Child>; `ctx` (server and client files) makes
    script.Parent the file's own folder.
]]
function loadFile(path, name, globals, folder, ctx)
	local source = fs.readFile(path)
	local script
	if ctx then
		local dir = string.match(path, "^(.*)/[^/]+$")
		if string.match(path, "/init%.luau$") then
			-- a folder module is its folder: script.<Child> is a file inside it
			script = makeRef(dir, ctx)
		else
			script = { Parent = makeRef(dir, ctx), Name = name }
		end
	else
		local parent = setmetatable({}, {
			__index = function(_, child)
				return { __module = child }
			end,
		})
		script = { Parent = parent, Name = name }
		-- A folder module's init.luau requires its children as script.<Child>.
		if folder then
			setmetatable(script, {
				__index = function(_, child)
					return { __module = folder .. "/" .. child }
				end,
			})
		end
	end
	local env = {
		script = script,
		game = harness.game,
		workspace = harness.workspace,
		task = task,
		require = requireTarget,
		Color3 = roblox.Color3,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		CFrame = roblox.CFrame,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		ColorSequence = roblox.ColorSequence,
		NumberSequence = roblox.NumberSequence,
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
		local path = sharedRoot .. name .. ".luau"
		if fs.isFile(path) then
			cache[name] = loadFile(path, name)
		else
			-- a folder module (src/shared/<name>/init.luau)
			cache[name] = loadFile(sharedRoot .. name .. "/init.luau", name, nil, name)
		end
	end
	return cache[name]
end

harness.require = loadModule

local function loadFresh(path, name, globals)
	local ctx = { globals = globals, cache = {} }
	return loadFile(path, name, globals, nil, ctx)
end

-- Loads a server service or module (its script.Parent.X requires reach sibling services, else shared).
function harness.requireServer(name, globals)
	return loadFresh(cwd .. "src/server/Services/" .. name .. ".luau", name, globals)
end

-- Loads src/client/<relPath>.luau ("UI/Layout", "ClientState"...). `globals` adds or replaces globals
-- (game, workspace, Instance, Enum, ...) with the test's own fakes.
function harness.requireClientFile(relPath, globals)
	local name = string.match(relPath, "([^/]+)$")
	return loadFresh(cwd .. "src/client/" .. relPath .. ".luau", name, globals)
end

-- Loads a client controller (src/client/Controllers/<name>.luau).
function harness.requireClient(name, globals)
	return harness.requireClientFile("Controllers/" .. name, globals)
end

-- Running ---------------------------------------------------------------------

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
