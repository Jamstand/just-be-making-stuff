-- Monetize: the Robux Store (StoreConfig) - game passes, developer products and what they do.
-- Test mode: in Studio, an item whose id is still 0 is granted at once through the same paths a
-- real purchase uses. A live server never self-grants (an id-0 item says "Coming soon!" there).
-- Test passes live only in this server's memory for the session; they are never saved.
-- ProcessReceipt follows the ProfileStore pattern: grant once, remember the PurchaseId in
-- profile.Data.receipts, and answer PurchaseGranted only after a save that contains it.
-- Item unlocks (StoreConfig products with `item`, bought from the Item Shop's Items tab) unlock that
-- item for good through Items.Unlock; a second grant just says it's already unlocked, and
-- StorePurchase won't prompt an item the player already has.
-- API: Monetize.Setup(player), Monetize.OnPlayerRemoving(player), Monetize.Owns(player, key),
--      Monetize.IncomeMult(player), Monetize.LuckUntil(), Monetize.LuckMult(rank),
--      Monetize.OnPassGranted(player, key), Monetize.GrantProduct(player, key) -> message,
--      Monetize.DeliverDrop(player) -> delivered?, Monetize.DeliverPending(player)
-- Remote: StorePurchase(kind, key) -> Types.Result
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local Monetize = {}
local S

local PURCHASE_GAP = 0.5 -- seconds between StorePurchase calls per player
local RECEIPT_CAP = 50 -- PurchaseIds kept in profile.Data.receipts
local LOAD_WAIT = 15 -- seconds ProcessReceipt waits for a joining player's drawer
local LOOKUP_RETRY = 30 -- seconds before a failed ownership lookup is tried again
local VIP_COLOR = Color3.fromRGB(255, 200, 60)
local LUCK_COLOR = Color3.fromRGB(88, 200, 110)

-- Player -> { owned = {key = bool}, test = {key = true}, tried = {key = os.clock()},
--             ready = bool, charConn = RBXScriptConnection? }
local sessions = {}
local passKeyById = {} -- live pass id -> key
local productKeyById = {} -- live product id -> key
local processing = {} -- PurchaseId -> true while that receipt is being handled
local luckUntil = 0 -- server time Server Luck ends

-- ---------- game passes ----------

-- Asks Roblox. Returns true/false, or nil when the lookup failed (not cached, tried again later).
local function lookup(player: Player, pass): boolean?
	local ok, result = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, pass.id)
	if ok then
		return result == true
	end
	warn("[Monetize] game pass lookup failed (" .. pass.key .. "): " .. tostring(result))
	return nil
end

local function addVipTag(character: Model)
	local head = character:WaitForChild("Head", 10)
	if not head or not head:IsA("BasePart") or head:FindFirstChild("VipTag") then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "VipTag"
	gui.Adornee = head
	gui.Size = UDim2.fromOffset(110, 30)
	gui.StudsOffset = Vector3.new(0, 2.8, 0)
	gui.MaxDistance = 80
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(70, 45, 10)
	label.BackgroundTransparency = 0.2
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = VIP_COLOR
	label.TextStrokeTransparency = 0.4
	label.Text = "👑 VIP"
	label.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Color = VIP_COLOR
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = label
	gui.Parent = head
end

-- What owning a pass changes in the world (no celebration: also runs when a join finds old passes).
local function applyPass(player: Player, key: string)
	if key == "ExtraSlots" then
		local record = S.Base.Get(player)
		if record then
			S.Base.RefreshSlots(record)
		end
		Monetize.DeliverPending(player)
	elseif key == "GoldenTowel" then
		S.Towel.Refresh(player)
	elseif key == "VIP" then
		if player.Character then
			task.spawn(addVipTag, player.Character)
		end
	end
end

