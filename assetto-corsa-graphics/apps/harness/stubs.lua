-- Hand-written core of the CSP Lua app stub environment used by run_app.py.
-- Everything here mimics the shape of the real API closely enough for smoke tests.
_H = { time = 0, log = {}, ui = { calls = {}, windowSize = nil }, web = { pending = {}, done = {} , handler = nil },
       files = {}, dirs = {}, filecontent = {}, timers = {}, stored = {}, storage = {} }

-- ---------------------------------------------------------------- vectors / colours
local function defvec(n, fields)
  local mt = {}; mt.__index = mt
  local function new(...)
    local a = {...}; local v = setmetatable({}, mt)
    for i, f in ipairs(fields) do v[f] = tonumber(a[i]) or 0 end
    return v
  end
  local function map(a, b, op)
    local r = new()
    for _, f in ipairs(fields) do
      local x = type(a) == 'number' and a or a[f]; local y = type(b) == 'number' and b or b[f]
      r[f] = op(x, y)
    end
    return r
  end
  mt.__add = function(a, b) return map(a, b, function(x, y) return x + y end) end
  mt.__sub = function(a, b) return map(a, b, function(x, y) return x - y end) end
  mt.__mul = function(a, b) return map(a, b, function(x, y) return x * y end) end
  mt.__div = function(a, b) return map(a, b, function(x, y) return x / y end) end
  mt.__unm = function(a) return map(a, -1, function(x, y) return x * y end) end
  mt.__eq = function(a, b) for _, f in ipairs(fields) do if a[f] ~= b[f] then return false end end return true end
  mt.__tostring = function(a) local t = {} for _, f in ipairs(fields) do t[#t+1] = tostring(a[f]) end return '(' .. table.concat(t, ', ') .. ')' end
  function mt:clone() local r = new() for _, f in ipairs(fields) do r[f] = self[f] end return r end
  function mt:set(...) local a = {...}
    if type(a[1]) == 'table' then for _, f in ipairs(fields) do self[f] = a[1][f] end else for i, f in ipairs(fields) do if a[i] ~= nil then self[f] = a[i] end end end
    return self end
  function mt:lengthSquared() local s = 0 for _, f in ipairs(fields) do s = s + self[f] * self[f] end return s end
  function mt:length() return math.sqrt(self:lengthSquared()) end
  function mt:normalize() local l = self:length() if l > 0 then for _, f in ipairs(fields) do self[f] = self[f] / l end end return self end
  function mt:normalized() return self:clone():normalize() end
  function mt:dot(o) local s = 0 for _, f in ipairs(fields) do s = s + self[f] * o[f] end return s end
  function mt:distance(o) return (self - o):length() end
  function mt:distanceSquared(o) return (self - o):lengthSquared() end
  function mt:scale(s) for _, f in ipairs(fields) do self[f] = self[f] * s end return self end
  function mt:add(o) for _, f in ipairs(fields) do self[f] = self[f] + (type(o) == 'number' and o or o[f]) end return self end
  function mt:sub(o) for _, f in ipairs(fields) do self[f] = self[f] - (type(o) == 'number' and o or o[f]) end return self end
  function mt:mul(o) for _, f in ipairs(fields) do self[f] = self[f] * (type(o) == 'number' and o or o[f]) end return self end
  function mt:addScaled(o, s) for _, f in ipairs(fields) do self[f] = self[f] + o[f] * s end return self end
  function mt:min(o) for _, f in ipairs(fields) do self[f] = math.min(self[f], type(o) == 'number' and o or o[f]) end return self end
  function mt:max(o) for _, f in ipairs(fields) do self[f] = math.max(self[f], type(o) == 'number' and o or o[f]) end return self end
  function mt:abs() for _, f in ipairs(fields) do self[f] = math.abs(self[f]) end return self end
  function mt:lerp(o, t) for _, f in ipairs(fields) do self[f] = self[f] + (o[f] - self[f]) * t end return self end
  function mt:unpack() local r = {} for _, f in ipairs(fields) do r[#r+1] = self[f] end return unpack(r) end
  function mt:angle(o) return math.acos(math.max(-1, math.min(1, self:dot(o) / (self:length() * o:length() + 1e-9)))) end
  if n == 2 then function mt:rotate(a) local c, s = math.cos(a), math.sin(a); local x, y = self.x, self.y; self.x = c*x - s*y; self.y = s*x + c*y; return self end end
  if n == 3 then function mt:cross(o) return new(self.y*o.z - self.z*o.y, self.z*o.x - self.x*o.z, self.x*o.y - self.y*o.x) end end
  local ctor = setmetatable({}, { __call = function(_, ...) return new(...) end })
  ctor.new = new; ctor.tmp = function() return new() end
  ctor['is' .. 'vec' .. n] = function(v) return getmetatable(v) == mt end
  ctor.isvec2 = ctor.isvec2 or function(v) return false end
  return ctor, mt
end
vec2 = defvec(2, {'x', 'y'}); vec3 = defvec(3, {'x', 'y', 'z'}); vec4 = defvec(4, {'x', 'y', 'z', 'w'})
vec2.isvec2 = function(v) return type(v) == 'table' and v.x ~= nil and v.z == nil end
vec3.isvec3 = function(v) return type(v) == 'table' and v.z ~= nil and v.w == nil end

local rgbmMT = {}; rgbmMT.__index = rgbmMT
local function newRgbm(r, g, b, m) return setmetatable({ r = r or 0, g = g or 0, b = b or 0, mult = m == nil and 1 or m, rgb = { r = r or 0, g = g or 0, b = b or 0 } }, rgbmMT) end
function rgbmMT:clone() return newRgbm(self.r, self.g, self.b, self.mult) end
function rgbmMT:set(r, g, b, m) if type(r) == 'table' then self.r, self.g, self.b, self.mult = r.r, r.g, r.b, r.mult or self.mult else self.r, self.g, self.b, self.mult = r, g, b, m or self.mult end return self end
function rgbmMT:scale(s) self.r, self.g, self.b = self.r*s, self.g*s, self.b*s return self end
rgbmMT.__tostring = function(c) return string.format('rgbm(%.2f,%.2f,%.2f,%.2f)', c.r, c.g, c.b, c.mult) end
rgbmMT.__mul = function(a, b) if type(b) == 'number' then return newRgbm(a.r*b, a.g*b, a.b*b, a.mult) end return newRgbm(a.r*b.r, a.g*b.g, a.b*b.b, a.mult*b.mult) end
rgbm = setmetatable({}, { __call = function(_, r, g, b, m) return newRgbm(r, g, b, m) end })
rgbm.new = newRgbm; rgbm.tmp = function() return newRgbm() end
rgbm.isrgbm = function(v) return getmetatable(v) == rgbmMT end
rgbm.colors = { transparent = newRgbm(0,0,0,0), black = newRgbm(0,0,0,1), silver = newRgbm(.75,.75,.75,1), gray = newRgbm(.5,.5,.5,1), white = newRgbm(1,1,1,1),
  maroon = newRgbm(.5,0,0,1), red = newRgbm(1,0,0,1), purple = newRgbm(.5,0,.5,1), fuchsia = newRgbm(1,0,1,1), green = newRgbm(0,.5,0,1), lime = newRgbm(0,1,0,1),
  olive = newRgbm(.5,.5,0,1), yellow = newRgbm(1,1,0,1), orange = newRgbm(1,.5,0,1), navy = newRgbm(0,0,.5,1), blue = newRgbm(0,0,1,1), teal = newRgbm(0,.5,.5,1), aqua = newRgbm(0,1,1,1), cyan = newRgbm(0,1,1,1) }
rgb = setmetatable({}, { __call = function(_, r, g, b) return { r = r or 0, g = g or 0, b = b or 0 } end }); rgb.new = function(r, g, b) return rgb(r, g, b) end
hsv = setmetatable({}, { __call = function(_, h, s, v) return { h = h or 0, s = s or 0, v = v or 0, rgb = function() return rgb(v, v, v) end } end })
function rgbm.colors.__index() return nil end

-- ---------------------------------------------------------------- math / table / string extras
function math.lerp(a, b, t) return a + (b - a) * t end
function math.clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
function math.saturate(v) return math.clamp(v, 0, 1) end
function math.round(v, d) local m = 10 ^ (d or 0) return math.floor(v * m + 0.5) / m end
function math.sign(v) if v > 0 then return 1 elseif v < 0 then return -1 end return 0 end
function math.smoothstep(x) x = math.saturate(x) return x * x * (3 - 2 * x) end
function math.lerpInvSat(v, a, b) return math.saturate((v - a) / (b - a)) end
function math.applyLag(v, t, lag, dt) return v + (t - v) * (1 - math.pow(lag, dt * 60)) end
function math.isNaN(v) return v ~= v end
function math.pow(a, b) return a ^ b end
function table.chain(...) local r = {} for _, t in ipairs({...}) do for k, v in pairs(t) do r[k] = v end end return r end
function table.map(t, f) local r = {} for k, v in pairs(t) do local nv, nk = f(v, k) if nk ~= nil then r[nk] = nv elseif nv ~= nil then r[#r+1] = nv end end return r end
function table.filter(t, f) local r = {} for k, v in pairs(t) do if f(v, k) then r[#r+1] = v end end return r end
function table.indexOf(t, v) for i, x in ipairs(t) do if x == v then return i end end return nil end
function table.contains(t, v) return table.indexOf(t, v) ~= nil end
function table.range(a, b, s) local r = {} for i = a, b, s or 1 do r[#r+1] = i end return r end
function table.clone(t) local r = {} for k, v in pairs(t) do r[k] = v end return r end
function table.forEach(t, f) for k, v in pairs(t) do f(v, k) end end
function table.count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
function table.findFirst(t, f) for k, v in pairs(t) do if f(v, k) then return v, k end end return nil end
function table.some(t, f) for k, v in pairs(t) do if f(v, k) then return true end end return false end
function table.every(t, f) for k, v in pairs(t) do if not f(v, k) then return false end end return true end
function table.reduce(t, init, f) local a = init for k, v in pairs(t) do a = f(a, v, k) end return a end
function table.join(t, sep) return table.concat(t, sep or ', ') end
function table.isEmpty(t) return next(t) == nil end
function table.nkeys(t) return table.count(t) end
function string.split(s, sep) local r = {} for p in string.gmatch(s, '([^' .. (sep or ',') .. ']+)') do r[#r+1] = p end return r end
function string.trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
function string.startsWith(s, p) return s:sub(1, #p) == p end
function string.endsWith(s, p) return p == '' or s:sub(-#p) == p end
function string.replace(s, a, b) return (s:gsub(a:gsub('%p', '%%%0'), b)) end

-- ---------------------------------------------------------------- JSON / stringify
JSON = {}
local function jenc(v, seen)
  local t = type(v)
  if t == 'nil' then return 'null' elseif t == 'boolean' then return tostring(v)
  elseif t == 'number' then if v ~= v or v == math.huge or v == -math.huge then return 'null' end return string.format('%.14g', v)
  elseif t == 'string' then return '"' .. v:gsub('[%c"\\]', function(c) local m = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' } return m[c] or string.format('\\u%04x', c:byte()) end) .. '"'
  elseif t == 'table' then
    seen = seen or {}; if seen[v] then return 'null' end seen[v] = true
    local n = #v; local isArr = n > 0 or next(v) == nil
    if isArr then local p = {} for i = 1, n do p[i] = jenc(v[i], seen) end return '[' .. table.concat(p, ',') .. ']' end
    local p = {} for k, x in pairs(v) do p[#p+1] = jenc(tostring(k), seen) .. ':' .. jenc(x, seen) end return '{' .. table.concat(p, ',') .. '}'
  end
  return 'null'
end
JSON.stringify = function(v) return jenc(v) end
local function jdec(s)
  local pos = 1
  local function ws() pos = s:find('%S', pos) or #s + 1 end
  local val
  local function str() local r = ''; pos = pos + 1
    while true do local c = s:sub(pos, pos)
      if c == '"' then pos = pos + 1 return r elseif c == '\\' then local e = s:sub(pos+1, pos+1); local m = { n = '\n', t = '\t', r = '\r', b = '\b', f = '\f', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
        if e == 'u' then r = r .. string.char(tonumber(s:sub(pos+2, pos+5), 16) % 256) pos = pos + 6 else r = r .. (m[e] or e) pos = pos + 2 end
      elseif c == '' then error('json: unterminated string') else r = r .. c pos = pos + 1 end end end
  val = function()
    ws(); local c = s:sub(pos, pos)
    if c == '{' then pos = pos + 1; local o = {} ws() if s:sub(pos, pos) == '}' then pos = pos + 1 return o end
      while true do ws(); local k = str(); ws(); pos = pos + 1; o[k] = val(); ws(); local d = s:sub(pos, pos); pos = pos + 1; if d == '}' then return o end end
    elseif c == '[' then pos = pos + 1; local a = {} ws() if s:sub(pos, pos) == ']' then pos = pos + 1 return a end
      while true do a[#a+1] = val(); ws(); local d = s:sub(pos, pos); pos = pos + 1; if d == ']' then return a end end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos+3) == 'true' then pos = pos + 4 return true elseif s:sub(pos, pos+4) == 'false' then pos = pos + 5 return false
    elseif s:sub(pos, pos+3) == 'null' then pos = pos + 4 return nil
    else local n = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos); if not n then error('json: unexpected at ' .. pos) end pos = pos + #n return tonumber(n) end
  end
  return val()
end
JSON.parse = function(s) local ok, r = pcall(jdec, s) if ok then return r end return nil end
stringify = setmetatable({}, { __call = function(_, v) return JSON.stringify(v) end })
stringify.tryParse = function(s, fallback) local r = s and JSON.parse(s) if r == nil then return fallback end return r end
stringify.parse = function(s) return JSON.parse(s) end

-- ---------------------------------------------------------------- timers / os
function os.preciseClock() return _H.time end
function os.clock() return _H.time end
function setTimeout(fn, delay) local t = { fn = fn, at = _H.time + (delay or 0) / 1000, once = true } _H.timers[#_H.timers+1] = t return t end
function setInterval(fn, period) local t = { fn = fn, at = _H.time + (period or 0) / 1000, period = (period or 0) / 1000 } _H.timers[#_H.timers+1] = t return t end
function clearTimeout(t) if t then t.dead = true end end
function clearInterval(t) if t then t.dead = true end end
function _H.tick(dt)
  _H.time = _H.time + dt
  for _, t in ipairs(_H.timers) do
    if not t.dead and _H.time >= t.at then
      t.fn()
      if t.once then t.dead = true else t.at = t.at + math.max(t.period, 0.001) end
    end
  end
end

-- ---------------------------------------------------------------- ac.*
ac = {}
ac.StructItem = setmetatable({}, { __index = function(_, k) return function(...) return { kind = k, args = {...} } end end })
local function structDefault(d)
  if type(d) ~= 'table' or not d.kind then return d end
  if d.kind == 'boolean' then return false elseif d.kind == 'string' then return '' end
  if d.kind == 'vec2' then return vec2() elseif d.kind == 'vec3' then return vec3() elseif d.kind == 'rgbm' then return rgbm() end
  return 0
end
function ac.connect(layout, keepLive, ns) local r = {} for k, v in pairs(layout) do if type(k) == 'string' then r[k] = structDefault(v) end end return r end
function ac.storage(layout, prefix)
  if type(layout) ~= 'table' then error('ac.storage(layout) expects a table') end
  local r = setmetatable({}, { __index = function(t, k) return rawget(t, '__values')[k] end, __newindex = function(t, k, v) rawget(t, '__values')[k] = v end })
  rawset(r, '__values', table.clone(layout)); _H.storage[#_H.storage+1] = r; return r
end
ac.storageHasKey = function() return false end
function ac.store(k, v) _H.stored[k] = v end
function ac.load(k) return _H.stored[k] end
local function logv(...) local p = {} for i = 1, select('#', ...) do p[#p+1] = tostring(select(i, ...)) end _H.log[#_H.log+1] = table.concat(p, ' ') end
ac.log, ac.debug, ac.warn, ac.error = logv, function(k, v) _H.log[#_H.log+1] = tostring(k) .. '=' .. tostring(v) end, logv, logv
function ac.getSim() return _H.sim end
function ac.getUI() return _H.ui.state end
function ac.getCar(i) return _H.cars[(i or 0) + 1] end
function ac.getSession(i) return _H.sessions[(i or 0) + 1] end
function ac.getDriverName(i) local c = _H.cars[(i or 0) + 1] return c and c.__driverName or nil end
function ac.getDriverNationCode(i) return 'GBR' end
function ac.getCarName(i) local c = _H.cars[(i or 0) + 1] return c and c.__carName or nil end
function ac.getCarID(i) local c = _H.cars[(i or 0) + 1] return c and c.__carID or nil end
function ac.getCarSkinID(i) return 'default' end
function ac.getCarBrand(i) return 'BMW' end
function ac.getTrackName() return _H.trackName end
function ac.getTrackID() return _H.trackID end
ac.getTrackId = ac.getTrackID
function ac.getTrackLayout() return '' end
function ac.getTrackFullID(sep) return _H.trackID end
function ac.getPpFilter() return _H.ppFilter end
function ac.getFolder(id) return _H.folders[id] or ('/fake/assettocorsa/folder' .. tostring(id)) end
function ac.currentlyPlaying() return _H.music end
function ac.getCompassAngle(dir) local a = math.deg(math.atan2(dir.x, dir.z)) if a < 0 then a = a + 360 end return a end
function ac.getSunAngle() return _H.sunAngle end
function ac.getSunPitchAngle() return _H.sunAngle end
function ac.getVRAMConsumption() return { usage = 4200, budget = 8192, availableForReservation = 0, reserved = 0 } end
function ac.setExposureMultiplier(v) _H.exposureSet = v end
function ac.getTrackDateTime() return 1700000000 end
function ac.lapTimeToString(ms, h) if not ms or ms <= 0 then return '--:--.---' end local s = ms / 1000 return string.format('%02d:%06.3f', math.floor(s / 60), s % 60) end
function ac.isWindowOpen(id) return true end
function ac.getCameraPosition() return _H.sim.cameraPosition end
function ac.getCameraForward() return _H.sim.cameraLook end
function ac.isModuleActive(id) return true end
function ac.getScriptSettings() return {} end
function ac.getRealTime() return _H.time end
function ac.getTrackUpcomingTurn(i) return vec2(60, 0.2) end
function ac.getTrackSectorName(p) return 'Sector' end
function ac.getTrackCoordinatesDeg(p) return vec2(35.6, 139.7) end

-- ---------------------------------------------------------------- web / io
web = {}
local function webreq(method, url, headers, data, cb)
  if type(headers) == 'function' then cb, headers, data = headers, nil, nil end
  if type(data) == 'function' then cb, data = data, nil end
  _H.web.pending[#_H.web.pending+1] = { method = method, url = url, headers = headers, data = data, cb = cb }
end
function web.get(url, headers, cb) webreq('GET', url, headers, nil, cb) end
function web.post(url, headers, data, cb) webreq('POST', url, headers, data, cb) end
function web.request(method, url, headers, data, cb) webreq(method, url, headers, data, cb) end
function web.timeouts() end
function web.socket(url, headers, cb, params) return { send = function() end, close = function() end } end
function web.encodeURIComponent(s) return (tostring(s):gsub('[^%w%-_%.~]', function(c) return string.format('%%%02X', c:byte()) end)) end
function _H.resolveWeb()
  local list = _H.web.pending; _H.web.pending = {}
  for _, r in ipairs(list) do
    local err, resp = nil, { status = 200, body = '{}', headers = {} }
    if _H.web.handler then err, resp = _H.web.handler(r) end
    _H.web.done[#_H.web.done+1] = r
    if r.cb then r.cb(err, resp) end
  end
end
io = io or {}
function io.fileExists(p) return _H.files[p] == true end
function io.dirExists(p) return _H.dirs[p] == true end
function io.exists(p) return _H.files[p] == true or _H.dirs[p] == true end
function io.load(p, fallback) return _H.filecontent[p] or fallback end
function io.save(p, data) _H.filecontent[p] = data return true end
function io.scanDir(dir, mask, cb, cbData) local n = 0 for f, _ in pairs(_H.files) do if f:sub(1, #dir) == dir then n = n + 1 if cb then cb(f:sub(#dir + 2), {}, cbData) end end end return n end
function io.getFileSize(p) return 0 end
function io.createDir() return true end

-- ---------------------------------------------------------------- ui.*
ui = {}
local function rec(name) _H.ui.calls[name] = (_H.ui.calls[name] or 0) + 1 end
local cursor = vec2(0, 0)
local uiState = { fontStack = {}, idStack = {}, groupDepth = 0, childDepth = 0 }
_H.uiState = uiState
function ui.windowSize() rec('windowSize') return _H.ui.windowSize:clone() end
function ui.windowPos() return vec2(100, 100) end
function ui.windowWidth() return _H.ui.windowSize.x end
function ui.windowHeight() return _H.ui.windowSize.y end
function ui.getCursor() rec('getCursor') return cursor:clone() end
function ui.getCursorX() return cursor.x end
function ui.getCursorY() return cursor.y end
function ui.setCursor(v) cursor:set(v) end
function ui.setCursorX(x) cursor.x = x end
function ui.setCursorY(y) cursor.y = y end
function ui.offsetCursor(v) cursor:add(v) end
function ui.offsetCursorX(x) cursor.x = cursor.x + x end
function ui.offsetCursorY(y) cursor.y = cursor.y + y end
function ui.availableSpace() return _H.ui.windowSize - cursor end
function ui.availableSpaceX() return _H.ui.windowSize.x - cursor.x end
function ui.availableSpaceY() return _H.ui.windowSize.y - cursor.y end
function ui.measureText(t) return vec2(#tostring(t) * 7, 14) end
function ui.measureDWriteText(t, size) return vec2(#tostring(t) * (size or 14) * 0.55, size or 14) end
function ui.textLineHeight() return 14 end
function ui.frameHeight() return 20 end
function ui.text(t) rec('text') cursor.y = cursor.y + 16 end
function ui.textWrapped(t) rec('text') cursor.y = cursor.y + 16 end
function ui.textColored(t, c) rec('text') cursor.y = cursor.y + 16 end
function ui.textAligned(t, a, s) rec('textAligned') cursor.y = cursor.y + 16 end
function ui.header(t) rec('header') cursor.y = cursor.y + 18 end
function ui.dwriteText(t, size, color) rec('dwriteText') cursor.y = cursor.y + (size or 14) + 2 end
function ui.dwriteTextAligned(t, size, ha, va, s, ell, c) rec('dwriteTextAligned') end
function ui.dwriteDrawText(t, size, pos, color) rec('dwriteDrawText') end
function ui.drawText(t, pos, color) rec('drawText') end
function ui.pushFont(f) rec('pushFont') uiState.fontStack[#uiState.fontStack+1] = f end
function ui.popFont() if #uiState.fontStack == 0 then error('ui.popFont without pushFont') end uiState.fontStack[#uiState.fontStack] = nil end
function ui.pushDWriteFont(f) rec('pushDWriteFont') uiState.fontStack[#uiState.fontStack+1] = f end
function ui.popDWriteFont() if #uiState.fontStack == 0 then error('ui.popDWriteFont without push') end uiState.fontStack[#uiState.fontStack] = nil end
function ui.DWriteFont(name, dir) return setmetatable({ name = name }, { __index = function(t, k) return function(self) return self end end, __tostring = function(t) return t.name end }) end
function ui.setNextTextBold() end
function ui.setNextItemWidth() end
function ui.pushItemWidth() end
function ui.popItemWidth() end
function ui.pushStyleColor(id, c) rec('pushStyleColor') uiState.styleDepth = (uiState.styleDepth or 0) + 1 end
function ui.popStyleColor(n) uiState.styleDepth = (uiState.styleDepth or 0) - (n or 1) if uiState.styleDepth < 0 then error('ui.popStyleColor underflow') end end
function ui.pushStyleVar(id, v) rec('pushStyleVar') uiState.varDepth = (uiState.varDepth or 0) + 1 end
function ui.popStyleVar(n) uiState.varDepth = (uiState.varDepth or 0) - (n or 1) if uiState.varDepth < 0 then error('ui.popStyleVar underflow') end end
function ui.pushID(id) uiState.idStack[#uiState.idStack+1] = id end
function ui.popID() if #uiState.idStack == 0 then error('ui.popID underflow') end uiState.idStack[#uiState.idStack] = nil end
function ui.separator() rec('separator') cursor.y = cursor.y + 6 end
function ui.sameLine(o, s) end
function ui.newLine() cursor.y = cursor.y + 16 end
function ui.dummy(s) end
function ui.invisibleButton() return false end
function ui.button(l, s, f) rec('button') cursor.y = cursor.y + 22 return false end
function ui.smallButton() rec('button') return false end
function ui.modernButton() rec('button') return false end
function ui.iconButton() rec('button') return false end
function ui.checkbox(l, v) rec('checkbox') cursor.y = cursor.y + 20 return false end
function ui.radioButton(l, v) return false end
function ui.slider(l, v, mn, mx, fmt, pw) rec('slider') cursor.y = cursor.y + 22 return v, false end
function ui.inputText(l, s, f, sz) rec('inputText') cursor.y = cursor.y + 22 return s, false end
function ui.combo(l, preview, flags, content) rec('combo') if type(flags) == 'function' then content = flags end if content then content() end return false end
function ui.selectable(l, sel) return false end
function ui.itemHovered() return false end
function ui.itemClicked() return false end
function ui.itemEdited() return false end
function ui.itemActive() return false end
function ui.mouseClicked() return false end
function ui.setTooltip() end
function ui.tooltip(cb) end
function ui.beginGroup() uiState.groupDepth = uiState.groupDepth + 1 end
function ui.endGroup() uiState.groupDepth = uiState.groupDepth - 1 if uiState.groupDepth < 0 then error('ui.endGroup underflow') end end
function ui.beginChild(id, size, border, flags) rec('beginChild') uiState.childDepth = uiState.childDepth + 1 return true end
function ui.endChild() uiState.childDepth = uiState.childDepth - 1 if uiState.childDepth < 0 then error('ui.endChild underflow') end end
function ui.childWindow(id, size, border, flags, content) rec('childWindow') if type(border) == 'function' then content = border elseif type(flags) == 'function' then content = flags end if content then content() end end
function ui.toolWindow(id, pos, size, noPadding, inputs, content) rec('toolWindow') for _, a in ipairs({noPadding, inputs, content}) do if type(a) == 'function' then a() break end end end
function ui.transparentWindow(id, pos, size, noPadding, inputs, content) rec('transparentWindow') for _, a in ipairs({noPadding, inputs, content}) do if type(a) == 'function' then a() break end end end
function ui.beginTransparentWindow() rec('beginTransparentWindow') return true end
function ui.endTransparentWindow() end
function ui.beginToolWindow() return true end
function ui.endToolWindow() end
function ui.tabBar(id, flags, content) if type(flags) == 'function' then content = flags end if content then content() end end
function ui.tabItem(label, flags, content) if type(flags) == 'function' then content = flags end if content then content() end end
function ui.columns(n) end
function ui.nextColumn() end
function ui.setColumnWidth() end
function ui.drawRect(p1, p2, c) rec('drawRect') end
function ui.drawRectFilled(p1, p2, c) rec('drawRectFilled') assert(p1 and p2 and c, 'drawRectFilled needs p1, p2, color') end
function ui.drawRectFilledMultiColor() rec('drawRectFilled') end
function ui.drawCircle(p, r, c) rec('drawCircle') end
function ui.drawCircleFilled(p, r, c) rec('drawCircleFilled') assert(p and r and c, 'drawCircleFilled needs pos, radius, color') end
function ui.drawLine(a, b, c) rec('drawLine') assert(a and b and c, 'drawLine needs p1, p2, color') end
function ui.drawSimpleLine(a, b, c) rec('drawLine') end
function ui.drawTriangleFilled(a, b, c, col) rec('drawTriangleFilled') end
function ui.drawQuadFilled() rec('drawQuadFilled') end
function ui.drawPolyline() rec('drawPolyline') end
function ui.drawImage() rec('drawImage') end
function ui.image() rec('image') end
function ui.pathClear() end function ui.pathLineTo() end function ui.pathStroke() end function ui.pathFillConvex() end function ui.pathArcTo() end
function ui.progressBar(f, s, o) rec('progressBar') cursor.y = cursor.y + 20 end
function ui.icon() rec('icon') end
function ui.isKnownIcon24() return false end
function ui.copyable(t) rec('text') end
function ui.textHyperlink() return false end
function ui.alignTextToFramePadding() end
function ui.toast() end
function ui.modalPopup() end
function ui.drawLoadingSpinner() end
function ui.keyboardButtonDown() return false end
function ui.keyboardButtonPressed() return false end
function ui.mouseLocalPos() return vec2(0, 0) end
function ui.mouseDown() return false end
function ui.windowHovered() return false end
function ui.windowFocused() return false end
function ui.isWindowAppearing() return false end
function ui.setNextWindowBgAlpha() end
function ui.beginOutline() end function ui.endOutline() end
function ui.beginScale() end function ui.endScale() end
function ui.beginRotation() end function ui.endRotation() end
function ui.pushClipRect() end function ui.popClipRect() end
function ui.dwriteSetTextAlign() end
function ui.MediaPlayer() return { setSource = function(s) return s end, play = function() end, pause = function() end } end
ui.Icons = setmetatable({}, { __index = function(_, k) return 'icon:' .. k end })
ui.Alignment = { Start = 0, Center = 0.5, End = 1 }
render = setmetatable({}, { __index = function(_, k) return function() end end })
physics = setmetatable({}, { __index = function(_, k) return function() end end })
