-- Purchase: buying a sock off the clothesline, and selling a drawer sock back (the sock card's
-- Sell button). The ProximityPrompt / SellSock remote fire on the server; this re-validates
-- distance, state, ownership, cash and drawer space before anything changes.
local Purchase = {}
local S

local SELL_GAP = 0.3 -- seconds between SellSock calls per player

local function distanceTo(player: Player, sock): number
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not sock.model then
		return math.huge
	end
	return (root.Position - S.Clothesline.PositionOf(sock)).Magnitude
end

function Purchase.TryBuy(player: Player, sock)
	if not S.Ready or not S.RateLimit.Check(player, "buy", S.Config.Economy.PromptRateLimit) then
		return
	end
	if sock.state ~= "line" then
		return -- already bought or fell in the trap
	end
	if distanceTo(player, sock) > S.Config.Economy.BuyRange then
		return
	end
	local record = S.Base.Get(player)
	local profile = S.Data.Get(player)
	if not record or not profile then
		S.Toast(player, "Your drawer isn't ready yet", "bad")
		return
	end
	local slot = S.Base.FirstEmptySlot(record)
	if not slot then
		S.Toast(player, "Your drawer is full! 🧦", "bad")
		return
	end
	local price = S.Registry.PriceOf(sock)
	if not S.Data.TrySpend(player, price) then
		S.Toast(player, "Not enough cash (need $" .. S.Util.FormatCash(price) .. ")", "bad")
		return
	end
	S.Clothesline.Remove(sock)
	S.FX("buy", S.Clothesline.PositionOf(sock), S.Registry.Tier(sock).color)
	S.Base.PlaceInSlot(record, sock, slot, true)
	S.Base.SyncToProfile(record)
	S.Dex.Record(player, sock) -- before Pair: a new type earns its Sockdex reward
	S.Pair.Recompute(record)
	S.Base.SyncToProfile(record)
	S.Toast(player, "Bought " .. S.Registry.DisplayName(sock) .. " for $" .. S.Util.FormatCash(price), "good")
	S.Income.Push(player)
end

-- Sells a sock out of the player's own drawer for Registry.SellPriceOf. Returns a Types.Result.
function Purchase.Sell(player: Player, uid: number)
	local record = S.Base.Get(player)
	local profile = S.Data.Get(player)
	if not record or not profile then
		return { ok = false, err = "Your drawer isn't ready yet" }
	end
	local sock = S.Registry.Get(uid)
	-- must be sitting in this player's drawer right now (not on someone's head, not mid-steal)
	if not sock or sock.state ~= "drawer" or sock.ownerId ~= player.UserId or sock.carrierId ~= nil
		or sock.slot == nil or record.slots[sock.slot] ~= uid then
		return { ok = false, err = "That sock isn't in your drawer" }
	end
	local paid = S.Registry.SellPriceOf(sock)
	local name = S.Registry.DisplayName(sock)
	local position = S.Base.SlotCFrame(record, sock.slot).Position
	local color = S.Registry.Tier(sock).color
	S.Base.RemoveFromSlot(record, sock)
	S.Registry.Destroy(uid)
	S.FX("sell", position, color)
	S.Base.SyncToProfile(record)
	S.Pair.Recompute(record)
	S.Data.AddCash(player, paid)
	S.Toast(player, "Sold " .. name .. " for $" .. S.Util.FormatCash(paid), "good")
	S.Base.RefreshSlots(record) -- a saved sock waiting for room takes the slot first
	S.Monetize.DeliverPending(player) -- then a Rare Sock Drop waiting for room
	S.Income.Push(player)
	return { ok = true, cash = paid, msg = "Sold " .. name .. " for $" .. S.Util.FormatCash(paid) }
end

local function onSellSock(player: Player, uid: any)
	if not S.Ready then
		return { ok = false, err = "Starting up…" }
	end
	if type(uid) ~= "number" or uid ~= uid or uid % 1 ~= 0 then
		return { ok = false, err = "Bad request" }
	end
	if not S.RateLimit.Check(player, "sellSock", SELL_GAP) then
		return { ok = false, err = "Slow down a little!" }
	end
	return Purchase.Sell(player, uid)
end

function Purchase.Init(s)
	S = s
	S.Remotes.SellSock.OnServerInvoke = function(player: Player, uid: any)
		local ok, result = pcall(onSellSock, player, uid)
		if not ok then
			warn("[Purchase] SellSock failed: " .. tostring(result))
			return { ok = false, err = "Something went wrong - try again" }
		end
		return result
	end
end

return Purchase
