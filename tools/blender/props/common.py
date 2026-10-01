"""
props/common.py - colours shared by several props. READ-ONLY for prop builders: define any new
colour inside your own module with a name prefixed by the prop (e.g. hexcol("bed_post", ...)) -
the palette is keyed by name and the FIRST registration of a name wins, so two modules using the
same name with different values would silently share one colour.
"""
import sockkit as K
from sockkit import hexcol

WOOD = hexcol("wood", "#B77A45")
WOOD_D = hexcol("wood_dark", "#8C5A30")
WOOD_L = hexcol("wood_light", "#D49A5E")
CREAM = hexcol("cream", "#F3E6CC")
BLUE = hexcol("blanket_blue", "#5C7FD1")
RED = hexcol("stripe_red", "#D94F4F")
YELLOW = hexcol("block_yellow", "#F2C14E")
BLOCK_BLUE = hexcol("block_blue", "#4F7FD6")
WHITE = K.WHITE
DRYER_W = hexcol("dryer_white", "#EEF1F6")
DRYER_B = hexcol("dryer_blue", "#6DA5E3")
DRYER_BD = hexcol("dryer_blue_dark", "#3E6FB8")
PORTAL_D = hexcol("portal_dark", "#2B1B5A")
PORTAL_P = hexcol("portal_purple", "#7A3FE0")
PORTAL_L = hexcol("portal_light", "#C9A8FF")
DUCK_Y = hexcol("duck", "#FFD23F")
DUCK_YD = hexcol("duck_dark", "#F2B030")
BEAK = hexcol("beak", "#FF8A2B")
FUR = hexcol("fur", "#9C6233")
FUR_L = hexcol("fur_light", "#D9A877")
LINT = hexcol("lint_grey", "#B8BAC4")
LINT_D = hexcol("lint_grey_dark", "#9497A3")
WICKER = hexcol("wicker", "#C8A064")
WICKER_D = hexcol("wicker_dark", "#9C7440")
GLOBE = hexcol("globe", "#FFE58A")
BLACK = K.BLACK

