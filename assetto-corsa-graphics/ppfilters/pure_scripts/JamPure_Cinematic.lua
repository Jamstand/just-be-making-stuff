--[[
  JamPure Cinematic - Pure script (v1.2)
  ------------------------------------------------------------------------
  Pure loads this file automatically whenever the PP filter with the same
  name ("JamPure_Cinematic.ini") is active. It must live in:

      assettocorsa\system\cfg\ppfilters\pure_scripts\JamPure_Cinematic.lua

  (folder name exactly "pure_scripts", with an underscore). The Pure PP app's
  File tab shows "Script loaded: JamPure_Cinematic.lua" when Pure found it.

  What it adds on top of the .ini filter:
    * Pure's cubemap-based exposure (CBE) with day / night targets, limits and
      adaption speeds set the way current Pure filters do, plus a live gain
    * Colour profiles (Cinematic / Natural / Vivid / Vintage / Dashcam)
    * Glare profiles + automatic night glare boost
    * Warmth, contrast, saturation, brightness, teal-shadow, film-fade sliders
    * Godrays length that follows Pure's sun-cover modulation

  Requirements for the exposure part (same as every CBE-driven filter):
    * AC video settings: reflections rendering frequency must not be "static"
    * CSP > Reflections FX: "Use proper physically-based sampling" enabled

  The controls appear in the Pure Config app (script section) while the filter
  is active. Pure saves them between sessions.

  API notes: current Pure exposes a `pure.*` table (pure.script.ui, pure.exposure.cbe,
  pure.mod, pure.pp ...). Older builds only have the __SCRIPT__* / PURE__* globals.
  Every call below resolves the new name first and falls back to the old one, and
  runs through `try()` so a missing function never kills the script.
]]

local SCRIPT_VERSION = 1.2

local base  -- filter values, filled in below

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

-- Call `f` if it exists, swallow errors, return the first result (or nil).
local function try(f, ...)
  if f == nil then return nil end
  local ok, result = pcall(f, ...)
  if ok then return result end
  return nil
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function round(v)
  return math.floor(v + 0.5)
end

-- Resolve a dotted path inside the global `pure` table ("script.ui.getValue").
local function P(path)
  local node = pure
  if node == nil then return nil end
  for part in string.gmatch(path, '[^%.]+') do
    if type(node) ~= 'table' then return nil end
    node = node[part]
    if node == nil then return nil end
  end
  if type(node) == 'function' then return node end
  return nil
end

-- New API first, legacy global second (legacy arg is nil when the global is missing).
local function api(path, legacy)
  return P(path) or legacy
end

-- 0 by day, 1 by night.
local function nightAmount()
  local v = try(P('mod.night'), 0)                 -- pure.mod.night(0): 0 by day, 1 by night
  if type(v) == 'number' then return clamp(v, 0, 1) end
  v = try(day_compensate, 0)                       -- legacy: 1 by day, 0 by night
  if type(v) == 'number' then return 1 - clamp(v, 0, 1) end
  return 0
end

-- ---------------------------------------------------------------------------
-- values read from the active .ini filter (so edits to the ini are respected)
-- ---------------------------------------------------------------------------

base = {
  brightness = 1.0,
  contrast = 1.03,
  saturation = 1.04,
  hue = 0,
  sepia = 0.02,
  colorTemp = 6500,
  whiteBalance = 6800,
  tonemap = 7,           -- ac.TonemapFunction.ACES
  filmicContrast = 0.55,
  glareThreshold = 6,
  bloomFilterThreshold = 0.0015,
  starFilterThreshold = 0.0004,
  godraysLength = 12,
}

local function readFilterValues()
  local get = Pure_get_PPfilter_entry
  if get == nil then return end
  local function r(section, key, default)
    local v = try(get, section, key)
    if type(v) == 'number' then return v end
    return default
  end
  base.tonemap = r('TONEMAPPING', 'FUNCTION', base.tonemap)
  base.brightness = r('COLOR', 'BRIGHTNESS', base.brightness)
  base.contrast = r('COLOR', 'CONTRAST', base.contrast)
  base.saturation = r('COLOR', 'SATURATION', base.saturation)
  base.hue = r('COLOR', 'HUE', base.hue)
  base.sepia = r('COLOR', 'SEPIA', base.sepia)
  base.colorTemp = r('COLOR', 'COLOR_TEMP', base.colorTemp)
  base.whiteBalance = r('COLOR', 'WHITE_BALANCE', base.whiteBalance)
  base.filmicContrast = r('EXT_HDR', 'FILMIC_CONTRAST', base.filmicContrast)
  base.glareThreshold = r('GLARE', 'THRESHOLD', base.glareThreshold)
  base.bloomFilterThreshold = r('GLARE', 'BLOOM_FILTER_THRESHOLD', base.bloomFilterThreshold)
  base.starFilterThreshold = r('GLARE', 'STAR_FILTER_THRESHOLD', base.starFilterThreshold)
  base.godraysLength = r('GODRAYS', 'LENGTH', base.godraysLength)
