#!/bin/sh
# Every command the UI can send, answered by a real engine against the real
# cache. Run it after ANY edit to the serve layer.
#
# This exists because a refactor deleted two command implementations while
# leaving their entries in Util.SERVE pointing at nil. Nothing complained: the
# file still loaded, every other view still worked, and the damage only surfaced
# as "unknown command: playback" in a screenshot taken for another reason. A
# loadfile check cannot catch that -- only calling every command can.
set -e
cd "$(dirname "$0")"
lua -e "assert(loadfile('spoot.lua'))" || { echo "FAIL: spoot.lua does not load"; exit 1; }

# Shuffle is toggled twice so the account is left exactly as it was found.
printf '%s\n' \
  '{"id":1,"cmd":"ping"}' \
  '{"id":2,"cmd":"playback"}' \
  '{"id":3,"cmd":"control","args":{"action":"shuffle"}}' \
  '{"id":4,"cmd":"control","args":{"action":"shuffle"}}' \
  '{"id":5,"cmd":"main"}' \
  '{"id":6,"cmd":"views"}' \
  '{"id":7,"cmd":"view","args":{"name":"liked"}}' \
  '{"id":8,"cmd":"view","args":{"name":"saved-albums"}}' \
  '{"id":9,"cmd":"view","args":{"name":"saved-albums","path":[1]}}' \
  '{"id":10,"cmd":"view","args":{"name":"saved-albums","path":[{"i":1,"alt":true}]}}' \
  '{"id":11,"cmd":"view","args":{"name":"search","path":["aurora"]}}' \
  '{"id":12,"cmd":"open","args":{"tile":"library"}}' \
  '{"id":13,"cmd":"open","args":{"tile":"library","path":[1]}}' \
| timeout 300 lua spoot.lua --serve 2>&1 | python3 -c '
import json, sys
seen, bad = set(), []
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("ev"): continue
    i = d.get("id")
    seen.add(i)
    if not d.get("ok"):
        bad.append((i, str(d.get("err"))[:80])); continue
    rows = (d.get("data") or {}).get("rows")
    # A command that answers ok with nothing is usually a command that broke
    # quietly, so empty results are reported rather than passed over.
    if rows is not None and len(rows) == 0:
        bad.append((i, "answered ok but returned no rows"))
missing = [i for i in range(1, 14) if i not in seen]
for i, why in bad: print(f"  FAIL id={i}: {why}")
for i in missing: print(f"  FAIL id={i}: no response")
print("SMOKE OK" if not bad and not missing else "SMOKE FAILED")
sys.exit(0 if not bad and not missing else 1)
'
