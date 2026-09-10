#!/usr/bin/env python3
"""Draw what a Content Manager theme will look like, from the theme file itself.

Content Manager is a WPF app, so it only renders on Windows. This reads the
same .xaml Content Manager reads, resolves every key the way Content Manager
does (theme first, its own defaults behind), and paints a mock of the window
with those exact colours: the menu, an online server list with a selected row,
the details pane and its GO button, and the usual controls.

It is a mock, not a screenshot: the layout is approximate, the colours are not.

Run: python3 verify/preview-cm-theme.py "content-manager/Themes/No Hesi.xaml" out.html
"""

import json
import os
import re
import sys
import xml.etree.ElementTree as ET

P = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
X = 'http://schemas.microsoft.com/winfx/2006/xaml'
HERE = os.path.dirname(os.path.abspath(__file__))
KEYS = json.load(open(os.path.join(HERE, 'cm-theme-keys.json')))
RES_RE = re.compile(r'^\{\s*(?:Dynamic|Static)Resource\s+([A-Za-z0-9_]+)\s*\}$')

NAMED = {'transparent': '#00000000', 'black': '#000000', 'white': '#FFFFFF', 'lime': '#00FF00',
         'greenyellow': '#ADFF2F', 'darkorange': '#FF8C00', 'gray': '#808080', 'red': '#FF0000',
         'yellow': '#FFFF00', 'silver': '#C0C0C0', 'brown': '#A52A2A'}


def load(path):
    """Every themeable key, theme value winning over Content Manager's default."""
    values = {k: v.get('default') for k, v in KEYS.items()}
    opacity = {}
    root = ET.parse(path).getroot()
    for el in root:
        key = el.get(f'{{{X}}}Key')
        if not key:
            continue
        tag = el.tag.split('}')[-1]
        if tag == 'Color':
            values[key] = (el.text or '').strip()
        elif el.get('Color') is not None:
            values[key] = el.get('Color')
            if el.get('Opacity'):
                opacity[key] = float(el.get('Opacity'))
    return values, opacity


def css(values, key, opacity=None, fallback='#FF00FF'):
    """Resolve a key to a CSS colour, following resource references."""
    seen = set()
    v = values.get(key)
    while v is not None:
        m = RES_RE.match(str(v).strip())
        if not m:
            break
        if m.group(1) in seen:
            return fallback
        seen.add(m.group(1))
        v = values.get(m.group(1))
    if v is None:
        return fallback
    v = str(v).strip()
    if not v.startswith('#'):
        v = NAMED.get(v.lower(), fallback)
    h = v[1:]
    if len(h) == 3:
        h = ''.join(c * 2 for c in h)
    if len(h) == 8:                      # WPF is #AARRGGBB, CSS is #RRGGBBAA
        h = h[2:] + h[:2]
    out = '#' + h
    if opacity and key in opacity:
        a = format(round(opacity[key] * 255), '02x')
        out = '#' + h[:6] + a
    return out


SERVERS = [
    ('No Hesi &mdash; Highway Rush', 'Shutoko Revival Project', '28/32', '18 ms', False),
    ('No Hesi &mdash; C1 Night Loop', 'Shutoko Revival Project', '31/32', '24 ms', True),
    ('No Hesi &mdash; Traffic Only', 'Los Angeles Canyons', '12/24', '41 ms', False),
    ('No Hesi &mdash; Wangan Express', 'Shutoko Revival Project', '30/30', '33 ms', False),
    ('No Hesi &mdash; Rookie Lane', 'Highlands Long', '7/24', '52 ms', False),
]