-- A lookup that failed earlier is retried in the background (never yields the caller).
local function retryLookup(player: Player, session, key: string)
	local last = session.tried[key]
	if last and os.clock() - last < LOOKUP_RETRY then
		return
	end
	session.tried[key] = os.clock()
	task.spawn(function()
		local result = lookup(player, S.Config.Store.Passes[key])
		if result == nil or sessions[player] ~= session or session.owned[key] ~= nil then
			return
		end
		session.owned[key] = result
		if result then
			applyPass(player, key)
			S.Income.Push(player)
		end
	end)
end

-- Cached per player. Never yields: before Setup (or while a lookup is pending) it says false.
function Monetize.Owns(player: Player, key: string): boolean
	local pass = S.Config.Store.Passes[key]
	local session = player and sessions[player]
	if not pass or not session then
		return false
	end
	if session.test[key] then
		return true
	end
	local cached = session.owned[key]
	if cached ~= nil then
		return cached
	end
	if session.ready and pass.id ~= 0 then
		retryLookup(player, session, key)
	end
	return false
end

-- Income multiplier from passes (2x Cash, VIP bonus).
function Monetize.IncomeMult(player: Player): number
	local Store = S.Config.Store
	local mult = 1
	if Monetize.Owns(player, "DoubleCash") then
		mult *= Store.DoubleCashMult
	end
	if Monetize.Owns(player, "VIP") then
		mult *= 1 + Store.VipIncomeBonus
	end
	return mult
end

-- A pass was bought (or test-bought): apply it, celebrate, push the new state.
function Monetize.OnPassGranted(player: Player, key: string)
	local pass = S.Config.Store.Passes[key]
	if not pass then
		return
	end
	applyPass(player, key)
	S.Celebrate(player, "pass", { key = key, display = pass.display })
	S.Income.Push(player)
end

-- ---------- Server Luck ----------

-- Server time Server Luck ends, or 0 when it isn't running. Same for everyone in the server.
function Monetize.LuckUntil(): number
	return if workspace:GetServerTimeNow() < luckUntil then luckUntil else 0
end

-- Spawn-weight multiplier for a rarity rank while Server Luck runs (1 otherwise).
function Monetize.LuckMult(rank: number): number
	if Monetize.LuckUntil() == 0 then
		return 1
	end
	local luck = S.Config.Store.Products.ServerLuck.luck or 1
	return luck ^ math.max(0, rank - 1)
end

-- Runs a side effect that comes AFTER a grant has happened (toast, FX, celebrate, push). It must
-- never error out of GrantProduct: ProcessReceipt would answer NotProcessedYet and Roblox would
-- deliver the receipt again - a second grant on top of the one that already happened.
local function after(fn: (...any) -> ...any, ...: any)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[Monetize] after-grant step failed: " .. tostring(err))
	end
end

-- ---------- Rare Sock Drop ----------

-- Rolls an Epic-or-better sock and flies it from the Great Dryer into `slot`.
local function dropInto(player: Player, record, slot: number)
	local minRank = S.Config.Store.Products.RareDrop.minRank or 3
	local typeId, side = S.Registry.RollTypeAtLeast(minRank)
	local sock = S.Registry.Create(typeId, side, S.Registry.RollMutation(), 0)
	local model = S.Factory.Build(sock)
	model:PivotTo(S.Map.LinePoint(0)) -- starts in the dryer's mouth; PlaceInSlot hops it home
	S.Base.PlaceInSlot(record, sock, slot, true)
	-- the sock is in the drawer now: nothing below may undo that by erroring
	after(S.Dex.Record, player, sock) -- before Pair: a new type earns its Sockdex reward
	after(S.Pair.Recompute, record)
	after(S.Base.SyncToProfile, record)
	after(function()
		local tier = S.Registry.Tier(sock)
		S.FX("claim", S.Base.SlotCFrame(record, slot).Position, tier.color)
		S.Celebrate(player, "rareDrop", { name = S.Registry.DisplayName(sock), rarity = S.Registry.Type(sock).rarity })
	end)
end

