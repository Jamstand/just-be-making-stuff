"""
Gear Speedo - a small in-game dashboard for Assetto Corsa.

Big gear indicator, road speed, and an 18-segment RPM bar with shift lights.

Deliberately pure Python: no ctypes, no shared memory, no bundled .pyd shims.
AC ships its standard library as a zip (system/x64/python33.zip) and CPython
cannot import C extension modules from inside a zip, so `import ctypes` fails
unless the app carries its own architecture-specific binaries. Avoiding it
entirely means this app loads on both acs.exe (x64) and acs_x86.exe with
nothing to install.

The one thing that costs us is the rev limit, which normally comes from the
shared-memory static block. See _learn_redline() for how it is recovered.
"""

import ac
import acsys

import os
import traceback


# ---------------------------------------------------------------- constants

APP_WINDOW_NAME = "Gear Speedo"   # keep as a literal: CM regexes the source
                                  # for ac.newApp("...") to find the icon name

# Design-space layout, in pixels at SCALE=100. Everything is multiplied by
# `_scale` at build time, so tweak these and keep the proportions.
DES_W, DES_H = 280.0, 120.0

BAR_X, BAR_Y = 14.0, 10.0
BAR_W, BAR_H = 252.0, 12.0
BAR_SEGMENTS = 18
BAR_SEG_GAP = 2.0

GEAR_Y, GEAR_SIZE = 24.0, 58.0
SPEED_Y, SPEED_SIZE = 38.0, 44.0
CAPTION_Y, CAPTION_SIZE = 92.0, 10.0

DIVIDER_X, DIVIDER_Y = 139.0, 34.0
DIVIDER_W, DIVIDER_H = 1.0, 52.0

GEAR_CX_SPLIT = 70.0      # gear centre when the speed readout is shown
SPEED_CX = 196.0
GEAR_CX_SOLO = DES_W / 2  # gear centre when it is on its own

# Fractions of the redline at which the bar changes colour. Red has to start
# well below SHIFT_AT, or the white shift flash covers it before you see it.
GREEN_UNTIL = 0.55
AMBER_UNTIL = 0.78

# Colours: (r, g, b) floats 0..1.
C_GREEN = (0.35, 0.85, 0.42)
C_AMBER = (0.98, 0.75, 0.16)
C_RED = (0.95, 0.24, 0.24)
C_FLASH = (1.00, 1.00, 1.00)
C_TRACK = (1.00, 1.00, 1.00)      # drawn at low alpha as the unlit segment
C_TEXT = (0.94, 0.95, 0.97)
C_DIM = (0.55, 0.58, 0.64)

BLINK_PERIOD = 0.22               # seconds, full on/off cycle of the shift flash

# Until the limiter has confirmed the real rev limit, pad the highest RPM we
# have actually seen so the bar is not permanently pegged at full.
UNCONFIRMED_HEADROOM = 1.06
MIN_REDLINE = 3000.0              # floor, so the very first frames cannot /0


# ------------------------------------------------------------------- config

_scale = 1.0
_units_mph = False
_show_speed = True
_opacity = 0.70
_shift_at = 0.95


def _read_config():
    """Load GearSpeedo.ini if it is there. Any problem falls back to defaults."""
    global _scale, _units_mph, _show_speed, _opacity, _shift_at

    try:
        import configparser
    except Exception:
        return

    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "GearSpeedo.ini")
    if not os.path.isfile(path):
        return

    try:
        # AC ships Python 3.3, where inline comments are NOT stripped by
        # default -- without inline_comment_prefixes, "100 ; App scale" parses
        # as the literal string. Interpolation is off because the annotation
        # comments Content Manager reads are full of '%'.
        parser = configparser.ConfigParser(inline_comment_prefixes=(";", "#"),
                                           interpolation=None)
        parser.read(path)

        def raw(key, default):
            try:
                value = parser.get("CONFIG", key)
            except Exception:
                return default
            # Belt and braces, in case inline_comment_prefixes ever regresses.
            for mark in (";", "#"):
                if mark in value:
                    value = value.split(mark, 1)[0]
            value = value.strip()
            return value if value else default

        def number(key, default, low, high):
            try:
                return min(max(float(raw(key, default)), low), high)
            except Exception:
                return default

        _scale = number("SCALE", 100.0, 50.0, 200.0) / 100.0
        _opacity = number("OPACITY", 70.0, 0.0, 100.0) / 100.0
        _shift_at = number("SHIFT_AT", 95.0, 80.0, 100.0) / 100.0
        _units_mph = raw("UNITS", "KMH").upper().startswith("MPH")
        _show_speed = raw("SHOW_SPEED", "1") not in ("0", "false", "False")
    except Exception:
        ac.log("GearSpeedo: config unreadable, using defaults\n"
               + traceback.format_exc())


