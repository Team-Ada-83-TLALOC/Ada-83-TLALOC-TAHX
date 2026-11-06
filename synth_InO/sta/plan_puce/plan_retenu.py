#!/usr/bin/env python3
"""Plan retenu (plan initial P67, stack_unit aux broches de Vincent, P69)."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from plans import *
R = {"ino_fetch": (0, 0, "N"), "ino_decode_predict": (1960, 0, "N"), "ino_decode_queue": (2920, 0, "N"),
     "stack_unit_16_8": (3380, 0, "N"), "ino_exec_arith": (1960, 1160, "N"), "ino_exec_entier": (3270, 1560, "N"),
     "ino_system": (4320, 1560, "N"), "ino_data_cache": (1895, 2620, "N")}
c = dict(P67); c["stack_unit_16_8"] = open(os.path.join(D, "cfg", "v69_stack_unit_16_8.cfg")).read()
run("plan retenu", R, c, (870, 2970), (4870, 3150))