-- Lands one drop now, or queues it in profile.Data.pendingDrops when the drawer is full.
-- Errors when the drawer isn't loaded (ProcessReceipt then retries later).
function Monetize.DeliverDrop(player: Player): boolean
	local record = S.Base.Get(player)
	local profile = S.Data.Get(player)
	if not record or not profile then
		error("drawer not ready")
	end
	local slot = S.Base.FirstEmptySlot(record)
	if not slot then
		profile.Data.pendingDrops = (tonumber(profile.Data.pendingDrops) or 0) + 1
		after(S.Toast, player, "Your drawer is full — your Rare Sock Drop will land when a slot frees up", "info")
		after(S.Income.Push, player)
		return false
	end
	dropInto(player, record, slot)
	after(S.Income.Push, player)
	return true
end

-- Lands queued drops while there is room. Called on join, after a sale, after +4 Slots and by Income.
function Monetize.DeliverPending(player: Player)
	local session = sessions[player]
	local record = S.Base.Get(player)
	local profile = S.Data.Get(player)
	if not session or not session.ready or not record or not profile then
		return
	end
	local delivered = false
	while (tonumber(profile.Data.pendingDrops) or 0) > 0 do
		local slot = S.Base.FirstEmptySlot(record)
		if not slot then
			break
		end
		profile.Data.pendingDrops -= 1
		local ok, err = pcall(dropInto, player, record, slot)
		if not ok then
			profile.Data.pendingDrops += 1
			warn("[Monetize] pending Rare Sock Drop failed: " .. tostring(err))
			break
		end
		delivered = true
	end
	if delivered then
		S.Income.Push(player)
	end
end

-- ---------- developer products ----------

-- The one grant path for products (real receipts and Studio test purchases). Returns a short
-- message. Errors when it can't grant, so ProcessReceipt answers NotProcessedYet.
function Monetize.GrantProduct(player: Player, key: string): string
	local product = S.Config.Store.Products[key]
	if not product then
		error("unknown product " .. tostring(key))
	end
	if not S.Data.Get(player) then
		error("profile not loaded")
	end
	if product.cashMin or product.cashSeconds then
		local record = S.Base.Get(player)
		local rate = if record then S.Income.RateOf(record) else 0
		local amount = math.max(product.cashMin or 0, math.floor(rate * (product.cashSeconds or 0)))
		S.Data.AddCash(player, amount)
		after(S.Celebrate, player, "product", { key = key, display = product.display, cash = amount })
		after(S.Income.Push, player)
		return product.display .. ": +$" .. S.Util.FormatCash(amount)
	elseif key == "ServerLuck" then
		local minutes = product.minutes or 15
		luckUntil = math.max(workspace:GetServerTimeNow(), luckUntil) + minutes * 60
		after(function()
			if S.Map.Root then
				S.Map.Root:SetAttribute("LuckUntil", luckUntil) -- every client shows the timer
			end
			S.Announce("🍀 " .. player.DisplayName .. " bought Server Luck! Rarer socks for " .. minutes .. " minutes!", LUCK_COLOR)
		end)
		after(S.Celebrate, player, "product", { key = key, display = product.display })
		after(S.Income.Push, player)
		return product.display .. " is on!"
	elseif key == "RareDrop" then
		if not Monetize.DeliverDrop(player) then
			after(S.Celebrate, player, "product", { key = key, display = product.display })
			return product.display .. " is waiting for a free slot"
		end
		return product.display .. " landed in your drawer!"
	elseif key == "Relock" then
		if not S.Base.ForceLock(player) then
			error("no drawer to lock")
		end
		after(S.Celebrate, player, "product", { key = key, display = product.display })
		after(S.Income.Push, player)
		return "Drawer slammed!"
	elseif product.item then
		-- Items.Unlock celebrates ("item") and pushes the state itself; already unlocked = nothing to do
		if not S.Items.Unlock(player, product.item) then
			return product.display .. " is already unlocked"
		end
		return product.display .. " unlocked!"
	end
	error("no grant for product " .. key)
end

