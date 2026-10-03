"""
sockfeat_e.py - signature features for Spaghettino, Sockula, Merlino, Sockstrong, Dragonzola, Toetankhamun, Sockfather (the second wave).

Each feature builder takes the SockCtx `c` built by socks.py and returns a list of sockkit Pieces
added on top of the shared body (same rules as sockfeat_a/b/c.py). This module also keeps its types'
rigging (RIG: type id -> fn(R), the same per-type functions rigging.py has for the first wave),
optional colour retunes (SPEC_OVERRIDES) and texture hints (MATERIALS: colour-name pattern -> class,
see texturing.classify).
"""

FEATURES = {}
RIG = {}
SPEC_OVERRIDES = {}
MATERIALS = {}
