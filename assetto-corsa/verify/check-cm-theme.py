#!/usr/bin/env python3
"""Check a Content Manager theme file the way Content Manager will read it.

Content Manager loads a theme with XamlReader.Load and merges it over its own
defaults, so a typo in a resource key is silent: the key is simply never used
and that part of the UI keeps the stock colour. This checks the things that
would otherwise only show up in the running app:

  * the file parses, and its root is a ResourceDictionary in WPF's namespace
    (that is exactly what Content Manager tests before offering to install it)
  * every x:Key is one Content Manager actually looks up
  * every colour is a colour WPF can parse
  * every {DynamicResource} / {StaticResource} target resolves
  * text stays readable: WCAG contrast for the pairs the app really draws
  * coverage: which identity-carrying keys are left at the stock dark values

Run: python3 verify/check-cm-theme.py "content-manager/Themes/No Hesi.xaml"
"""

import json
import os
import re
import sys
import xml.etree.ElementTree as ET

P = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
X = 'http://schemas.microsoft.com/winfx/2006/xaml'
SYS = 'clr-namespace:System;assembly=mscorlib'

HERE = os.path.dirname(os.path.abspath(__file__))
KEYS = json.load(open(os.path.join(HERE, 'cm-theme-keys.json')))

# Element types a theme can sensibly hold. Anything else is unlikely to be
# what the author meant, even if WPF could build it.
ELEMENTS = {'Color', 'SolidColorBrush', 'LinearGradientBrush', 'RadialGradientBrush',
            'ImageBrush', 'VisualBrush', 'DropShadowEffect', 'BlurEffect', 'Null', 'String'}

# System.Windows.Media.Colors: the X11/HTML names WPF accepts, plus Transparent.
NAMED = set("""aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue
blueviolet brown burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan
darkblue darkcyan darkgoldenrod darkgray darkgreen darkkhaki darkmagenta darkolivegreen darkorange
darkorchid darkred darksalmon darkseagreen darkslateblue darkslategray darkturquoise darkviolet
deeppink deepskyblue dimgray dodgerblue firebrick floralwhite forestgreen fuchsia gainsboro ghostwhite
gold goldenrod gray green greenyellow honeydew hotpink indianred indigo ivory khaki lavender
lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan lightgoldenrodyellow lightgray
lightgreen lightpink lightsalmon lightseagreen lightskyblue lightslategray lightsteelblue lightyellow
lime limegreen linen magenta maroon mediumaquamarine mediumblue mediumorchid mediumpurple
mediumseagreen mediumslateblue mediumspringgreen mediumturquoise mediumvioletred midnightblue
mintcream mistyrose moccasin navajowhite navy oldlace olive olivedrab orange orangered orchid
palegoldenrod palegreen paleturquoise palevioletred papayawhip peachpuff peru pink plum powderblue
purple red rosybrown royalblue saddlebrown salmon sandybrown seagreen seashell sienna silver skyblue
slateblue slategray snow springgreen steelblue tan teal thistle tomato transparent turquoise violet
wheat white whitesmoke yellow yellowgreen""".split())

RES_RE = re.compile(r'^\{\s*(Dynamic|Static)Resource\s+([A-Za-z0-9_]+)\s*\}$')


class Check:
    def __init__(self):
        self.fails = 0
        self.warns = 0

    def ok(self, msg, extra=''):
        print(f'  ok   {msg}' + (f' ({extra})' if extra else ''))

    def check(self, msg, cond, extra=''):
        if cond:
            self.ok(msg, extra)
        else:
            print(f'  FAIL {msg}' + (f' ({extra})' if extra else ''))
            self.fails += 1
        return cond

    def warn(self, msg):
        print(f'  note {msg}')
        self.warns += 1


def parse_colour(value, defined, name):
    """Return (r, g, b) or None, plus an error string."""
    if value is None:
        return None, 'missing'
    v = value.strip()
    m = RES_RE.match(v)
    if m:
        target = m.group(2)
        if target not in defined and target not in KEYS:
            return None, f'{v} -> no such resource'
        # Resolve one level so contrast can still be computed.
        src = defined.get(target) or KEYS.get(target, {}).get('default')
        if src is None or RES_RE.match(str(src) or ''):
            return None, None            # a reference we cannot resolve: not an error
        return parse_colour(src, defined, name)
    if v.startswith('#'):
        h = v[1:]
        if len(h) not in (3, 4, 6, 8) or re.search(r'[^0-9a-fA-F]', h):
            return None, f'{v} is not a valid hex colour'
        if len(h) == 3:
            h = ''.join(c * 2 for c in h)
        elif len(h) == 4:
            h = ''.join(c * 2 for c in h[1:])
        elif len(h) == 8:
            h = h[2:]
        return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)), None
    if v.lower() in NAMED:
        return None, None                 # valid, just not worth a table lookup
    return None, f'{v} is not a colour WPF knows'


