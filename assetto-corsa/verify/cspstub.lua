-- Stub of the CSP Lua API, recording what the app draws.
RECT, TEXT, FONTS = {}, {}, {}
local WIN = {x = 280, y = 120}
CAR = {gear = 0, rpm = 0, rpmLimiter = 7500, speedKmh = 0}
CAR_NIL = false

function vec2(x, y) return {x = x, y = y} end
function rgbm(r, g, b, a) return {r = r, g = g, b = b, a = a} end

ac = {}
function ac.getCar(i)
  assert(i == 0, 'unexpected car index ' .. tostring(i))
  if CAR_NIL then return nil end
  return CAR
end
STORAGE = nil                      -- the app's settings table, for probes
function ac.storage(defaults)
  local t = {}
  for k, v in pairs(defaults) do t[k] = v end
  STORAGE = t
  return t
end

-- Window accessor: what CSP hands back for ac.accessAppWindow. Records every
-- move/resize so a probe can see the lock working, and lets a probe "drag"
-- the window by editing WIN_ACCESS.pos directly.
WIN_ACCESS = { pos = {x = 100, y = 200}, size = {x = 280, y = 120}, moves = {}, resizes = {}, valid = true, name = 'Gear Speedo' }
ACCESS_CALLS = {}
function ac.accessAppWindow(name)
  ACCESS_CALLS[#ACCESS_CALLS + 1] = name
  if name ~= WIN_ACCESS.name then return nil end
  local a = {}
  function a:valid() return WIN_ACCESS.valid end
  function a:position() return vec2(WIN_ACCESS.pos.x, WIN_ACCESS.pos.y) end
  function a:size() return vec2(WIN_ACCESS.size.x, WIN_ACCESS.size.y) end
  function a:move(v) WIN_ACCESS.pos = {x = v.x, y = v.y}; WIN_ACCESS.moves[#WIN_ACCESS.moves + 1] = {x = v.x, y = v.y}; return a end
  function a:resize(v) WIN_ACCESS.size = {x = v.x, y = v.y}; WIN_ACCESS.resizes[#WIN_ACCESS.resizes + 1] = {x = v.x, y = v.y}; return a end
  return a
end

ui = {}
ui.Alignment = {Start = 0, Center = 1, End = 2}
function ui.windowSize() return WIN end
function ui.drawRectFilled(p1, p2, col)
  assert(p1 and p2 and col, 'drawRectFilled missing args')
  assert(p2.x >= p1.x and p2.y >= p1.y, 'inverted rect')
  RECT[#RECT + 1] = {p1 = p1, p2 = p2, col = col}
end
function ui.dwriteDrawTextClipped(text, size, p1, p2, ah, av, wrap, col)
  assert(type(text) == 'string', 'text must be a string, got ' .. type(text))
  assert(type(size) == 'number' and size > 0, 'bad font size: ' .. tostring(size))
  assert(p1 and p2, 'missing clip rect')
  assert(ah ~= nil and av ~= nil, 'missing alignment')
  assert(type(wrap) == 'boolean', 'wrap must be boolean')
  assert(col, 'missing colour')
  TEXT[#TEXT + 1] = {text = text, size = size, p1 = p1, p2 = p2, col = col}
end
function ui.pushDWriteFont(f) FONTS[#FONTS + 1] = f end
function ui.popDWriteFont() FONTS[#FONTS] = nil end
function ui.checkbox(l, v) return false end
function ui.slider(l, v) return v end
function ui.setNextItemWidth(w) end
function ui.itemEdited() return false end
function ui.text(t) end

function setWindow(w, h) WIN = {x = w, y = h} end
function reset() RECT, TEXT = {}, {} end
script = {}

-- Own-folder + manifest reading, the way CSP's WebBrowser app does it
-- (ac.INIConfig.load(__dirname..'/manifest.ini', ac.INIFormat.Extended)).
-- Values are comma-split into tables like CSP's reader, and with the Extended
-- format the [WINDOW_...] section is numbered WINDOW_0 to mimic CSP's
-- auto-numbering, so the app's prefix match is what gets exercised.
__dirname = ((arg and arg[0] or 'x'):match('^(.*)[/\\]') or '.') .. '/../apps/lua/GearSpeedo'
ac.INIFormat = { Default = 0, Extended = 1 }
ac.INIConfig = {}
INI_LOADS = {}
function ac.INIConfig.load(filename, format)
  INI_LOADS[#INI_LOADS + 1] = filename
  local f = assert(io.open(filename, 'rb'), 'INIConfig.load: cannot open ' .. tostring(filename))
  local text = f:read('*a'); f:close()
  local sections, cur, counter = {}, nil, {}
  for line in (text .. '\n'):gmatch('(.-)\r?\n') do
    line = line:gsub('%s*;.*$', '')
    local sec = line:match('^%s*%[(.-)%]%s*$')
    if sec then
      if format == ac.INIFormat.Extended and sec:sub(-3) == '...' then
        local base = sec:sub(1, -4); counter[base] = (counter[base] or -1) + 1
        sec = base .. counter[base]
      end
      cur = {}; sections[sec] = cur
    elseif cur then
      local k, v = line:match('^%s*([%w_%.]+)%s*=%s*(.-)%s*$')
      if k then local t = {}; for item in v:gmatch('[^,]+') do t[#t + 1] = item:match('^%s*(.-)%s*$') end; cur[k] = t end
    end
  end
  return { sections = sections, get = function(self, section, key, default)
    local s = self.sections[section]; if not s or not s[key] then return default end
    return type(default) == 'table' and s[key] or s[key][1]
  end }
end
