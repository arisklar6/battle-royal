version     = "0.1.1"
author      = "arisk"
description = "Zero Sum - a battle-royale Coworld: 16 contestants, one Fortress, a shrinking zone, and sponsor airdrops."
license     = "MIT"

srcDir = "src"

# Engine + deps are pinned via nimby.lock (upstream's own workflow: `nimby sync
# nimby.lock` checks out bitworld at the exact commit recorded there and in
# NOTICE). Plain `nimble install` of bitworld is broken upstream (installDirs
# resolves against srcDir and installs an empty package) — do not use it.
requires "nim >= 2.2.4"