def brush_colour(el, tag):
    """WPF reads a brush's colour from the Color attribute, a
    <SolidColorBrush.Color> child or the element's own text. Content Manager's
    own default theme uses all three, so all three have to be understood."""
    if tag == 'Color':
        return (el.text or '').strip() or None
    if el.get('Color') is not None:
        return el.get('Color')
    for child in el:
        if child.tag.split('}')[-1].endswith('.Color'):
            return (child.text or '').strip() or None
    text = (el.text or '').strip()
    return text or None


def luminance(rgb):
    def ch(c):
        c /= 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# Text-on-background pairs Content Manager actually draws, with the minimum
# each one needs. Body copy is held to AA (4.5); labels drawn over a coloured
# fill only have to clear AA-large (3.0) because they are short and bold.
PAIRS = [
    ('WindowText', 'WindowBackground', 4.5, 'body text on the window'),
    ('WindowTextReadOnly', 'WindowBackground', 3.0, 'read-only text on the window'),
    ('MenuTextSelected', 'WindowBackground', 4.5, 'selected menu link'),
    ('MenuText', 'WindowBackground', 3.0, 'idle menu link'),
    ('MenuTextHover', 'WindowBackground', 4.5, 'hovered menu link'),
    ('ItemText', 'WindowBackground', 4.5, 'list item'),
    ('ItemTextSelected', 'ItemBackgroundSelected', 4.5, 'selected list item'),
    ('ItemTextHover', 'ItemBackgroundHover', 4.5, 'hovered list item'),
    ('ButtonText', 'ButtonBackground', 4.5, 'button label'),
    ('ButtonTextHover', 'ButtonBackgroundHover', 4.5, 'hovered button label'),
    ('ButtonTextPressed', 'ButtonBackgroundPressed', 4.5, 'pressed button label'),
    ('InputText', 'InputBackground', 4.5, 'text you type'),
    ('DataGridCellForeground', 'DataGridCellBackground', 4.5, 'grid cell'),
    ('DataGridCellForegroundSelected', 'DataGridCellBackgroundSelected', 4.5, 'selected grid cell'),
    ('DataGridHeaderForeground', 'DataGridHeaderBackground', 3.0, 'grid header'),
    ('ModernButtonText', 'WindowBackground', 4.5, 'modern button label'),
    ('LinkButtonText', 'WindowBackground', 3.0, 'link button'),
    ('LinkButtonTextHover', 'WindowBackground', 4.5, 'hovered link button'),
    ('SubMenuTextSelected', 'WindowBackground', 4.5, 'selected sub-menu link'),
    ('Hyperlink', 'WindowBackground', 4.5, 'hyperlink'),
    ('ItemText', 'PopupBackground', 4.5, 'item in a popup'),
    ('WindowText', 'PopupBackground', 4.5, 'text in a popup'),
    ('CardHeaderText', 'CardHeaderBackground', 4.5, 'card header'),
    ('GoButtonText', 'GoButtonBackground', 4.5, 'GO button'),
]

# Content Manager defines these but never looks them up, so setting them does
# nothing visible. Harmless to keep (its own themes set them), not worth testing.
DEAD = {'WindowHeaderGradient', 'InputTextPlaceholder'}

# Without these the theme leaks Content Manager's stock greys into the middle
# of itself, which is what a half-finished theme looks like.
IDENTITY = [
    'WindowBackgroundColor', 'WindowBackground', 'WindowText', 'WindowTextReadOnly',
    'PopupBackground', 'SeparatorBackground', 'MenuText', 'MenuTextHover', 'MenuTextSelected',
    'SubMenuText', 'SubMenuTextHover', 'SubMenuTextSelected', 'ItemBackgroundHover',
    'ItemBackgroundSelected', 'ItemText', 'ItemTextSelected', 'ItemBorder',
    'ButtonBackground', 'ButtonBackgroundHover', 'ButtonBackgroundPressed', 'ButtonBorder',
    'ButtonText', 'ButtonTextPressed', 'InputBackground', 'InputBorder', 'InputText',
    'DataGridCellBackgroundHover', 'DataGridCellBackgroundSelected', 'DataGridGridLines',
    'ScrollBarBackground', 'ScrollBarThumb', 'ScrollBarThumbHover',
    'SliderSelectionBackground', 'SliderThumbBackground', 'SliderTrackBackground',
    'ModernButtonBorder', 'ModernButtonText', 'Hyperlink', 'ProgressBackground', 'FocusBorder',
]