end

-- ---------------------------------------------------------------------------
-- colour profiles
--   sat / con   multipliers on the filter's saturation / contrast
--   temp / wb   Kelvin offsets on the filter's colour temperature / white balance
--   sepia       absolute sepia amount
--   tonemap     ac.TonemapFunction id (2 Sensitometric, 7 ACES, 8 Uchimura,
--               10 Lottes, 11 Uncharted, 13 Filmic)
--   lift        rgb bias added to the whole frame (tiny values, lifts shadows)
--   fade        strength of the FadeRgb "washed film" correction
-- ---------------------------------------------------------------------------

local PROFILES = {
  [0] = { name = 'Cinematic', sat = 1.00, con = 1.00, temp = 0,    wb = 0,    sepia = 0.02, tonemap = 7,  lift = { 0.000, 0.005, 0.010 }, fade = 0.05, liftFollowsTeal = true },
  [1] = { name = 'Natural',   sat = 0.96, con = 0.97, temp = 0,    wb = -300, sepia = 0.00, tonemap = 2,  lift = { 0, 0, 0 },             fade = 0.00 },
  [2] = { name = 'Vivid',     sat = 1.14, con = 1.04, temp = 0,    wb = 150,  sepia = 0.00, tonemap = 7,  lift = { 0, 0, 0 },             fade = 0.00 },
  [3] = { name = 'Vintage',   sat = 0.84, con = 0.95, temp = -150, wb = 500,  sepia = 0.14, tonemap = 13, lift = { 0.008, 0.005, 0.000 }, fade = 0.18 },
  [4] = { name = 'Dashcam',   sat = 0.90, con = 1.10, temp = 100,  wb = -450, sepia = 0.00, tonemap = 2,  lift = { 0.000, 0.004, 0.003 }, fade = 0.00 },
}

-- glare profile -> multiplier applied to the glare thresholds
-- (lower threshold = more things bloom)
local GLARE_PROFILES = {
  [0] = 1.6,   -- subtle
  [1] = 1.0,   -- filter default
  [2] = 0.7,   -- strong
  [3] = 0.5,   -- max
}

-- ---------------------------------------------------------------------------
-- colour corrections owned by this script (registered once in init)
-- ---------------------------------------------------------------------------

local ccLift, ccFade
local lastLift = { nil, nil, nil }
local lastFade = nil
local lastTonemap = nil

