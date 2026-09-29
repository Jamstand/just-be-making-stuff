--!strict
-- Small helpers shared by server and client.
local Util = {}

-- Picks a key from `weights` using `order` for a stable iteration order.
function Util.WeightedPick(weights: { [string]: number }, order: { string }): string
	local total = 0
	for _, key in ipairs(order) do
		total += weights[key] or 0
	end
	local r = math.random() * total
	local acc = 0
	for _, key in ipairs(order) do
		acc += weights[key] or 0
		if r <= acc then
			return key
		end
	end
	return order[#order]
end

-- 1234 -> "1.2K", 5 -> "5", 2500000 -> "2.5M"
function Util.FormatCash(n: number): string
	local abs = math.abs(n)
	local suffix = { "", "K", "M", "B", "T", "Qa", "Qi" }
	local i = 1
	while abs >= 1000 and i < #suffix do
		abs /= 1000
		i += 1
	end
	local body
	if i == 1 then
		body = tostring(math.floor(abs))
	elseif abs >= 100 then
		body = string.format("%.0f", abs)
	else
		body = string.format("%.1f", abs)
	end
	return (if n < 0 then "-" else "") .. body .. suffix[i]
end

-- "$12.5K/s" style rate text (keeps one decimal below 10)
function Util.FormatRate(n: number): string
	if n < 10 then
		return string.format("%.1f", n)
	end
	return Util.FormatCash(n)
end

function Util.SideLabel(side: string): string
	if side == "L" then
		return "LEFT"
	elseif side == "R" then
		return "RIGHT"
	end
	return "SINGLE"
end

return Util
