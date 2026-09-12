--[[
  JamPure Cinematic - Pure script
  ------------------------------------------------------------------------
  Pure loads this file automatically whenever the PP filter with the same
  name ("JamPure_Cinematic.ini") is active. It must live in:

      assettocorsa\system\cfg\ppfilters\Pure scripts\JamPure_Cinematic.lua

  What it adds on top of the .ini filter:
    * Colour profiles (Cinematic / Natural / Vivid / Vintage / Dashcam)
    * Glare profiles + automatic night glare boost
    * Warmth, contrast, saturation, teal-shadow and film-fade sliders
    * Pure's cubemap-based exposure adaption with separate interior /
      exterior strength, spectrum adaption and VAO adaption toggles
    * Godrays length that follows Pure's sun-cover modulation

  The controls show up in the Pure Config app (PP / script section) while
  the filter is active. Values are saved by Pure between sessions.

  Everything the script touches goes through `try()`, so if a Pure or CSP
  build lacks one of the API calls the script keeps working instead of
  erroring out.
]]

local SCRIPT_VERSION = 1.1

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

local base  -- filter values, filled in below

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

-- sign-preserving power (Pure's negative_pow): keeps the direction of a negative base
local function signedPow(v, e)
  if v < 0 then return -((-v) ^ e) end
  return v ^ e
end

-- Pure's cubemap-based exposure estimate is calibrated for a filter with exposure /
-- auto-exposure target 0.3 and gamma 1.2. Filters with a lower gamma end up darker,
-- so the multiplier gets a gamma term (same shape other Pure filters use).
local function exposureMultiplier()
  local reference = (base.aeEnabled > 0) and base.target or base.exposure
  return 1 + (reference - 0.3) + signedPow(3 * (1.2 - base.gamma ^ 0.4), 0.76)
end

-- 0 by day, 1 by night (Pure's day_compensate(v) returns 1 by day, v by night).
local function nightAmount()
  local dc = day_compensate
  if dc ~= nil then
    local v = try(dc, 0)
    if type(v) == 'number' then return 1 - clamp(v, 0, 1) end
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- values read from the active .ini filter (so edits to the ini are respected)
-- ---------------------------------------------------------------------------

base = {
  exposure = 0.30,
  gamma = 1.15,
  target = 0.32,
  aeEnabled = 1,
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
  base.exposure = r('TONEMAPPING', 'EXPOSURE', base.exposure)
  base.gamma = r('TONEMAPPING', 'GAMMA', base.gamma)
  base.tonemap = r('TONEMAPPING', 'FUNCTION', base.tonemap)
  base.target = r('AUTO_EXPOSURE', 'TARGET', base.target)
  base.aeEnabled = r('AUTO_EXPOSURE', 'ENABLED', base.aeEnabled)
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
-- Pure entry points
-- ---------------------------------------------------------------------------

function init_pure_script()
  readFilterValues()
  registerColorCorrections()

  -- Pure's exposure calculation (cubemap brightness estimation), scaled so the
  -- filter's own exposure / auto-exposure target and gamma are the reference point.
  try(PURE__use_ExpCalc, true)
  try(PURE__ExpCalc_set_Multiplier, exposureMultiplier())
  try(PURE__ExpCalc_set_Target, 1.0)

  try(__SCRIPT__setVersion, SCRIPT_VERSION)
  try(__SCRIPT__ResetSettingsWithNewVersion)

  -- look
  try(__SCRIPT__UI_SliderFloat, 'Color profile (0 Cine 1 Natural 2 Vivid 3 Vintage 4 Dashcam)', 0, 0, 4)
  try(__SCRIPT__UI_SliderFloat, 'Warmth', 0.0, -1.0, 1.0)
  try(__SCRIPT__UI_SliderFloat, 'Saturation', 1.0, 0.5, 1.5)
  try(__SCRIPT__UI_SliderFloat, 'Contrast', 1.0, 0.8, 1.3)
  try(__SCRIPT__UI_SliderFloat, 'Teal shadows', 0.35, 0.0, 1.0)
  try(__SCRIPT__UI_SliderFloat, 'Film fade', 1.0, 0.0, 2.0)
  try(__SCRIPT__UI_SliderFloat, 'Tonemap override (-1 = profile)', -1, -1, 14)
  try(__SCRIPT__UI_Separator)

  -- glare / godrays
  try(__SCRIPT__UI_SliderFloat, 'Glare profile (0 subtle 1 default 2 strong 3 max)', 1, 0, 3)
  try(__SCRIPT__UI_SliderFloat, 'Night glare boost', 1.0, 0.0, 2.0)
  try(__SCRIPT__UI_SliderFloat, 'Night brightness lift', 0.06, 0.0, 0.25)
  try(__SCRIPT__UI_SliderFloat, 'Godrays length', 1.0, 0.0, 2.0)
  try(__SCRIPT__UI_Separator)

  -- exposure
  try(__SCRIPT__UI_SliderFloat, 'Exposure gain', 1.0, 0.5, 2.5)
  try(__SCRIPT__UI_SliderFloat, 'Brightness', 1.0, 0.5, 2.0)
  try(__SCRIPT__UI_Checkbox, 'Exposure adaption', true)
  try(__SCRIPT__UI_SliderFloat, 'Exposure adaption interior', 0.90, 0.0, 1.0)
  try(__SCRIPT__UI_SliderFloat, 'Exposure adaption exterior', 0.50, 0.0, 1.0)
  try(__SCRIPT__UI_Checkbox, 'Spectrum adaption', true)
  try(__SCRIPT__UI_Checkbox, 'VAO adaption', false)
end

function update_pure_script(dt)
  local getValue = __SCRIPT__UI_getValue
  if getValue == nil then return end

  local function num(name, default)
    local v = try(getValue, name)
    if type(v) == 'number' then return v end
    if type(v) == 'boolean' then return v and 1 or 0 end
    return default
  end

  local function flag(name, default)
    local v = try(getValue, name)
    if type(v) == 'boolean' then return v end
    if type(v) == 'number' then return v ~= 0 end
    return default
  end

  -- ---- exposure -----------------------------------------------------------
  local adapt = flag('Exposure adaption', true)
  local gain = clamp(num('Exposure gain', 1), 0.1, 4)
  try(PURE__use_ExpCalc, adapt)
  try(PURE__ExpCalc_set_Multiplier, exposureMultiplier() * gain)
  if adapt then
    local interior = (ac ~= nil) and (try(ac.isInteriorView) == true)
    try(PURE__set_ExpCalc, interior and num('Exposure adaption interior', 0.9) or num('Exposure adaption exterior', 0.5))
  else
    try(PURE__set_ExpCalc, 0)
  end
  try(PURE__use_SpectrumAdaption, flag('Spectrum adaption', true))
  try(PURE__use_VAOAdaption, flag('VAO adaption', false))

  local finalExposure = try(PURE__ExpCalc_get_final_exposure)
  if type(finalExposure) == 'number' then
    try(__SCRIPT__UI_setValue, 'Final exposure', finalExposure)
  end

  -- everything below only matters while post-processing is on
  if try(PURE__getPP_enabled) == false then return end
  if ac == nil then return end

  local night = nightAmount()

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
  local modulator = try(PURE__getGodraysModulator)
  if type(modulator) ~= 'number' then modulator = 1 end
  try(ac.setGodraysLength, base.godraysLength * modulator * num('Godrays length', 1))
end