-- Waits (up to LOAD_WAIT) until the player's profile, drawer and passes are ready.
local function waitForDrawer(player: Player)
	local deadline = os.clock() + LOAD_WAIT
	while true do
		local session = sessions[player]
		local profile = S.Data.Get(player)
		if profile and session and session.ready then
			return profile
		end
		if player.Parent ~= Players or os.clock() > deadline then
			return nil
		end
		task.wait(0.25)
	end
end

local function handleReceipt(player: Player, profile, purchaseId: string, key: string)
	local receipts = profile.Data.receipts
	if type(receipts) ~= "table" then
		receipts = {}
		profile.Data.receipts = receipts
	end
	if not table.find(receipts, purchaseId) then
		local ok, err = pcall(Monetize.GrantProduct, player, key)
		if not ok then
			warn("[Monetize] grant failed (" .. key .. "): " .. tostring(err))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		table.insert(receipts, purchaseId)
		while #receipts > RECEIPT_CAP do
			table.remove(receipts, 1)
		end
	end

	-- PurchaseGranted only once a save that contains this PurchaseId has landed
	local result = nil
	local function check()
		if result ~= nil then
			return
		end
		local saved = profile.LastSavedData and profile.LastSavedData.receipts
		if type(saved) == "table" and table.find(saved, purchaseId) then
			result = Enum.ProductPurchaseDecision.PurchaseGranted
		elseif not profile:IsActive() then
			result = Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end
	check()
	if result == nil then
		local conn = profile.OnAfterSave:Connect(check)
		profile:Save()
		while result == nil do
			task.wait(0.5)
			check()
		end
		conn:Disconnect()
	end
	return result
end

