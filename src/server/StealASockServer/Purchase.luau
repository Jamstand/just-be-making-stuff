-- Purchase: buying a sock off the clothesline. The ProximityPrompt fires on the server; this
-- re-validates distance, state, cash and drawer space before anything changes.
local Purchase = {}
local S

function Purchase.Init(s)
	S = s
end

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
	S.Pair.Recompute(record)
	S.Base.SyncToProfile(record)
	S.Toast(player, "Bought " .. S.Registry.DisplayName(sock) .. " for $" .. S.Util.FormatCash(price), "good")
	S.Income.Push(player)
end

return Purchase
