# No Hesi — a Content Manager theme

Night on the highway. Cold asphalt behind everything, lane-paint white text,
taillight red on the row you have selected, sodium amber for anything that
wants attention, and the GO button still green.

![The theme, drawn from the theme file](preview.png)

That picture is generated from `Themes/No Hesi.xaml` itself — every colour in
it is read out of the file and resolved the way Content Manager resolves it.
The layout is a mock: Content Manager is a WPF app and only draws on Windows,
so nothing here can screenshot the real thing.

## Install

**Drag and drop.** Drop `No Hesi.zip` onto Content Manager's window. It
recognises the file as a theme, offers "New CM theme No Hesi", and files it in
the right folder.

**Or copy it by hand** into whichever of these your Content Manager uses:

| Install | Folder |
| --- | --- |
| normal | `%LOCALAPPDATA%\AcTools Content Manager\Themes\` |
| portable (its exe name has "local" in it) | `<folder with the exe>\Data\Themes\` |
| started with `--storage-location=…` | `<that path>\Themes\` |

The file has to sit directly in `Themes`; Content Manager only lists `.xaml`
files at the top level of that folder, never in subfolders.

Then **Settings → Appearance → Theme → No Hesi**. It shows up without a
restart, and Content Manager re-applies the file every time you save an edit
to it, so you can tune colours with the app open.

## Set the accent colour too

On the same settings page, set the colour picker to **`#E01B24`**.

Content Manager keeps the accent as a per-user setting and writes it straight
into the running app, on top of whatever theme is loaded — a theme cannot set
it. Around a hundred places in its UI paint directly from that accent. The
theme uses its own literal red everywhere it can, so lists, buttons and grids
look right either way, but until the accent matches you will see the odd
leftover blue icon or highlight.

## What it changes

158 of Content Manager's 169 themeable colours, so nothing is left sitting at
the stock grey. The parts worth calling out:

- **Selection is red.** The chosen server, car or track gets a taillight-red
  bar with white text. Half-highlights use the same red as diagonal hazard
  stripes, which is an alternative Content Manager ships commented out in its
  own default theme.
- **Errors are amber, not red.** Red is doing selection here, and a warning
  that looks like a highlighted row is a warning nobody reads. Amber is what
  Content Manager uses by default anyway.
- **Links are headlight blue** so they never read as selection.
- **GO stays green.** It is the one control found by muscle memory.
- **The loading glow is red** — taillights in the mirror while a session loads.

| | |
| --- | --- |
| `#0E1013` | asphalt, the window itself |
| `#1A1E25` | inputs and buttons |
| `#232830` | hover |
| `#E4E8EE` | lane paint, body text |
| `#949CA8` | dimmed text |
| `#E01B24` | taillight, selection and accent |
| `#FFB020` | sodium, warnings and ratings |
| `#7FC7FF` | headlight, links |
| `#3DDC6E` | green, GO |

Not affiliated with the No Hesi servers or their operators. It is a palette
that looks like the game those servers run, nothing more.

## Changing it

Every colour in the file comes from one of the `NoHesi…` entries at the top, so
editing those carries through the whole theme. Save the file and Content
Manager re-applies it immediately.

Two checks live next door in `../verify/`:

```bash
python3 ../verify/check-cm-theme.py "Themes/No Hesi.xaml"
python3 ../verify/preview-cm-theme.py "Themes/No Hesi.xaml" preview.html
```

The first reads the file the way Content Manager does and reports what it
would silently ignore: a key Content Manager never looks up (a typo in a key
is not an error, the colour just never appears), a colour WPF cannot parse, a
resource reference that resolves to nothing, and the WCAG contrast of every
text-on-background pair the app actually draws. The second regenerates the
picture above. `../verify/cm-theme-keys.json` is the key inventory both use,
extracted from Content Manager's own default theme dictionary.

If Content Manager cannot parse the file it does not say so loudly: it drops
back to its stock Nordschleife theme and prints the parser's message in red
under the theme dropdown.