local function registerColorCorrections()
  if ac == nil or ac.weatherColorCorrections == nil then return end
  local list = ac.weatherColorCorrections
  local function register(cc)
    if cc == nil then return nil end
    local ok = pcall(function() list[#list + 1] = cc end)
    if ok then return cc end
    return nil
  end
  ccLift = register(try(ac.ColorCorrectionBiasRgb, { color = rgb(0, 0, 0) }))
  ccFade = register(try(ac.ColorCorrectionFadeRgb, { color = rgb(1.0, 0.96, 0.90), effectRatio = 0 }))
end

local function setLift(r, g, b)
  if not ccLift then return end
  if lastLift[1] == r and lastLift[2] == g and lastLift[3] == b then return end
  lastLift[1], lastLift[2], lastLift[3] = r, g, b
  ccLift.color = rgb(r, g, b)
end

local function setFade(amount)
  if not ccFade then return end
  if lastFade == amount then return end
  lastFade = amount
  ccFade.effectRatio = amount
end

-- ---------------------------------------------------------------------------
-- UI (new pure.script.ui first, legacy __SCRIPT__UI_* second)
-- ---------------------------------------------------------------------------

local function uiSlider(name, default, lo, hi)
  try(api('script.ui.addSliderFloat', __SCRIPT__UI_SliderFloat), name, default, lo, hi)
end

local function uiCheckbox(name, default)
  try(api('script.ui.addCheckbox', __SCRIPT__UI_Checkbox), name, default)
end

local function uiSeparator()
  try(api('script.ui.addSeparator', __SCRIPT__UI_Separator))
end

local function uiText(text)
  try(api('script.ui.addText', __SCRIPT__UI_Text), text)
end

local function uiState(name, value)
  try(api('script.ui.addStateFloat', __SCRIPT__UI_StateFloat), name, value)
end

local function uiSet(name, value)
  try(api('script.ui.setValue', __SCRIPT__UI_setValue), name, value)
end

local function uiGet(name)
  return try(api('script.ui.getValue', __SCRIPT__UI_getValue), name)
end

-- ---------------------------------------------------------------------------
-- Pure entry points
-- ---------------------------------------------------------------------------

function init_pure_script()
  readFilterValues()
  registerColorCorrections()

  -- Pure's cubemap brightness estimation drives exposure; values in the range
  -- current Pure filters ship with (target ~1.3 by day, ~2.5 at night,
  -- iris limits 0.05..0.8, 2 s / 4 s adaption).
  try(PURE__use_ExpCalc, true)
  try(api('exposure.cbe.setSensitivity', PURE__ExpCalc_set_Sensitivity), 1)
  try(api('exposure.cbe.setLimits', PURE__ExpCalc_set_Limits), 0.05, 0.8)
  try(api('exposure.cbe.setAdaptionSpeeds', PURE__ExpCalc_set_AdaptionSpeeds), 2.0, 4.0)
  try(api('exposure.cbe.setTarget', PURE__ExpCalc_set_Target), 1.4)
  try(api('exposure.cbe.setMultiplier', PURE__ExpCalc_set_Multiplier), 1.0)

  try(api('script.setVersion', __SCRIPT__setVersion), SCRIPT_VERSION)
  try(api('script.resetSettingsWithNewVersion', __SCRIPT__ResetSettingsWithNewVersion))

  uiText('Exposure (Pure cubemap estimate)')
  uiSlider('Exposure target day', 1.4, 0.3, 4.0)
  uiSlider('Exposure target night', 2.6, 0.3, 6.0)
  uiSlider('Exposure gain', 1.0, 0.3, 3.0)
  uiSlider('Brightness', 1.0, 0.5, 2.0)
  uiCheckbox('Exposure adaption', true)
  uiSlider('Exposure adaption interior', 0.90, 0.0, 1.0)
  uiSlider('Exposure adaption exterior', 0.50, 0.0, 1.0)
  uiSlider('Spectrum adaption', 0.5, 0.0, 1.0)
  uiSlider('VAO adaption', 0.5, 0.0, 1.0)
  uiState('Final exposure', 0)
  uiSeparator()

  uiText('Look')
  uiSlider('Color profile (0 Cine 1 Natural 2 Vivid 3 Vintage 4 Dashcam)', 0, 0, 4)
  uiSlider('Warmth', 0.0, -1.0, 1.0)
  uiSlider('Saturation', 1.0, 0.5, 1.5)
  uiSlider('Contrast', 1.0, 0.8, 1.3)
  uiSlider('Teal shadows', 0.35, 0.0, 1.0)
  uiSlider('Film fade', 1.0, 0.0, 2.0)
  uiSlider('Tonemap override (-1 = profile)', -1, -1, 14)
  uiSeparator()

  uiText('Glare and sunrays')
  uiSlider('Glare profile (0 subtle 1 default 2 strong 3 max)', 1, 0, 3)
  uiSlider('Night glare boost', 1.0, 0.0, 2.0)
  uiSlider('Night brightness lift', 0.06, 0.0, 0.25)
  uiSlider('Godrays length', 1.0, 0.0, 2.0)
end

function update_pure_script(dt)
  local function num(name, default)
    local v = uiGet(name)
    if type(v) == 'number' then return v end
    if type(v) == 'boolean' then return v and 1 or 0 end
    return default
  end

  local function flag(name, default)
    local v = uiGet(name)
    if type(v) == 'boolean' then return v end
    if type(v) == 'number' then return v ~= 0 end
    return default
  end

  local night = nightAmount()

  -- ---- exposure -----------------------------------------------------------
  local adapt = flag('Exposure adaption', true)
  local gain = clamp(num('Exposure gain', 1), 0.1, 4)
  local target = lerp(num('Exposure target day', 1.4), num('Exposure target night', 2.6), night)

  try(PURE__use_ExpCalc, adapt)
  try(api('exposure.cbe.setTarget', PURE__ExpCalc_set_Target), target)
  try(api('exposure.cbe.setMultiplier', PURE__ExpCalc_set_Multiplier), gain)
  if adapt then
    local interior = (ac ~= nil) and (try(ac.isInteriorView) == true)
    try(PURE__set_ExpCalc, interior and num('Exposure adaption interior', 0.9) or num('Exposure adaption exterior', 0.5))
  else
    try(PURE__set_ExpCalc, 0)
  end

  local spectrum = clamp(num('Spectrum adaption', 0.5), 0, 1)
  local vao = clamp(num('VAO adaption', 0.5), 0, 1)
  if P('light.setSpectrumAdaption') then
    try(P('light.setSpectrumAdaption'), spectrum)
    try(P('light.setVAOAdaption'), vao)
  else
    try(PURE__use_SpectrumAdaption, spectrum > 0)
    try(PURE__use_VAOAdaption, vao > 0)
  end

  local finalExposure = try(api('exposure.getValue', PURE__ExpCalc_get_final_exposure))
  if type(finalExposure) == 'number' then uiSet('Final exposure', finalExposure) end

  -- everything below only matters while post-processing is on
  if try(PURE__getPP_enabled) == false then return end
  if ac == nil then return end

  -- ---- colour profile -----------------------------------------------------
  local profileIndex = clamp(round(num('Color profile (0 Cine 1 Natural 2 Vivid 3 Vintage 4 Dashcam)', 0)), 0, 4)
  local p = PROFILES[profileIndex]
  local warmth = clamp(num('Warmth', 0), -1, 1)
  local satMul = num('Saturation', 1)
  local conMul = num('Contrast', 1)
  local teal = clamp(num('Teal shadows', 0.35), 0, 1)
  local fadeMul = num('Film fade', 1)
  local brightnessLift = num('Night brightness lift', 0.06)
  local brightness = clamp(num('Brightness', 1), 0.1, 4)

  try(ac.setPpSaturation, base.saturation * p.sat * satMul)
  try(ac.setPpContrast, base.contrast * p.con * conMul)
  try(ac.setPpBrightness, base.brightness * brightness * lerp(1.0, 1.0 + brightnessLift, night))
  try(ac.setPpHue, base.hue)
  try(ac.setPpSepia, p.sepia)
  try(ac.setPpColorTemperatureK, base.colorTemp + p.temp)
  try(ac.setPpWhiteBalanceK, base.whiteBalance + p.wb + warmth * 600)

  local liftScale = p.liftFollowsTeal and teal or 1
  setLift(p.lift[1] * liftScale, p.lift[2] * liftScale, p.lift[3] * liftScale)
  setFade(clamp(p.fade * fadeMul, 0, 1))

  -- tonemapping: only poke CSP when the function actually changes
  local override = round(num('Tonemap override (-1 = profile)', -1))
  local tonemap = (override >= 0) and clamp(override, 0, 14) or p.tonemap
  if tonemap ~= lastTonemap then
    lastTonemap = tonemap
    try(ac.setPpTonemapFunction, tonemap)
    try(ac.setPpTonemapFilmicContrast, base.filmicContrast)
  end

  -- ---- glare --------------------------------------------------------------
  local glareIndex = clamp(round(num('Glare profile (0 subtle 1 default 2 strong 3 max)', 1)), 0, 3)
  local glareMul = GLARE_PROFILES[glareIndex]
  local nightBoost = clamp(num('Night glare boost', 1), 0, 2)
  local nightMul = lerp(1, 1 / (1 + 0.6 * nightBoost), night)

  try(ac.setGlareThreshold, base.glareThreshold * glareMul * nightMul)
  try(ac.setGlareBloomFilterThreshold, base.bloomFilterThreshold * glareMul)
  try(ac.setGlareStarFilterThreshold, base.starFilterThreshold * glareMul)

  -- ---- godrays ------------------------------------------------------------
  local modulator = try(api('pp.getGodraysModulator', PURE__getGodraysModulator))
  if type(modulator) ~= 'number' then modulator = 1 end
  try(ac.setGodraysLength, base.godraysLength * modulator * num('Godrays length', 1))
end