def main(path):
    print(f'Checking {path}\n')
    c = Check()

    with open(path, 'rb') as f:
        raw = f.read()
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as e:
        print(f'  FAIL the file is not valid XML: {e}')
        print('\n1 failure(s)')
        return 1

    print('== the file Content Manager will read ==')
    c.check('root element is a ResourceDictionary in WPF\'s namespace '
            '(Content Manager tests exactly this)', root.tag == f'{{{P}}}ResourceDictionary', root.tag)
    # Content Manager reads a theme out of a dropped archive as a *string* and
    # hands it to XDocument.Parse, which throws on a leading U+FEFF. The theme is
    # then not recognised at all and the drop silently installs nothing. Loading
    # the same file from the Themes folder goes through a stream and is fine.
    c.check('no UTF-8 BOM (a BOM stops Content Manager recognising the file as a '
            'theme when it is installed from a zip)', not raw.startswith(b'\xef\xbb\xbf'))
    if b'\t' in raw:
        c.warn('the file contains tabs; Content Manager does not mind, they just '
               'make the file harder to keep tidy')

    entries, defined, dupes = [], {}, []
    for el in root:
        if el.tag == f'{{{P}}}ResourceDictionary.MergedDictionaries':
            for m in el:
                c.warn(f'merges {m.get("Source")} — that has to resolve inside Content Manager')
            continue
        key = el.get(f'{{{X}}}Key')
        tag = el.tag.split('}')[-1]
        if key is None:
            c.check(f'<{tag}> has an x:Key (a theme entry without one is dead weight)', False, tag)
            continue
        if key in defined:
            dupes.append(key)
        entries.append((key, tag, el))
        defined[key] = brush_colour(el, tag)

    c.check('no duplicate keys', not dupes, ', '.join(dupes))
    print(f'  {len(entries)} entries')

    print('\n== keys Content Manager looks up ==')
    # A key Content Manager never reads is either a typo or a palette entry the
    # theme defines for its own use. Referenced-by-another-entry tells them apart.
    used = set()
    for _, _, el in entries:
        for node in el.iter():
            for v in list(node.attrib.values()) + [(node.text or '')]:
                m = RES_RE.match(str(v).strip())
                if m:
                    used.add(m.group(2))
    local = [k for k, t, _ in entries if k not in KEYS and t != 'String' and k in used]
    unknown = [k for k, t, _ in entries if k not in KEYS and t != 'String' and k not in used]
    c.check('every key is one Content Manager reads, or one this file uses itself '
            '(a typo would be ignored in silence)', not unknown, ', '.join(unknown))
    if local:
        print(f'  {len(local)} own palette entries: {", ".join(local[:6])}'
              + (' ...' if len(local) > 6 else ''))
    bad_type = [f'{k} is <{t}>, Content Manager wants <{KEYS[k]["type"]}>'
                for k, t, _ in entries
                if k in KEYS and t != KEYS[k]['type'] and not (t == 'Null' or KEYS[k]['type'] == 'Null')
                and not (t.endswith('Brush') and KEYS[k]['type'].endswith('Brush'))]
    c.check('every key holds the type it is read as', not bad_type, '; '.join(bad_type))
    odd = [f'{k}:<{t}>' for k, t, _ in entries if t not in ELEMENTS]
    c.check('no unexpected element types', not odd, ', '.join(odd))

    # WPF resolves StaticResource while parsing, so a reference to a key defined
    # further down the file throws and Content Manager falls back to its own
    # theme with only a line of red text to say why.
    order, late = {k: i for i, (k, _, _) in enumerate(entries)}, []
    for i, (key, _, el) in enumerate(entries):
        for node in el.iter():
            for v in list(node.attrib.values()) + [(node.text or '')]:
                m = RES_RE.match(str(v).strip())
                if m and m.group(1) == 'Static' and order.get(m.group(2), -1) >= i:
                    late.append(f'{key} -> {m.group(2)}')
    c.check('every {StaticResource} points at a key defined further up the file '
            '(WPF resolves those while parsing)', not late, '; '.join(late))

    version = [el for k, t, el in entries if k == 'Version']
    if c.check('has a Version string, so Content Manager can offer updates', bool(version)):
        v = version[0]
        c.check('Version is a System.String (clr-namespace:System;assembly=mscorlib)',
                v.tag == f'{{{SYS}}}String', v.tag.split('}')[0].strip('{'))
        c.check('Version looks like a version number',
                bool(re.match(r'^\d+(\.\d+)*$', (v.text or '').strip())), (v.text or '').strip())

    print('\n== colours ==')
    problems = []
    for k, t, el in entries:
        if t == 'String':
            continue
        vals = []
        own = brush_colour(el, t)
        if own is not None:
            vals.append(own)
        for stop in el.iter():
            if stop.tag.split('}')[-1] == 'GradientStop' and stop.get('Color'):
                vals.append(stop.get('Color'))
        if t == 'SolidColorBrush' and not vals:
            problems.append(f'{k} has no colour')
        for v in vals:
            _, err = parse_colour(v, defined, k)
            if err:
                problems.append(f'{k}: {err}')
    c.check('every colour is one WPF can parse, and every resource reference resolves',
            not problems, '; '.join(problems))

    accent = [k for k, t, el in entries
              if (el.get('Color') or '').strip() in ('{DynamicResource AccentColor}', '{StaticResource AccentColor}')]
    if accent:
        c.warn(f'{len(accent)} brushes follow AccentColor, which is a per-user setting in '
               f'Settings -> Appearance and overrides whatever the theme sets: {", ".join(accent[:6])}'
               + (' ...' if len(accent) > 6 else ''))

    print('\n== readable text ==')
    # Several backgrounds are Transparent by default, which means "whatever is
    # behind me" — in Content Manager that is the window.
    resolved, via_accent = {}, set()
    for k in set([p[0] for p in PAIRS] + [p[1] for p in PAIRS]):
        src = defined.get(k, KEYS.get(k, {}).get('default'))
        if str(src or '').strip().lower() in ('transparent', '#00000000'):
            src = defined.get('WindowBackground', KEYS.get('WindowBackground', {}).get('default'))
        if RES_RE.match(str(src or '')) and RES_RE.match(str(src)).group(2) in ('AccentColor', 'AccentOverlayColor'):
            via_accent.add(k)
        rgb, _ = parse_colour(src, defined, k)
        if rgb:
            resolved[k] = rgb
    own_accent = 'AccentColor' in defined

    worst, deferred = None, []
    for fg, bg, need, what in PAIRS:
        if fg not in resolved or bg not in resolved:
            continue
        ratio = contrast(resolved[fg], resolved[bg])
        # A pair that runs through AccentColor is only as readable as the accent
        # the player picked in Settings -> Appearance, which overrides the theme.
        if (fg in via_accent or bg in via_accent) and not own_accent:
            deferred.append((what, ratio, fg, bg))
            continue
        if worst is None or ratio < worst[0]:
            worst = (ratio, what)
        c.check(f'{what}: {ratio:.1f}:1 (needs {need}:1)', ratio >= need,
                f'{fg} on {bg}' if ratio < need else '')
    if worst:
        print(f'  worst pair: {worst[1]} at {worst[0]:.1f}:1')
    if deferred:
        print('  these follow AccentColor, so they are only as readable as the accent the '
              'player picks in Settings -> Appearance:')
        for what, ratio, fg, bg in deferred:
            print(f'    {what}: {ratio:.1f}:1 against the stock accent')
    elif own_accent and via_accent:
        print(f'  pairs above that run through AccentColor were measured against this theme\'s '
              f'own accent ({defined["AccentColor"]}); the player has to set the same accent in '
              f'Settings -> Appearance for that to hold')

    print('\n== coverage ==')
    missing = [k for k in IDENTITY if k not in defined]
    c.check(f'sets the {len(IDENTITY)} keys that carry the theme\'s identity',
            not missing, 'left at stock: ' + ', '.join(missing) if missing else '')
    set_keys = [k for k in defined if k in KEYS]
    print(f'  {len(set_keys)} of Content Manager\'s {len(KEYS)} themeable keys set; '
          f'the rest fall back to its own dark values')

    print(f'\n{c.fails} failure(s), {c.warns} note(s)')
    return 1 if c.fails else 0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
