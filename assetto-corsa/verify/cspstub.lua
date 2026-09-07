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
function ac.storage(defaults)
  local t = {}
  for k, v in pairs(defaults) do t[k] = v end
  return t
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
