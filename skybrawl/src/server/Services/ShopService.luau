--[[
    Coin shop for cosmetics. All checks happen here; the client only asks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cosmetics = require(Shared.Cosmetics)
local Net = require(Shared.Net)

local ShopService = {}
local services

function ShopService.init(s)
	services = s
end

local function buy(player, itemId)
	local item = Cosmetics.get(itemId)
	if not item then
		return false, "That item doesn't exist."
	end
	local profile = services.DataService.get(player)
	if not profile then
		return false, "Your profile is still loading."
	end
	if profile.Owned[item.Id] then
		return false, "You already own that."
	end
	if profile.Coins < item.Price then
		return false, "Not enough coins."
	end
	services.DataService.update(player, function(p)
		p.Coins -= item.Price
		p.Owned[item.Id] = true
		p.Equipped[item.Category] = item.Id
	end)
	services.CharacterService.refreshNameplate(player)
	return true, "Bought " .. item.Name .. "!"
end

local function equip(player, itemId)
	local item = Cosmetics.get(itemId)
	if not item then
		return false, "That item doesn't exist."
	end
	local profile = services.DataService.get(player)
	if not profile or not profile.Owned[item.Id] then
		return false, "You don't own that yet."
	end
	services.DataService.update(player, function(p)
		p.Equipped[item.Category] = item.Id
	end)
	services.CharacterService.refreshNameplate(player)
	return true, "Equipped " .. item.Name .. "."
end

function ShopService.start()
	Net.get("ShopRequest").OnServerInvoke = function(player, action, itemId)
		if type(itemId) ~= "string" then
			return false, "Bad request."
		end
		if action == "Buy" then
			return buy(player, itemId)
		elseif action == "Equip" then
			return equip(player, itemId)
		end
		return false, "Bad request."
	end
end

return ShopService
