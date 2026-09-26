#!/bin/sh

# ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
# ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
# └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
# spoot Spotify Client ~ Part of the ZENWORKS Suite
# https://github.com/kbuckleys/
# Every view, every layout, recorded — then compared against the last recording.
#
# `--record` writes engine/views.golden. With no argument it re-runs the same
# probes and diffs. Row COUNTS and shapes are compared, never the row text: the
# library changes as you listen, and a harness that cried wolf every time a new
# release landed would be ignored within a day.
#
# This exists because the damage I keep doing is invisible: a deleted function, a
# shifted index, a view that quietly returns nothing. Each one still loaded, still
# drew a header, and still passed a syntax check.
set -e
cd "$(dirname "$0")"
GOLDEN=views.golden
OUT=$(mktemp)

python3 - "$OUT" <<'PY'
import json, os, select, subprocess, sys

PROBES = [
    # name,                    command, args
    ("main",                   "main",  {}),
    ("liked",                  "view",  {"name": "liked"}),
    ("top-tracks",             "view",  {"name": "top-tracks"}),
    ("recently-played",        "view",  {"name": "recently-played"}),
    ("saved-albums",           "view",  {"name": "saved-albums"}),
    ("followed-artists",       "view",  {"name": "followed-artists"}),
    ("playlists",              "view",  {"name": "playlists"}),
    ("categories",             "view",  {"name": "categories"}),
    ("collections",            "view",  {"name": "collections"}),
    ("new-releases",           "view",  {"name": "new-releases"}),
    ("top-artists",            "view",  {"name": "top-artists"}),
    ("discover-genre",         "view",  {"name": "discover-genre"}),
    ("podcasts",               "view",  {"name": "podcasts"}),
    ("library",                "open",  {"tile": "library"}),
    ("system",                 "open",  {"tile": "system"}),
    # The settings menu and one of its pickers. Recorded like any other view --
    # a picker that stops answering, or a menu that loses a row because a
    # setting was renamed in one place and not the other, shows up here.
    ("ui-settings",            "view",  {"name": "ui-settings"}),
    ("ui-settings>opacity",    "view",  {"name": "ui-settings", "path": [2]}),
    ("playback",               "open",  {"tile": "playback"}),
    # Navigation: one level, two levels, and an action menu at each depth. These
    # are the shapes that broke when path steps were addressed by call ordinal.
    ("album",                  "view",  {"name": "saved-albums", "path": [1]}),
    ("album-actions",          "view",  {"name": "saved-albums", "path": [{"i": 1, "alt": True}]}),
    ("album>track-actions",    "view",  {"name": "saved-albums", "path": [1, {"i": 1, "alt": True}]}),
    ("artist-albums",          "view",  {"name": "followed-artists", "path": [1]}),
    ("artist-actions",         "view",  {"name": "followed-artists", "path": [{"i": 1, "alt": True}]}),
    ("library>liked",          "open",  {"tile": "library", "path": [1]}),
    ("track-actions",          "view",  {"name": "liked", "path": [{"i": 1, "alt": True}]}),
    ("trail-jump",             "view",  {"name": "trail-jump"}),
    # THE CONTEXT-MENU ROUTE, which is how every action menu is actually reached
    # now. The three probes above open one as a PATH STEP -- a real hop -- which
    # is the fallback the UI takes only when there is nothing to draw the card
    # over. These send it the way the UI does: as `tail`, walked but never
    # entered on the trail.
    #
    # What is being pinned is the absence. `crumb` must not grow and `scope` must
    # stay the parent's, because an action menu is not a place -- if either
    # starts moving again, a track's verbs are back on the breadcrumb and in
    # nav.json, which is exactly the regression this route exists to prevent.
    ("ctx:track",              "nav",   {"hops": [{"cmd": "view", "key": "liked"}], "pos": 1,
                                         "tail": [{"step": {"i": 1, "alt": True}}]}),
    ("ctx:album",              "nav",   {"hops": [{"cmd": "view", "key": "saved-albums"}], "pos": 1,
                                         "tail": [{"step": {"i": 1, "alt": True}}]}),
    ("ctx:artist",             "nav",   {"hops": [{"cmd": "view", "key": "followed-artists"}], "pos": 1,
                                         "tail": [{"step": {"i": 1, "alt": True}}]}),
    # A tail that is a ROOT hop rather than a step -- the trail menu, which is
    # also not a place. It creates a segment of its own and still must not reach
    # the chain.
    ("ctx:trail",              "nav",   {"hops": [{"cmd": "view", "key": "liked"}], "pos": 1,
                                         "tail": [{"cmd": "view", "key": "trail-jump"}]}),
]

