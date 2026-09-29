-- RateLimit: per-player minimum gap between actions of the same kind.
-- Every remote/prompt/touch handler calls Check() first.
local RateLimit = {}

local last: { [Player]: { [string]: number } } = {}

function RateLimit.Init(_S)
end

-- Returns true if the action may proceed now, false if it is too soon.
function RateLimit.Check(player: Player, key: string, gap: number): boolean
	local now = os.clock()
	local record = last[player]
	if not record then
		record = {}
		last[player] = record
	end
	local previous = record[key]
	if previous and now - previous < gap then
		return false
	end
	record[key] = now
	return true
end

function RateLimit.Clear(player: Player)
	last[player] = nil
end

return RateLimit
