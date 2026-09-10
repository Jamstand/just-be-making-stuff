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
-- CSP keys a Lua app's windows IMGUI_LUA_<[ABOUT] NAME>_<window ID>, and
-- ac.getAppWindows() lists them as { name = <that key>, title = <NAME> }.
WIN_ACCESS = { pos = {x = 100, y = 200}, size = {x = 280, y = 120}, moves = {}, resizes = {}, valid = true,
               name = 'IMGUI_LUA_Gear Speedo_main', title = 'Gear Speedo' }
ACCESS_CALLS = {}
function ac.getAppWindows() return { { name = WIN_ACCESS.name, title = WIN_ACCESS.title } } end
function ac.accessAppWindow(name)
  assert(type(name) == 'string', 'accessAppWindow needs a name')
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
function reset() RECT, TEXT, ICONBTN, DUMMY = {}, {}, {}, {} end
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

-- Windows, as CSP keeps them: which are open (ac.setWindowOpen / isWindowOpen),
-- where the one being drawn sits (ui.windowPos), whether the mouse is over it.
OPEN = { main = true }
OPEN_LOG = {}
function ac.setWindowOpen(id, v)
  assert(type(id) == 'string', 'setWindowOpen: id must be a string')
  OPEN[id] = v and true or false
  OPEN_LOG[#OPEN_LOG + 1] = { id = id, open = OPEN[id] }
end
function ac.isWindowOpen(id) return OPEN[id] == true end
WINPOS = { x = 100, y = 200 }
function ui.windowPos() return vec2(WINPOS.x, WINPOS.y) end
HOVER = false
function ui.windowHovered() return HOVER end
RCLICK = false
ui.MouseButton = { Left = 0, Right = 1 }
function ui.mouseClicked(b) return b == 1 and RCLICK end

-- Items the title-bar-less windows draw for themselves.
ui.Icons = { Settings = 'icon:settings', Cancel = 'icon:cancel' }
ui.StyleColor = { Button = 21, ButtonHovered = 22, ButtonActive = 23 }
STYLE_DEPTH = 0
function ui.pushStyleColor(c, col) assert(c and col, 'pushStyleColor needs a colour id and a colour'); STYLE_DEPTH = STYLE_DEPTH + 1 end
function ui.popStyleColor(n) STYLE_DEPTH = STYLE_DEPTH - (n or 1); assert(STYLE_DEPTH >= 0, 'popStyleColor without a push') end
CURSOR = nil
function ui.setCursor(v) assert(v and v.x, 'setCursor needs a vec2'); CURSOR = { x = v.x, y = v.y } end
function ui.sameLine(a, b) end
ICONBTN, CLICK = {}, {}          -- buttons drawn this frame; CLICK[icon] = true presses one
function ui.iconButton(icon, size, padding)
  assert(type(icon) == 'string' and size and size.x, 'iconButton(icon, vec2 size, padding)')
  ICONBTN[#ICONBTN + 1] = { icon = icon, size = size, at = CURSOR }
  return CLICK[icon] == true
end
function ui.itemHovered() return false end
function ui.setTooltip(t) assert(type(t) == 'string') end
DUMMY = {}
function ui.dummy(v) assert(v and v.x and v.y, 'dummy needs a vec2'); DUMMY[#DUMMY + 1] = { x = v.x, y = v.y } end
function ui.separator() end
POPUPS = {}                      -- ui.popup registrations: { fn, params }
function ui.popup(fn, params)
  assert(type(fn) == 'function', 'popup needs a callback')
  POPUPS[#POPUPS + 1] = { fn = fn, params = params or {} }
end
function ui.closePopup() end
