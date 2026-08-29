#!/bin/sh

# ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
# ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
# └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
# spoot Spotify Client ~ Part of the ZENWORKS Suite
# https://github.com/kbuckleys/
# Launches the real app, drives it through a few views, and FAILS on any QML
# error. Run it after every UI edit.
#
# This exists because twice now an edit deleted working QML -- once the view
# Components and the playback clock -- and the app still started, still drew its
# header, and still reported no errors, because Qt swallows qml logging unless
# QT_FORCE_STDERR_LOGGING is set. The window looked merely "empty". Only forcing
# the log and reading it catches that class of damage.
set -e
cd "$(dirname "$0")/.."
LOG=$(mktemp)
pkill -x spoot 2>/dev/null || true
sleep 1

# NO FIRST-RUN FLOW HERE. On a machine with no token spoot now hides itself and
# waits for a browser login, which this script has no way to complete -- it would
# sit out the timeout and then report a single draw. The flow is exercised by
# hand; what this checks is the QML.
QT_FORCE_STDERR_LOGGING=1 SPOOT_NO_AUTOSETUP=1 "${SPOOT_BIN:-./bin/spoot}" > "$LOG" 2>&1 &
APP=$!
sleep 5

# Exercise a grid, a list, an action menu and the trail menu -- between them they
# instantiate every delegate and both view Components.
#
# NOT Escape to leave a menu. Escape hides the window, and it had been doing so
# here since dismiss() stopped meaning "go back": every key after it went to
# whatever had focus instead, so the last third of this drive had quietly been
# testing nothing. Backspace is the key that goes back one level.
if command -v wtype >/dev/null 2>&1; then
    wtype -M alt -k l -m alt; sleep 2             # a list
    wtype -M shift -k Return -m shift; sleep 2    # an action menu
    wtype -k BackSpace; sleep 2                   # back to the list
    wtype -M alt -k space -m alt; sleep 2         # the grid
    wtype -k Return; sleep 2                      # a tile, from the grid
    wtype -k Tab; sleep 2                         # the trail menu
    wtype -k BackSpace; sleep 2
fi

kill "$APP" 2>/dev/null || true
sleep 1

# ReferenceError and TypeError are the shapes a deleted id or function takes;
# "failed to load component" is the shape an unbalanced brace takes, and this
# check passed clean through one of those -- the app never started at all and
# nothing in the log matched, because a file that does not parse cannot go on to
# throw a TypeError.
if grep -nE "ReferenceError|TypeError|is not a function|is not defined|Cannot assign|Unable to assign|failed to load component|Expected token|Syntax error|is not a type|unavailable" "$LOG"; then
    echo "QML CHECK FAILED"
    rm -f "$LOG"
    exit 1
fi
# ...and the positive half, which is what actually proves it ran: main.qml logs
# one of these per draw. No draws means no window, however quiet the log was.
if ! grep -q "render:" "$LOG"; then
    echo "QML CHECK FAILED -- the app never drew anything"
    rm -f "$LOG"
    exit 1
fi

# EVERY DRAW HAD SOMETHING IN IT. A menu that comes up blank is not an error and
# it is not a missing draw -- it is a perfectly successful render of nothing, so
# both checks above sail straight past it. That is exactly how a blank Main could
# be shipped and only noticed by looking at it.
#
# Row counts, not row text: what the shelves contain changes as you listen, and a
# check that cried wolf over a new release would be ignored within a day. Zero is
# the only count that means something is broken.
EMPTY=$(grep -o "render: rows=[0-9]*" "$LOG" | grep -c "rows=0" || true)
if [ "$EMPTY" -gt 0 ]; then
    echo "QML CHECK FAILED -- $EMPTY draw(s) came up empty:"
    grep -n "render: rows=0 " "$LOG"
    rm -f "$LOG"
    exit 1
fi
echo "QML CHECK OK ($(grep -c "render:" "$LOG") draws, none empty)"
rm -f "$LOG"
