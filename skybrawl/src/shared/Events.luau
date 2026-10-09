--[[
    Live events (Config.Events): which are on, and the reward multipliers
    they give a match.

    Dates are UTC ISO strings ("2026-10-09T00:00:00Z" or "2026-10-09"),
    turned into unix seconds by hand (days from the civil date), never with
    os.time{...}, which reads local time.

    Pure: `now` (unix seconds, UTC) is always passed in.
]]

local Config = require(script.Parent.Config)

local Events = {}

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function isLeap(y)
	return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
end

-- Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's days_from_civil).
local function daysFromCivil(y, m, d)
	if m <= 2 then
		y -= 1
	end
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local doy = (153 * (m + (if m > 2 then -3 else 9)) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- "YYYY-MM-DD" or "YYYY-MM-DDThh:mm:ssZ" -> unix seconds (UTC); nil when malformed.
function Events.parse(iso)
	if type(iso) ~= "string" then
		return nil
	end
	local y, m, d = string.match(iso, "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	local hh, mm, ss = "0", "0", "0"
	if not y then
		y, m, d, hh, mm, ss = string.match(iso, "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
		if not y then
			return nil
		end
	end
	local year, month, day = tonumber(y), tonumber(m), tonumber(d)
	local hour, minute, second = tonumber(hh), tonumber(mm), tonumber(ss)
	if month < 1 or month > 12 or day < 1 then
		return nil
	end
	local maxDay = DAYS_IN_MONTH[month] + (if month == 2 and isLeap(year) then 1 else 0)
	if day > maxDay or hour > 23 or minute > 59 or second > 59 then
		return nil
	end
	return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
end

-- Starts <= now < Ends; an event with a bad date is never active.
function Events.isActive(event, now)
	local starts, ends = Events.parse(event.Starts), Events.parse(event.Ends)
	return starts ~= nil and ends ~= nil and starts <= now and now < ends
end

-- The active events of `list`, in list order.
function Events.active(list, now)
	local out = {}
	for _, event in list do
		if Events.isActive(event, now) then
			table.insert(out, event)
		end
	end
	return out
end

-- Seconds until the event ends (0 when it has, or its date is bad).
function Events.endsIn(event, now)
	local ends = Events.parse(event.Ends)
	if not ends then
		return 0
	end
	return math.max(0, ends - now)
end

local function multOf(value)
	if type(value) ~= "number" or value ~= value then
		return 1
	end
	return math.clamp(value, 1, Config.EventMaxMult)
end

--[[
    The best XP and the best coin multiplier among the active events that
    apply to a match played as `legendId` (events without a Legend apply to
    everyone). Each is in 1..Config.EventMaxMult; events never stack.
    Returns xpMult, coinMult, applied (the events that gave either value,
    in list order).
]]
function Events.multipliers(list, now, legendId)
	local xpMult, coinMult = 1, 1
	local xpEvent, coinEvent = nil, nil
	for _, event in Events.active(list, now) do
		if event.Legend == nil or event.Legend == legendId then
			local xp, coins = multOf(event.XPMult), multOf(event.CoinMult)
			if xp > xpMult then
				xpMult, xpEvent = xp, event
			end
			if coins > coinMult then
				coinMult, coinEvent = coins, event
			end
		end
	end
	local applied = {}
	for _, event in list do
		if event == xpEvent or event == coinEvent then
			table.insert(applied, event)
		end
	end
	return xpMult, coinMult, applied
end

return Events