# -------------------------------------------------------------------- state

app_window = None
label_gear = None
label_speed = None
label_gear_caption = None
label_speed_caption = None

_redline = MIN_REDLINE
_observed_max = 0.0
_limiter_rpm = 0.0
_limiter_confirmed = False
_current_car = ""

_rpm_fraction = 0.0        # 0..1, what the bar draws
_shift = False             # at or past the shift threshold
_blink_on = False
_blink_clock = 0.0
_housekeeping = 0.0

_last_gear_text = None
_last_speed_text = None
_gear_is_red = False
_update_failed = False


def _reset_redline():
    global _redline, _observed_max, _limiter_rpm, _limiter_confirmed
    _redline = MIN_REDLINE
    _observed_max = 0.0
    _limiter_rpm = 0.0
    _limiter_confirmed = False


# ----------------------------------------------------------------- telemetry

def format_gear(raw_gear):
    """AC returns 0 for reverse, 1 for neutral, and 2 for first gear."""
    if raw_gear <= 0:
        return "R"
    if raw_gear == 1:
        return "N"
    return str(raw_gear - 1)


def _learn_redline(rpm, limiter_on):
    """Estimate the rev limit without shared memory.

    The Python API exposes no maxRPM, but it does expose IsEngineLimiterOn.
    The moment the limiter cuts in we know we are *at* the limit, so the
    highest RPM seen while it is active is the rev limit almost exactly.

    Before that has ever happened we fall back to the highest RPM seen so far,
    padded a little so the bar is not stuck at full every time you set a new
    personal best rev. The estimate therefore starts approximate and snaps to
    exact the first time you bounce off the limiter.
    """
    global _redline, _observed_max, _limiter_rpm, _limiter_confirmed

    if rpm > _observed_max:
        _observed_max = rpm

    if limiter_on and rpm > MIN_REDLINE * 0.5:
        _limiter_confirmed = True
        if rpm > _limiter_rpm:
            _limiter_rpm = rpm

    if _limiter_confirmed and _limiter_rpm > 0.0:
        _redline = _limiter_rpm
    else:
        _redline = max(_observed_max * UNCONFIRMED_HEADROOM, MIN_REDLINE)


# ------------------------------------------------------------------ drawing

def _quad(x, y, w, h, colour, alpha=1.0):
    ac.glColor4f(colour[0], colour[1], colour[2], alpha)
    ac.glQuad(x * _scale, y * _scale, w * _scale, h * _scale)


def on_render(delta_t):
    """Every gl* call has to happen inside the render callback or AC drops it."""
    try:
        seg_w = (BAR_W - (BAR_SEGMENTS - 1) * BAR_SEG_GAP) / BAR_SEGMENTS
        lit = int(_rpm_fraction * BAR_SEGMENTS + 0.0001)

        for i in range(BAR_SEGMENTS):
            x = BAR_X + i * (seg_w + BAR_SEG_GAP)

            if i >= lit:
                _quad(x, BAR_Y, seg_w, BAR_H, C_TRACK, 0.10)
                continue

            if _shift and _blink_on:
                _quad(x, BAR_Y, seg_w, BAR_H, C_FLASH, 1.0)
                continue

            position = (i + 1.0) / BAR_SEGMENTS
            if position <= GREEN_UNTIL:
                colour = C_GREEN
            elif position <= AMBER_UNTIL:
                colour = C_AMBER
            else:
                colour = C_RED
            _quad(x, BAR_Y, seg_w, BAR_H, colour, 1.0)

        if _show_speed:
            _quad(DIVIDER_X, DIVIDER_Y, DIVIDER_W, DIVIDER_H, C_TRACK, 0.12)
    except Exception:
        ac.log("GearSpeedo: render failed\n" + traceback.format_exc())


# -------------------------------------------------------------- app lifecycle