# ANSWERED, BUT NOT DESCRIBED. Ten views the engine serves were probed by
# nothing at all -- a guard covering two thirds of the app and presenting itself
# as covering all of it. These are the rest, recorded by whether they ANSWER
# rather than by what they contain, because what they contain is not a property
# of the code:
#
#   the five current-track views act on whatever is playing, so their rows,
#   their scope and even their layout turn on whether something happens to be
#   playing when this runs;
#
#   the queue and the three podcast shelves are empty on this account today and
#   full on the day a podcast is followed. Both readings are correct, so pinning
#   either into the golden file would have the guard cry wolf over a change to
#   the account rather than to the code.
#
# Whether a view answers still catches what this harness is for: a deleted
# function, a renamed view, an entry in Util.SERVE_VIEWS pointing at nil. Every
# one of those raises rather than returning something uninteresting.
#
# `listen` is deliberately absent. Util.view_listen blocks on songrec for up to
# P.listen_timeout seconds, and a guard nobody will wait thirty seconds for is a
# guard nobody will run.
STATE_PROBES = [
    # Search results belong here rather than above: the view reopens on the
    # SLICE you were last looking at for that query -- tracks, albums, artists --
    # and those are a list, a grid and a grid. So its layout, its row count and
    # whether it has icons all turn on a remembered choice, and pinning any of
    # them describes the last search made rather than the code.
    ("search-results",         "view",  {"name": "search", "path": ["aurora"]}),
    ("your-queue",             "view",  {"name": "your-queue"}),
    ("show-list",              "view",  {"name": "show-list"}),
    ("latest-episodes",        "view",  {"name": "latest-episodes"}),
    ("saved-episodes",         "view",  {"name": "saved-episodes"}),
    # WHERE THE MUSIC CAME FROM, as one step rather than the walk that led there.
    # Recorded by whether it ANSWERS and nothing else: what it points at is the
    # last list you played from, so its layout, its rows and its scope all change
    # as you listen -- pinning any of them describes this afternoon, not the code.
    ("origin",                 "view",  {"name": "origin"}),
    ("lyrics-current",         "view",  {"name": "lyrics-current"}),
    ("art-current",            "view",  {"name": "art-current"}),
    ("seek-current",           "view",  {"name": "seek-current"}),
]

# THE BINARY, not `lua spoot.lua`. The engine ships inside it and reaches the
# network and the player through it, so a guard that ran the script on a
# standalone interpreter was testing a transport nothing uses any more.
p = subprocess.Popen([os.environ.get("SPOOT_BIN", "../bin/spoot"), "--serve"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, text=True, bufsize=1)
p.stdout.readline()
out = []
for i, (label, cmd, args) in enumerate(PROBES, 1):
    p.stdin.write(json.dumps({"id": i, "cmd": cmd, "args": args}) + "\n")
    p.stdin.flush()
    # Art arrives as events AFTER the response -- the engine flushes the rows
    # first on purpose. So the reply is read, and THEN the pipe is drained for
    # whatever art follows. Without the drain each view's art was credited to the
    # next probe, and the golden file quietly described the wrong thing.
    art = 0
    while True:
        d = json.loads(p.stdout.readline())
        if d.get("ev") == "art":
            art += len(d.get("items") or [])
            continue
        if d.get("id") == i:
            break
    while select.select([p.stdout], [], [], 1.5)[0]:
        line = p.stdout.readline()
        if not line:
            break
        ev = json.loads(line)
        if ev.get("ev") == "art":
            art += len(ev.get("items") or [])
    if not d.get("ok"):
        out.append(f"{label:<22} ERROR {str(d.get('err'))[:60]}")
        continue
    dd = d["data"]
    rows = dd.get("rows", [])
    # Buckets, not exact counts: a library grows. A view going EMPTY is the
    # failure worth catching, and that changes the bucket.
    n = len(rows)
    bucket = "0" if n == 0 else "1-9" if n < 10 else "10-99" if n < 100 else "100+"
    icons = "some" if (art or any(r.get("icon") for r in rows)) else "none"
    # `ctx` says whether the menu declared itself a context menu. Recorded for
    # every probe, not just the ctx: ones: a view that starts claiming it would
    # be drawn as a floating card over whatever was on screen, and nothing else
    # here would notice.
    out.append(f"{label:<22} layout={str(dd.get('layout')):<5} rows={bucket:<5} "
               f"icons={icons:<4} scope={str(dd.get('scope')):<16} "
               f"ctx={'yes' if dd.get('context') else 'no ':<3} "
               f"crumb={len(dd.get('crumb') or [])}")

for j, (label, cmd, args) in enumerate(STATE_PROBES, len(PROBES) + 1):
    p.stdin.write(json.dumps({"id": j, "cmd": cmd, "args": args}) + "\n")
    p.stdin.flush()
    while True:
        d = json.loads(p.stdout.readline())
        if d.get("id") == j:
            break
    while select.select([p.stdout], [], [], 1.0)[0]:
        if not p.stdout.readline():
            break
    out.append(f"{label:<22} answers={'yes' if d.get('ok') else 'NO -- ' + str(d.get('err'))[:60]}")
p.kill()
open(sys.argv[1], "w").write("\n".join(out) + "\n")
PY

if [ "$1" = "--record" ]; then
    mv "$OUT" "$GOLDEN"
    echo "recorded $(wc -l < "$GOLDEN") views to $GOLDEN"
    exit 0
fi
if [ ! -f "$GOLDEN" ]; then
    echo "no $GOLDEN yet -- run: $0 --record"
    rm -f "$OUT"; exit 1
fi
if diff -u "$GOLDEN" "$OUT"; then
    echo "VIEWS OK ($(wc -l < "$GOLDEN") views unchanged)"
    rm -f "$OUT"
else
    echo "VIEWS CHANGED -- if intended, re-record with: $0 --record"
    rm -f "$OUT"; exit 1
fi
