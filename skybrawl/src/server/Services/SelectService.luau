-- STUB (owner: S1): replace the body, keep the exports.
--[[
    Legend select + map vote + VS timing between "match found" and the
    Match (menus design 4.3). Until S1 lands nothing uses it: begin refuses
    and nobody is ever in a session.
]]

local SelectService = {}

-- Returns the session, or nil and the error text.
function SelectService.begin(_config)
	return nil, "Not ready."
end

function SelectService.getSessionOf(_player)
	return nil
end

-- opts = { requeue: boolean?, leavers: { Player }? }
function SelectService.cancel(_session, _reason, _opts) end

function SelectService.onPlayerRemoving(_player) end

function SelectService.init(_services) end

function SelectService.start() end

return SelectService