def acMain(ac_version):
    global app_window, label_gear, label_speed
    global label_gear_caption, label_speed_caption

    try:
        _read_config()

        gear_cx = GEAR_CX_SPLIT if _show_speed else GEAR_CX_SOLO

        app_window = ac.newApp("Gear Speedo")
        ac.setTitle(app_window, "")
        ac.setIconPosition(app_window, -9000, -9000)
        ac.setSize(app_window, DES_W * _scale, DES_H * _scale)
        ac.drawBorder(app_window, 0)
        ac.setBackgroundOpacity(app_window, _opacity)
        ac.addRenderCallback(app_window, on_render)

        # No setCustomFont: that needs a matching font in content/fonts, and a
        # missing one is a silent failure. The stock label font is fine.
        label_gear = ac.addLabel(app_window, "N")
        ac.setFontAlignment(label_gear, "center")
        ac.setFontSize(label_gear, GEAR_SIZE * _scale)
        ac.setFontColor(label_gear, C_TEXT[0], C_TEXT[1], C_TEXT[2], 1.0)
        ac.setPosition(label_gear, gear_cx * _scale, GEAR_Y * _scale)

        label_gear_caption = ac.addLabel(app_window, "GEAR")
        ac.setFontAlignment(label_gear_caption, "center")
        ac.setFontSize(label_gear_caption, CAPTION_SIZE * _scale)
        ac.setFontColor(label_gear_caption, C_DIM[0], C_DIM[1], C_DIM[2], 1.0)
        ac.setPosition(label_gear_caption, gear_cx * _scale, CAPTION_Y * _scale)

        if _show_speed:
            label_speed = ac.addLabel(app_window, "0")
            ac.setFontAlignment(label_speed, "center")
            ac.setFontSize(label_speed, SPEED_SIZE * _scale)
            ac.setFontColor(label_speed, C_TEXT[0], C_TEXT[1], C_TEXT[2], 1.0)
            ac.setPosition(label_speed, SPEED_CX * _scale, SPEED_Y * _scale)

            label_speed_caption = ac.addLabel(
                app_window, "MPH" if _units_mph else "KM/H")
            ac.setFontAlignment(label_speed_caption, "center")
            ac.setFontSize(label_speed_caption, CAPTION_SIZE * _scale)
            ac.setFontColor(label_speed_caption,
                            C_DIM[0], C_DIM[1], C_DIM[2], 1.0)
            ac.setPosition(label_speed_caption,
                           SPEED_CX * _scale, CAPTION_Y * _scale)

        ac.log("GearSpeedo: loaded (AC API {})".format(ac_version))
    except Exception:
        # Without this the app just silently never appears in the sidebar.
        ac.log("GearSpeedo: acMain failed\n" + traceback.format_exc())

    return "GearSpeedo"


def acUpdate(delta_t):
    global _rpm_fraction, _shift, _blink_on, _blink_clock, _housekeeping
    global _current_car, _last_gear_text, _last_speed_text, _gear_is_red
    global _update_failed

    try:
        # Once a second, notice a car swap and relearn that car's rev limit.
        _housekeeping += delta_t
        if _housekeeping >= 1.0:
            _housekeeping = 0.0
            car = ac.getCarName(0)
            if isinstance(car, str) and car != _current_car:
                _current_car = car
                _reset_redline()

        gear_text = format_gear(ac.getCarState(0, acsys.CS.Gear))

        rpm = ac.getCarState(0, acsys.CS.RPM)
        if rpm < 0:
            rpm = 0.0
        limiter_on = ac.getCarState(0, acsys.CS.IsEngineLimiterOn)
        _learn_redline(rpm, limiter_on)

        _rpm_fraction = min(max(rpm / _redline, 0.0), 1.0) if _redline > 0 else 0.0
        _shift = bool(limiter_on) or _rpm_fraction >= _shift_at

        _blink_clock += delta_t
        if _blink_clock >= BLINK_PERIOD:
            _blink_clock -= BLINK_PERIOD
        _blink_on = _blink_clock < (BLINK_PERIOD * 0.5)

        if gear_text != _last_gear_text:
            _last_gear_text = gear_text
            ac.setText(label_gear, gear_text)

        # Recolour only on the transition, not every frame.
        if _shift != _gear_is_red:
            _gear_is_red = _shift
            colour = C_RED if _shift else C_TEXT
            ac.setFontColor(label_gear, colour[0], colour[1], colour[2], 1.0)

        if _show_speed:
            speed = ac.getCarState(
                0, acsys.CS.SpeedMPH if _units_mph else acsys.CS.SpeedKMH)
            speed_text = str(int(speed if speed > 0 else 0))
            if speed_text != _last_speed_text:
                _last_speed_text = speed_text
                ac.setText(label_speed, speed_text)
    except Exception:
        # acUpdate runs every tick; log once rather than filling py_log.txt.
        if not _update_failed:
            _update_failed = True
            ac.log("GearSpeedo: acUpdate failed\n" + traceback.format_exc())


def acShutdown():
    pass
