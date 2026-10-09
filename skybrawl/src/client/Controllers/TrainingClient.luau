-- STUB (owner: T): replace the body, keep the exports.
--[[
    Client side of the training room (menus design 5.11): frame data,
    hitbox overlay, dummy state, the training panel. MatchClient calls these
    hooks; until T lands they do nothing.
]]

local TrainingClient = {}

-- In onStart after MatchHUD.show, when m.info.source == "Training".
function TrainingClient.start(_m) end

-- In cleanup (always; no-op when not training).
function TrainingClient.stop() end

-- End of MatchClient's step(), training only; dt already scaled.
function TrainingClient.step(_m, _dt) end

-- handleSimEvent "Attack", training only.
function TrainingClient.onOwnAttack(_m, _ev, _move) end

-- handleSimEvent "AttackEnd", training only.
function TrainingClient.onOwnAttackEnd(_m, _ev) end

-- End of the Hit handler, training only.
function TrainingClient.onHit(_m, _d) end

-- MatchEvent "Training".
function TrainingClient.onServer(_m, _d) end

return TrainingClient