def render(values, opacity, source):
    c = lambda k, fb='#FF00FF': css(values, k, opacity, fb)
    rows = []
    for name, track, players, ping, sel in SERVERS:
        bg = f'background:{c("ItemBackgroundSelected")};' if sel else ''
        fg = c('ItemTextSelected') if sel else c('ItemText')
        dim = c('ItemTextSelected') if sel else c('WindowTextReadOnly')
        rows.append(f'''
      <tr class="{'sel' if sel else ''}" style="{bg}">
        <td style="color:{fg}">{name}</td>
        <td style="color:{dim}">{track}</td>
        <td style="color:{fg}">{players}</td>
        <td style="color:{dim}">{ping}</td>
      </tr>''')

    return f'''<!doctype html>
<meta charset="utf-8">
<title>{os.path.basename(source)} &mdash; Content Manager preview</title>
<style>
  body {{ margin:0; padding:28px; background:#0a0a0b; font:13px "Segoe UI",system-ui,sans-serif; }}
  .win {{ width:1100px; margin:0 auto; background:{c('WindowBackground')};
          border:1px solid {c('WindowBorderActive')}; box-shadow:0 24px 70px rgba(0,0,0,.7); }}
  .title {{ display:flex; align-items:center; gap:14px; padding:14px 18px 0; }}
  .title h1 {{ margin:0; font-size:26px; font-weight:300; color:{c('WindowText')}; letter-spacing:.02em; }}
  .title .wbtn {{ margin-left:auto; color:{c('WindowTextReadOnly')}; font-size:15px; letter-spacing:6px; }}
  .menu {{ display:flex; gap:22px; padding:10px 18px 0; font-size:15px; }}
  .menu span {{ color:{c('MenuText')}; }}
  .menu .hover {{ color:{c('MenuTextHover')}; }}
  .menu .sel {{ color:{c('MenuTextSelected')}; }}
  .submenu {{ display:flex; gap:18px; padding:8px 18px 12px; font-size:11px; text-transform:uppercase;
              letter-spacing:.08em; border-bottom:1px solid {c('SeparatorBackground')}; }}
  .submenu span {{ color:{c('SubMenuText')}; }}
  .submenu .sel {{ color:{c('SubMenuTextSelected')}; }}
  .body {{ display:flex; gap:0; }}
  .list {{ flex:1; min-width:0; padding:14px 0 18px 18px; }}
  .bar {{ display:flex; gap:8px; align-items:center; margin-bottom:12px; padding-right:18px; }}
  input.search {{ flex:1; background:{c('InputBackground')}; border:1px solid {c('InputBorder')};
      color:{c('InputText')}; padding:6px 9px; font:13px inherit; }}
  input.search::placeholder {{ color:{c('InputTextPlaceholder')}; }}
  button {{ background:{c('ButtonBackground')}; border:1px solid {c('ButtonBorder')};
      color:{c('ButtonText')}; padding:6px 14px; font:13px inherit; }}
  button.hover {{ background:{c('ButtonBackgroundHover')}; border-color:{c('ButtonBorderHover')};
      color:{c('ButtonTextHover')}; }}
  button.pressed {{ background:{c('ButtonBackgroundPressed')}; border-color:{c('ButtonBorderPressed')};
      color:{c('ButtonTextPressed')}; }}
  table {{ width:100%; border-collapse:collapse; }}
  th {{ text-align:left; font-weight:600; font-size:11px; text-transform:uppercase; letter-spacing:.08em;
        color:{c('DataGridHeaderForeground')}; padding:6px 10px; border-bottom:1px solid {c('DataGridGridLines')}; }}
  td {{ padding:9px 10px; border-bottom:1px solid {c('DataGridGridLines')}; }}
  tr.hover td {{ background:{c('DataGridCellBackgroundHover')}; }}
  .side {{ width:320px; padding:14px 18px 18px; border-left:1px solid {c('SeparatorBackground')}; }}
  .card {{ background:{c('CardBackground')}; border:1px solid {c('CardBorder')}; padding:0 0 12px; }}
  .card h2 {{ margin:0; padding:10px 12px; font-size:13px; font-weight:600;
      background:{c('CardHeaderBackground')}; color:{c('CardHeaderText')}; }}
  .card dl {{ margin:0; padding:10px 12px 0; display:grid; grid-template-columns:auto 1fr; gap:5px 12px; }}
  .card dt {{ color:{c('WindowTextReadOnly')}; }}
  .card dd {{ margin:0; color:{c('WindowText')}; }}
  .go {{ display:block; width:100%; margin-top:14px; padding:11px 0; font-size:15px; letter-spacing:.1em;
      background:{c('GoButtonBackground')}; border:1px solid {c('GoButtonBorder')}; color:{c('GoButtonText')}; }}
  .go.pressed {{ background:{c('GoButtonBackgroundPressed')}; color:{c('GoButtonTextPressed')}; }}
  .ctl {{ margin-top:16px; display:grid; gap:10px; }}
  .row {{ display:flex; align-items:center; gap:9px; color:{c('WindowText')}; }}
  .box {{ width:13px; height:13px; border:1px solid {c('CheckBoxBorder', c('ModernButtonBorder'))};
      background:{c('CheckBoxBackground', c('InputBackground'))}; }}
  .box.on {{ background:{c('ItemBackgroundSelected')}; border-color:{c('ItemBackgroundSelected')}; }}
  .track {{ flex:1; height:3px; background:{c('SliderTrackBackground')}; position:relative; }}
  .track i {{ position:absolute; left:0; top:0; bottom:0; width:58%; background:{c('SliderSelectionBackground')}; }}
  .track b {{ position:absolute; left:58%; top:-4px; width:8px; height:11px;
      background:{c('SliderThumbBackground')}; border:1px solid {c('SliderThumbBorder')}; }}
  .sb {{ width:9px; background:{c('ScrollBarBackground')}; position:relative; }}
  .sb i {{ position:absolute; left:1px; right:1px; top:16%; height:34%; background:{c('ScrollBarThumb')}; }}
  .status {{ display:flex; gap:16px; padding:9px 18px; border-top:1px solid {c('SeparatorBackground')};
      font-size:12px; color:{c('WindowTextReadOnly')}; }}
  .err {{ color:{c('ErrorColor')}; }}
  .link {{ color:{c('Hyperlink')}; }}
  .legend {{ width:1100px; margin:22px auto 0; color:#8b919b; font-size:12px; line-height:1.7; }}
  .legend b {{ color:#e8eaee; font-weight:600; }}
  .sw {{ display:inline-block; width:11px; height:11px; vertical-align:-1px; margin-right:5px;
      border:1px solid rgba(255,255,255,.2); }}
</style>
<div class="win">
  <div class="title"><h1>Content Manager</h1><span class="wbtn">&minus; &square; &times;</span></div>
  <div class="menu"><span class="sel">drive</span><span class="hover">content</span><span>settings</span><span>about</span></div>
  <div class="submenu"><span class="sel">online</span><span>quick drive</span><span>race</span><span>replays</span></div>
  <div class="body">
    <div class="list">
      <div class="bar">
        <input class="search" placeholder="Filter servers&hellip;" value="no hesi">
        <button class="hover">Refresh</button><button class="pressed">Sort</button>
      </div>
      <table>
        <tr><th>Server</th><th>Track</th><th>Players</th><th>Ping</th></tr>
        {''.join(rows)}
        <tr class="hover"><td style="color:{c('ItemText')}">No Hesi &mdash; Practice</td>
          <td style="color:{c('WindowTextReadOnly')}">Shutoko Revival Project</td>
          <td style="color:{c('ItemText')}">4/24</td><td style="color:{c('WindowTextReadOnly')}">67 ms</td></tr>
      </table>
    </div>
    <div class="sb"><i></i></div>
    <div class="side">
      <div class="card">
        <h2>No Hesi &mdash; C1 Night Loop</h2>
        <dl>
          <dt>Track</dt><dd>Shutoko Revival Project</dd>
          <dt>Cars</dt><dd>17 available</dd>
          <dt>Session</dt><dd>Practice, 04:12 left</dd>
          <dt>Password</dt><dd class="err">required</dd>
          <dt>Website</dt><dd class="link">nohesi.example</dd>
        </dl>
      </div>
      <button class="go">GO</button>
      <div class="ctl">
        <div class="row"><span class="box on"></span> Auto-join when a slot opens</div>
        <div class="row"><span class="box"></span> Hide full servers</div>
        <div class="row">Traffic density <span class="track"><i></i><b></b></span></div>
      </div>
    </div>
  </div>
  <div class="status"><span>1,284 servers</span><span>Updated 3 s ago</span><span class="err">2 failed to load</span></div>
</div>
<div class="legend">
  <b>{os.path.basename(source)}</b> &mdash; every colour above is read out of the theme file, resolved the way
  Content Manager resolves it. Layout is a mock; Content Manager is WPF and only renders on Windows.<br>
  <span class="sw" style="background:{c('WindowBackground')}"></span>window
  <span class="sw" style="background:{c('ItemBackgroundSelected')}"></span>selection
  <span class="sw" style="background:{c('GoButtonText')}"></span>go
  <span class="sw" style="background:{c('ErrorColor')}"></span>error
  <span class="sw" style="background:{c('WindowText')}"></span>text
  <span class="sw" style="background:{c('InputBackground')}"></span>input
</div>
'''


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        print(__doc__)
        sys.exit(2)
    src = sys.argv[1]
    values, opacity = load(src)
    html = render(values, opacity, src)
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(src)[0] + '.preview.html'
    with open(out, 'w') as f:
        f.write(html)
    print(f'wrote {out}')
