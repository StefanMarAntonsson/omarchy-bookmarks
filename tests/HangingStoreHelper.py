#!/usr/bin/env python3

import json
import sys
import time


if len(sys.argv) > 1 and sys.argv[1] == "store-load":
    time.sleep(30)

print(json.dumps({"ok": True}, separators=(",", ":")))