local function processReceipt(receipt)
	local key = productKeyById[receipt.ProductId]
	if not key then
		warn("[Monetize] receipt for an unknown product id " .. tostring(receipt.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- granted when they next join
	end
	local profile = waitForDrawer(player)
	if not profile or not profile:IsActive() then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local purchaseId = tostring(receipt.PurchaseId)
	if processing[purchaseId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- the same receipt is already being handled
	end
	processing[purchaseId] = true
	local ok, result = pcall(handleReceipt, player, profile, purchaseId, key)
	processing[purchaseId] = nil
	if not ok then
		warn("[Monetize] ProcessReceipt failed: " .. tostring(result))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return result
end

-- ---------- StorePurchase remote ----------

local function storePurchase(player: Player, kind: any, key: any)
	if not S.Ready then
		return { ok = false, err = "Starting up…" }
	end
	if (kind ~= "pass" and kind ~= "product") or type(key) ~= "string" then
		return { ok = false, err = "Bad request" }
	end
	local Store = S.Config.Store
	local item = if kind == "pass" then Store.Passes[key] else Store.Products[key]
	if not item then
		return { ok = false, err = "Bad request" }
	end
	if not S.RateLimit.Check(player, "storePurchase", PURCHASE_GAP) then
		return { ok = false, err = "Slow down a little!" }
	end
	local session = sessions[player]
	if not session or not session.ready or not S.Data.Get(player) then
		return { ok = false, err = "Your drawer isn't ready yet" }
	end
	if kind == "pass" and Monetize.Owns(player, key) then
		return { ok = false, err = "You already own this!" }
	end
	if kind == "product" and item.item and S.Items.IsUnlocked(player, item.item) then
		return { ok = false, err = "You already unlocked this!" }
	end

	if item.id == 0 then
		if not RunService:IsStudio() then
			return { ok = false, err = "Coming soon!" }
		end
		-- Studio test purchase: granted now through the same path a real purchase uses
		if kind == "pass" then
			session.test[key] = true
			Monetize.OnPassGranted(player, key)
			return { ok = true, simulated = true, msg = "Test purchase (Studio only): " .. item.display }
		end
		local ok, msg = pcall(Monetize.GrantProduct, player, key)
		if not ok then
			warn("[Monetize] test grant failed (" .. key .. "): " .. tostring(msg))
			return { ok = false, err = "Something went wrong - try again" }
		end
		return { ok = true, simulated = true, msg = "Test purchase (Studio only): " .. tostring(msg) }
	end

	local ok, err = pcall(function()
		if kind == "pass" then
			MarketplaceService:PromptGamePassPurchase(player, item.id)
		else
			MarketplaceService:PromptProductPurchase(player, item.id)
		end
	end)
	if not ok then
		warn("[Monetize] purchase prompt failed (" .. key .. "): " .. tostring(err))
		return { ok = false, err = "The store isn't available right now - try again" }
	end
	return { ok = true, prompted = true }
end

-- ---------- lifecycle ----------

function Monetize.Init(s)
	S = s
	local Store = S.Config.Store
	local missing = {}
	for _, key in ipairs(Store.PassOrder) do
		local pass = Store.Passes[key]
		if pass.id ~= 0 then
			passKeyById[pass.id] = key
		else
			table.insert(missing, key)
		end
	end
	-- every product: the Store's tabs (ProductOrder) and the ones only the Item Shop sells (Item_*)
	local productKeys = table.clone(Store.ProductOrder)
	local extra = {}
	for key in pairs(Store.Products) do
		if not table.find(productKeys, key) then
			table.insert(extra, key)
		end
	end
	table.sort(extra)
	for _, key in ipairs(extra) do
		table.insert(productKeys, key)
	end
	for _, key in ipairs(productKeys) do
		local product = Store.Products[key]
		if product.id ~= 0 then
			productKeyById[product.id] = key
		else
			table.insert(missing, key)
		end
	end
	if #missing > 0 then
		warn("[Monetize] store items with id 0 (" .. (if RunService:IsStudio() then "simulated in Studio" else "\"Coming soon!\" on live servers")
			.. "): " .. table.concat(missing, ", ") .. " - paste the real ids into StoreConfig.luau")
	end
	if S.Map.Root then
		S.Map.Root:SetAttribute("LuckUntil", 0)
	end

	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		local key = passKeyById[passId]
		local session = sessions[player]
		if not purchased or not key or not session or session.owned[key] == true then
			return
		end
		session.owned[key] = true -- replaces whatever was cached; Roblox just confirmed it
		Monetize.OnPassGranted(player, key)
	end)
	S.Remotes.StorePurchase.OnServerInvoke = function(player: Player, kind: any, key: any)
		local ok, result = pcall(storePurchase, player, kind, key)
		if not ok then
			warn("[Monetize] StorePurchase failed: " .. tostring(result))
			return { ok = false, err = "Something went wrong - try again" }
		end
		return result
	end
end

-- On join, after the drawer is assigned: looks up every live pass (yields), applies the owned
-- ones (back row, Golden Towel, VIP tag), then lands any Rare Sock Drops that were waiting.
function Monetize.Setup(player: Player)
	if sessions[player] then
		return
	end
	local session = { owned = {}, test = {}, tried = {}, ready = false, charConn = nil }
	sessions[player] = session
	local Store = S.Config.Store
	for _, key in ipairs(Store.PassOrder) do
		local pass = Store.Passes[key]
		if pass.id ~= 0 then
			session.tried[key] = os.clock()
			local result = lookup(player, pass)
			if sessions[player] ~= session then
				return -- left while Roblox was answering
			end
			if result ~= nil then
				session.owned[key] = result
			end
		end
	end
	session.charConn = player.CharacterAdded:Connect(function(character)
		if Monetize.Owns(player, "VIP") then
			addVipTag(character)
		end
	end)
	session.ready = true
	for _, key in ipairs(Store.PassOrder) do
		if Monetize.Owns(player, key) then
			applyPass(player, key)
		end
	end
	local record = S.Base.Get(player)
	if record then
		S.Base.RefreshSlots(record) -- places saved back-row socks once +4 Slots is known
	end
	Monetize.DeliverPending(player)
	S.Income.Push(player)
end

function Monetize.OnPlayerRemoving(player: Player)
	local session = sessions[player]
	if session and session.charConn then
		session.charConn:Disconnect()
	end
	sessions[player] = nil
end

return Monetize
