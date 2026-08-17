// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// The shell: one persistent surface, a message bar, and whatever view is
// current. There is no menu stack of windows here -- the engine owns the session
// stack, so this asks what to draw rather than remembering it.
import QtQuick
import QtQuick.Window
import QtQuick.Shapes
import "views"
import "components"

Window {
    id: root
    // A structured sheet sizes the window to ITSELF; every other view takes the
    // width its theme declares. Clamped to the screen so a pathological value
    // cannot push the panel off it.
    // The image viewer widens the surface to whatever the picture needs, because
    // the picture is a fixed size and the window is not: art.rasi says the window
    // is 1000 and the icon is 1000, which cannot both be true once the frame
    // around it is drawn. The frame is what gives, and the window grows by it.
    // THE SURFACE IS THE WHOLE OUTPUT; `panel` below is the menu. The host
    // anchors all four edges, so the compositor hands us the output's size and
    // these two only have to agree with it. Everything the panel is sized by
    // lives on `panel` itself now -- see its width and height.
    width: Screen.width
    height: Screen.height
    // Computed HERE, from the model, rather than chained through
    // Loader.item.implicitHeight -- that indirection is null while the loader is
    // still building and the window collapsed to a 1px sliver because of it.
    // ZENON's `fixed-height: false` means the panel is as tall as its rows need
    // and no taller, with main.rasi's `lines: 3` acting as a ceiling.
    // Rows wrap into `columns`, so the height is the number of ROWS needed,
    // capped at the theme's `lines` -- which is how rofi reads those two numbers
    // together rather than as a flat maximum.
    // Every kind of overlay, or the panel sizes itself for the view underneath.
    // A structured sheet was missing from this test, so it was laid out as if it
    // were the list behind it -- twenty rows in a ten-row window.
    readonly property bool overlayUp: root.sheet.length > 0
                                   || root.sheetRows.length > 0
                                   || root.artPath.length > 0
    readonly property int bodyHeight: {
        // An overlay sizes ITSELF. It borrowed the layout of the view underneath
        // before this, so a details sheet opened over an album grid was 13 rows
        // tall at GRID cell height -- 2,470px of panel running off the screen.
        // A SHEET REPLACES THE BODY and sizes itself. A structured one is exactly
        // as tall as its rows plus its margins -- no fixed line count, so nothing
        // is ever cut off, and the screen is the only cap.
        if (root.sheetRows.length)
            return Math.min(keySheet.contentHeight + zenon.sheetPad * 2,
                            Screen.height - 200)
        if (root.sheet.length) return root.g.lines * zenon.rowHeight
        // THE ART VIEWER DOES NOT. It is a card floating over the menu, so the
        // menu underneath keeps the shape it had -- which it did not, because
        // this returned the CARD's line count for it: art.rasi is one line tall,
        // so a 671-row list was laid out one row high, and a GridView flowing
        // top to bottom answers that by running the list into 671 COLUMNS.
        // Closing the card left it parked among them, sideways. That is the
        // "garbled text, like two columns" coming back from Alt+a.
        // NO ROWS MEANS NO BODY. This had a floor of one, which drew an empty
        // row's worth of panel for a list that genuinely has nothing in it -- a
        // search history before you have searched for anything. The floor was
        // never load-bearing for the loading case either: rows are deliberately
        // left standing until the next draw applies, so a menu in flight is
        // sized by the rows still on screen rather than by this.
        var used = Math.min(Math.ceil(rows.count / root.columns), root.menuG.lines)
        return used * (layout === "grid" ? zenon.cellHeight : zenon.rowHeight)
    }
    // Every bar in the column pays for itself, and each collapses to nothing
    // when it has nothing to say -- the input bar outside search, the message
    // bar with no caption and no trail, the notification between notifications,
    // the now-playing strip with nothing loaded.
    // An overlay IS the panel: it draws its own caption above its own picture and
    // covers everything else, so the panel is exactly as tall as it. Adding the
    // chrome underneath reserved room for a message bar and a now-playing strip
    // that the overlay then painted over -- which is the empty band that sat
    // below every cover and every artist image.
    readonly property int menuHeight: inputBar.height + message.height + bodyHeight
                                     + noticeBar.height + nowBar.height + zenon.borderWidth
    // A sheet is still a panel and sizes the window to itself. The art viewer is
    // a card ON the menu, so the surface only has to grow enough to hold it --
    // and when the menu is already taller, it does not grow at all.
    // NOT visible from QML. The host shows the window only after asking
    // LayerShellQt for it -- get() has to run before the platform window exists
    // or the surface is created as an ordinary toplevel and the compositor tiles
    // it like any other app. Showing here cost exactly that on the first run.
    visible: false
    color: "transparent"          // the rounded panel below paints the ground

    Theme { id: zenon }

    // THE FIRST DRAW. Asked for, not waited for. `restore` answers empty when
    // there is no session worth reopening, and Main is the fallback -- so one
    // round trip covers both cold and warm starts with no startup race.
    // NOT called directly. Component.onCompleted runs while this object's own
    // `var` properties are still being initialised, and `pending` is initialised
    // by a binding -- `({})` is an expression, evaluated when the binding is,
    // which can be AFTER onCompleted has already run. Calling out from here put
    // the first request's callback into the object that existed at that instant
    // and then had it replaced by a fresh empty one, so the reply came back to
    // nobody: the engine answered, the row data was right there, and the panel
    // sat empty forever because the one function that draws it was never called.
    //
    // Nothing about it looked like a failure -- no error, no missing response,
    // just a menu that came up blank -- and which draw it ate depended on the
    // ORDER the properties happen to be declared in, so moving a block of them
    // was enough to start it. callLater runs once the event loop next turns, by
    // which point every binding on this object has been evaluated.
    Component.onCompleted: Qt.callLater(root.bootstrap)
    function bootstrap() {
        // `spoot --listen` on a COLD start. It used to return here, which meant
        // the saved trail was never resumed -- Listen became hop one of an empty
        // trail, so the journey you were on was silently thrown away, and there
        // was no menu underneath for the card to sit on. It resumes first now and
        // opens Listen on top of that, exactly as the keybind does on a warm one.
        var wantListen = (typeof startView !== "undefined" && startView === "listen")
        // A bare nav means "resume": the engine replays the hop list it saved,
        // and hands it back so the restored trail is walkable rather than a line
        // of dead text. Falls back to the session restore for a first run with
        // no saved trail yet, and to Main if there is nothing at all.
        var bid = root.call("nav", {}, function (d) {
            root.drawReq = bid
            if (d && d.rows && d.rows.length) {
                if (d.hops && d.hops.length) {
                    root.hops = root.toArray(d.hops)
                    root.trailPos = Math.max(0, Math.min(d.hops.length,
                        (d.pos === undefined || d.pos === null) ? d.hops.length : d.pos))
                    root.fullCrumb = root.toArray(d.tip)
                    root.fullRoots = root.toArray(d.tipRoots)
                }
                root.render(d)
                if (wantListen) root.openListen()
                return
            }
            var rid = root.call("restore", {}, function (r) {
                root.drawReq = rid
                if (r && r.rows && r.rows.length) root.render(r)
                else root.goHome()
                if (wantListen) root.openListen()
            })
        })
    }
    ListModel { id: rows }

    // --- engine plumbing ----------------------------------------------------
    property var pending: ({})
    property string layout: "grid"
    // The rows as the engine sent them. Filtering rebuilds `rows` from this, so
    // typing never costs a request -- rofi filtered a static list too, it just
    // had no choice about it.
    property var allRows: []
    property string filter: ""
    property var playback: ({})
    // WHERE WE ARE, as the engine understands it: an entry point plus the row
    // indices walked into it. Navigation is stateless replay -- the same shape
    // replay_session uses to restore a warm start -- so there is no view stack
    // here to fall out of sync with the engine's.
    // THE TRAIL, flat. A hop is either a ROOT -- {cmd,key}, an entry point you
    // jumped to -- or a STEP: {step} a selection made inside the root above it.
    // One list rather than "an entry point plus a path" because the two were
    // never independent: a new root used to reset the path, which is exactly
    // why pressing Alt+s three levels deep threw the trail away. Appending a
    // root instead keeps the walk intact, and the engine replays the segments
    // in order so the crumb keeps reading through them.
    // Empty IS Main: the trail before you have taken a step. Picking a tile off
    // the Main grid appends the tile's own root, so Main never needs a hop of
    // its own -- and the chain does not open with a seam.
    property var hops: []
    // HOW MANY HOPS ARE ACTIVE -- the cursor. 0 means Main.
    property int trailPos: 0
    function activeHops() { return root.hops.slice(0, root.trailPos) }
    // Index of the root hop governing a position. Steps belong to the nearest
    // root above them, which is the one rule segment boundaries need.
    // Clamped, because `hops` and `trailPos` are two properties and QML cannot
    // assign them at once: every truncation shortens the list a moment before it
    // moves the cursor, and anything reading through the cursor in that moment
    // read off the end. It threw inside a BINDING, so nothing failed visibly --
    // the binding simply kept its old value and the view drew the previous
    // view's path. Clamping is the fix; the assignment order is not.
    function trailEnd() { return Math.min(root.trailPos, root.hops.length) }
    function rootAt(pos) {
        var p = Math.min(pos, root.hops.length)
        for (var i = p - 1; i >= 0; i--) if (root.hops[i] && root.hops[i].cmd) return i
        return -1
    }
    readonly property var entryHop: root.hops[root.rootAt(root.trailPos)] || {cmd: "main", key: ""}
    readonly property string entryCmd: root.entryHop.cmd || "main"   // "main" | "open" | "view"
    readonly property string entryKey: root.entryHop.key || ""       // tile key or view name
    // The steps taken INSIDE the current root -- what "path" always meant, now
    // derived rather than stored, so it cannot drift from the hop list.
    readonly property var path: {
        var end = root.trailEnd()
        var r = root.rootAt(end), out = []
        for (var i = r + 1; i < end; i++) {
            var h = root.hops[i]
            if (h && h.step !== undefined) out.push(h.step)
        }
        return out
    }
    // Append a hop, dropping whatever was ahead of the cursor. Walking back and
    // then choosing something else BRANCHES -- the stretch you walked out of
    // described a trail you have just left, so it makes way for the new one.
    // What the trail was before this step. A step that turns out to ACT rather
    // than navigate -- playing a track, liking one -- has taken you nowhere, so
    // the part of the trail ahead of the cursor is still ahead of you. Truncating
    // on the way in meant playing a track after walking back with Alt+left cut
    // the forward trail exactly as Backspace does.
    property var preHops: []
    property int prePos: 0
    function pushHop(h) {
        root.preHops = root.hops
        root.prePos = root.trailPos
        var hs = root.activeHops()
        hs.push(h)
        root.hops = hs
        root.trailPos = hs.length
        root.fullCrumb = []; root.fullRoots = []
    }

    function call(cmd, args, cb) {
        var id = Engine.request(cmd, args || {})
        if (cb) pending[id] = cb
        return id
    }

    // --- OPENING INSTANTLY ---------------------------------------------------
    // A menu is a place, not a payload: asking for one puts you there straight
    // away and its contents arrive at their own pace. Every draw goes through
    // here, so this is the rule for all of them rather than a special case for
    // the slow ones -- and which ones are slow is not knowable in advance
    // anyway. A warm shelf answers in a millisecond; a search, a discography or
    // a show's episode list goes to the network first, and without this you sit
    // looking at the PREVIOUS menu with nothing to say the key registered.
    property int inFlight: 0
    // Which requests are DRAWS. A draw that fails is still a draw that finished,
    // and without knowing which ids those were the panel would stay blanked at a
    // held height forever, waiting for an answer that already came back as an
    // error.
    property var drawIds: ({})
    // Waiting long enough to say so. Drives the glow and nothing else.
    property bool blanked: false
    readonly property bool loading: root.inFlight > 0
    // The rows are NOT cleared any more. Clearing them was how the body stopped
    // showing the previous menu during a wait, and the transition does that now
    // -- it fades the body out on its way to the next menu and leaves it out
    // until the draw lands. Clearing on top of that bought nothing and cost the
    // panel its height, which is the only reason heldHeight had to exist.
    //
    // Long, and much longer than it was. This is the mark of a menu that is
    // genuinely fetching, so it must not appear for a round trip nobody
    // experienced as a wait: playing a track is one API call, comes back in a
    // couple of hundred milliseconds, and was lighting this up on a list that
    // was already entirely cached.
    Timer {
        id: glowDelay
        interval: 500
        onTriggered: if (root.inFlight > 0) root.blanked = true
    }
    // --- MENU TRANSITIONS ---------------------------------------------------
    //
    // One menu gives way to the next by carrying on the way you were headed:
    // going deeper, the outgoing menu grows and fades, and the one arriving
    // comes up from behind it. Going back plays the same move mirrored. That
    // mirroring is the whole point -- it is what makes the direction readable
    // rather than decorative, so back never looks like forward.
    //
    // The body only. The panel resizes between menus of different heights, and
    // that resize happens while the body is at zero opacity, so it is never
    // seen -- which is why the chrome deliberately stays put: a message bar
    // zooming would only draw attention to the seam.
    property int navDir: 1                       // 1 deeper, -1 back
    property real bodyZoom: 1
    property real bodyFade: 1
    readonly property real zoomBy: 0.06
    // A draw that landed while the outgoing half was still playing. Applying it
    // there would swap the rows out from under an animation whose whole subject
    // is those rows, so it waits -- for the remainder of an animation already
    // running, not for a delay added on top of one.
    property var heldDraw: null
    ParallelAnimation {
        id: swapOut
        NumberAnimation { target: root; property: "bodyFade"; to: 0
                          duration: 110; easing.type: Easing.InCubic }
        NumberAnimation { target: root; property: "bodyZoom"
                          to: 1 + root.navDir * root.zoomBy
                          duration: 110; easing.type: Easing.InCubic }
        onFinished: {
            if (!root.heldDraw) return
            var d = root.heldDraw
            root.heldDraw = null
            root.applyDraw(d)
            // ...and then its covers, which have been waiting on it.
            root.flushHeldArt()
        }
    }
    // Longer than the out half, because arriving is the half worth watching --
    // the same reason the panel's own open outlasts its close.
    ParallelAnimation {
        id: swapIn
        NumberAnimation { target: root; property: "bodyFade"; to: 1
                          duration: 160; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "bodyZoom"; to: 1
                          duration: 160; easing.type: Easing.OutCubic }
    }
    // Back to plain, now. For the paths that end without a draw -- an engine
    // error above all -- where the body would otherwise be left mid-transition
    // and invisible, waiting for an arrival that is not coming.
    function abortSwap() {
        swapOut.stop(); swapIn.stop()
        root.heldDraw = null
        root.heldArt = []
        root.bodyZoom = 1
        root.bodyFade = 1
    }

    function beginDraw() {
        root.inFlight++
        glowDelay.restart()
    }

    // --- NOTIFICATIONS ---------------------------------------------------
    // A remark the app is making, as opposed to the caption of the menu you are
    // in. rofi had exactly one message bar and both had to share it, so "Copied
    // link" arrived by REPLACING the name of the view you were standing in --
    // you were told one thing at the cost of being told another.
    //
    // Here it gets its own bar at the foot of the panel. See noticeBar: it
    // pushes the menu up rather than covering a row, so nothing you were looking
    // at is hidden in order to tell you something.
    property string notice: ""
    // --- DEPENDENCIES --------------------------------------------------------
    //
    // spoot runs other programs -- curl for every request, playerctl for every
    // transport key, spotifyd for the sound itself -- and missing one of them
    // fails somewhere deep and quiet. The engine says which are absent and what
    // would install them; this decides whether to just go ahead.
    //
    // It goes ahead only when the engine says it can do so without asking spoot
    // to handle a password: already root, a sudo/doas rule that grants it
    // non-interactively, a package manager that installs into the user's own
    // profile, or pkexec -- which raises the DESKTOP's authentication dialog,
    // drawn and read by the desktop and never by spoot. Anything else is
    // reported with the exact command, which for plenty of setups is the right
    // answer rather than a lesser one.
    property var deps: null
    // One install at a time, ever. The event fires once, so this is belt and
    // braces -- but a second pkexec dialog stacked on the first is the kind of
    // thing there is no recovering from without a keyboard.
    property bool depsBusy: false
    function onDeps(d) {
        root.deps = d
        var miss = root.toArray(d.missing).join(", ")
        if (d.auto === true) {
            root.installDeps(d, miss)
            return
        }
        // Nothing to run, or already tried today. Say what is missing and how to
        // fix it by hand -- once, in the notice bar, not on every launch.
        root.notify(miss + " missing \u2014 run: spoot --doctor install")
    }
    function installDeps(d, miss) {
        if (root.depsBusy) return
        root.depsBusy = true
        root.notify("Installing " + miss + "\u2026", true)
        // pkexec needs the keyboard, and this surface has all of it.
        var auth = d.method === "pkexec"
        if (auth && typeof Shell !== "undefined") Shell.setGrab(false)
        root.call("deps", {install: true}, function (r) {
            root.depsBusy = false
            // Taken back whatever happened -- an install that failed must not
            // leave the panel unable to hear a keystroke.
            if (auth && typeof Shell !== "undefined") Shell.setGrab(true)
            // ONE MESSAGE, then on to the login regardless of which it was: a
            // partial install can still have landed everything the login itself
            // needs, and stopping here would strand a machine that was one step
            // from working.
            if (!r) root.notify("Dependency install failed")
            else {
                var left = root.toArray(r.missing)
                if (left.length === 0) root.notify("Installed " + miss)
                else if (r.ok === true)
                    root.notify("Installed some \u2014 still missing: " + left.join(", "))
                else
                    root.notify("Could not install " + left.join(", ")
                                + " \u2014 run: spoot --doctor install")
            }
            root.runSetup()
        })
    }

    // `sticky` holds it until something replaces it. For work whose length is not
    // ours to know -- a package manager can take half a minute -- where a notice
    // that times out would leave the panel looking idle mid-install.
    // --- FIRST RUN -----------------------------------------------------------
    //
    // Dependencies, then the account, then the playback device -- in that order,
    // because each needs the one before it. The account login is a curl exchange
    // with an openssl challenge, caught by a perl listener and shown to you by
    // xdg-open; the device login is spotifyd's own OAuth. Neither can run on a
    // machine that has not been set up yet, which is why this waits for the
    // install rather than racing it.
    property var setupNeed: null
    property bool setupBusy: false
    function onSetup(d) {
        root.setupNeed = d
        // The install goes first when there is one. installDeps calls back here
        // when it is done -- including when it failed, since a failed install can
        // still leave enough behind to log in with.
        if (!root.depsBusy) root.runSetup()
    }
    function runSetup() {
        var need = root.setupNeed
        if (root.setupBusy || !need) return
        var lack = root.toArray(need.lack)
        if (lack.length > 0) {
            // Naming the programs beats opening a page that cannot complete.
            root.notify("Cannot sign in without " + lack.join(", "))
            return
        }
        root.setupBusy = true
        root.notify(need.token === true ? "Authorising playback\u2026"
                                        : "Signing in to Spotify\u2026", true)
        // OUT OF THE WAY, not merely ungrabbed. This surface covers the whole
        // output and takes every pointer event on it, so a browser tab opened
        // underneath could not be clicked; and the login is a page you have to
        // read, not a dialog you dismiss. Hiding hands back the keyboard as well.
        if (typeof Shell !== "undefined") Shell.conceal()
        setupGuard.restart()
        root.call("setup", {}, root.finishSetup)
    }
    function finishSetup(r) {
        setupGuard.stop()
        root.setupBusy = false
        root.setupNeed = null
        if (typeof Shell !== "undefined") Shell.reveal()
        if (!r) { root.notify("Sign-in failed"); return }
        var lack = root.toArray(r.lack)
        if (lack.length > 0) {
            root.notify("Cannot sign in without " + lack.join(", "))
            return
        }
        if (r.token === true && r.device === true) {
            root.notify("Signed in")
            // The menus drawn before this had no token behind them.
            root.refresh()
            return
        }
        if (r.token !== true) {
            root.notify("Not signed in \u2014 System \u203a Re-authenticate")
            return
        }
        root.notify("Playback device not authorised \u2014 System \u203a Re-authenticate")
        root.refresh()
    }
    // The window must never be left hidden by a login that never came back. Only
    // reveals -- the reply is still expected, and finishSetup remains the one
    // place that decides what happened.
    Timer {
        id: setupGuard
        interval: 330000
        onTriggered: {
            if (typeof Shell !== "undefined") Shell.reveal()
            root.notify("Sign-in is taking a while \u2014 finish it in your browser")
        }
    }

    function notify(text, sticky) {
        root.notice = (text === undefined || text === null) ? "" : String(text)
        noticeTimer.stop()
        if (root.notice.length && sticky !== true) noticeTimer.restart()
    }
    // COPYING A LINK SAYS SO WITHOUT WORDS. It is over the moment it happens and
    // the only thing worth reporting is that it happened, so it is reported as a
    // mark next to the thing that was copied and then withdrawn -- rather than a
    // sentence you have to read and then wait out.
    //
    // On the ROW, at its right edge -- "Copy Web Link" out of an action menu is
    // the only way to ask for it now, and the row is the honest place to say so
    // because it names WHICH thing was copied. A second mark used to land in the
    // now-playing strip for Alt+g, back when that key copied the playing track;
    // it opens a pasted link instead (see Keymap), so that mark is gone.
    property int lastSrc: -1                  // the row the last step picked
    property int copiedSrc: -1                // ...and the one that copied, if any
    Timer {
        id: copiedTimer
        interval: 1000
        onTriggered: root.copiedSrc = -1
    }
    Timer {
        id: noticeTimer
        // Long enough to read a sentence twice, short enough to be gone before
        // you next look down.
        interval: 4500
        onTriggered: root.notice = ""
    }
    function endDraw() {
        root.inFlight = Math.max(0, root.inFlight - 1)
        if (root.inFlight > 0) return
        glowDelay.stop()
        root.blanked = false
    }

    Connections {
        target: Engine
        function onResponse(id, ok, data, err) {
            var cb = root.pending[id]
            var wasDraw = root.drawIds[id] === true
            delete root.pending[id]
            delete root.drawIds[id]
            if (!ok) {
                // render() would have released it; nothing else will -- and
                // neither will anything bring the body back, which is halfway
                // out on a transition that now has nothing to transition to.
                if (wasDraw) { root.endDraw(); root.abortSwap() }
                root.notify(err && err.length ? err : "engine error")
                return
            }
            if (cb) cb(data)
        }
        function onEvent(name, data) {
            // `ready` is deliberately NOT the trigger for the first draw. It is
            // an unsolicited event the engine fires the moment it starts, and
            // qml.load() spins the event loop -- so QProcess can deliver it
            // before this Connections object exists and it is simply lost. The
            // first draw is PULLED in bootstrap() instead, which cannot race.
            if (name === "ready") { /* handshake seen; nothing to do */ }
            // A view that wants to say "No results" says it here -- rofi_message
            // has nowhere to draw when the front end is not rofi.
            else if (name === "message") {
                // Multi-line means a SHEET (Track/Album/Podcast Details, the
                // keybind list); one line is a status remark. rofi needed a
                // separate themed window for the former -- here it is a panel
                // that slides over the rows and takes Escape.
                var t = data.text || ""
                if (root.overlayTheme === "listen") root.closeOverlay()
                if (t.indexOf("\n") >= 0) {
                    root.sheet = t
                    root.overlayFresh = true
                    root.overlayTheme = data.theme || "meta"
                    root.popTransient()
                }
                else root.notify(t)
            }
            // The row that asked for it wears the mark. The event arrives before
            // the redraw that follows, and the redraw puts the same rows back --
            // "Copy Web Link" leaves no place behind it -- so by the time this is
            // visible it is sitting on the entry you picked.
            else if (name === "copied") { root.copiedSrc = root.lastSrc; copiedTimer.restart() }
            // A play STARTED. The trail is not settled yet -- the step that
            // played is still on it and the draw that drops it has not arrived
            // -- so this only arms the record; applyDraw takes it once the trail
            // describes the menu again. See originId.
            else if (name === "played") root.armOrigin = data.id || ""
            // ART BELONGS TO ROWS THAT ARE NOT ON SCREEN YET. The engine flushes
            // the rows first and follows with their covers, so while a draw is
            // held for the outgoing transition its art arrives ahead of it --
            // and applying it then patches the menu being LEFT, whose model is
            // about to be replaced by the held draw. Both the wrong rows and
            // then no rows at all: Main came back with five blank tiles.
            //
            // Queued instead, and replayed the moment its own draw is applied.
            // QUIT means the whole app, window included. The engine sweeps the
            // background processes and then leaves, and it is the host that owns
            // it rather than the other way round -- so without this the window
            // stayed up holding a dead pipe.
            else if (name === "quit") Qt.quit()
            else if (name === "art" || name === "context-art") {
                if (root.heldDraw) root.heldArt.push({name: name, data: data})
                else root.applyArtEvent(name, data)
            }
            // WHAT SPOOT NEEDS AND HAS NOT GOT. Sent once at startup and only
            // when something is missing, so a healthy machine never sees this
            // path at all.
            else if (name === "deps") root.onDeps(data)
            // ...and what a first run still owes after them. Always sent after
            // the deps event, which is what makes the ordering trivial here.
            else if (name === "setup") root.onSetup(data)
            else if (name === "sheet") {
                root.sheetRows = root.toArray(data.rows)
                root.overlayFresh = true
                root.sheetKind = data.kind || ""
                root.overlayTheme = data.theme || "meta"
                root.popTransient()
            }
            else if (name === "listening") {
                // Reuses the art overlay wholesale: a 300px asset with a caption
                // under it is exactly what that draws, and listen.rasi's own
                // geometry (304px window, 300px icon) comes from the same table.
                // A second "modal with a picture" would have been a duplicate.
                root.artPath = data.asset || ""
                root.overlayFresh = true
                root.artMesg = "spoot is listening\u2026"
                root.overlayTheme = "listen"
            }
            else if (name === "prompt") {
                root.promptFor = data.prompt || ""
                root.setFilter(data.preset || "")
                // The step that opened the prompt is not a place either -- the
                // engine answered nil and stayed put -- so it comes off the path
                // and is re-sent with the text appended when you submit.
                root.popTransient()
            }
            else if (name === "art-view") {
                root.artPath = data.path || ""
                root.overlayFresh = true
                root.artMesg = data.mesg || ""
                root.overlayTheme = data.theme || "art"
                root.popTransient()
            }
        }
    }

    // Covers arrive after the rows, one event per view. Patching the model in
    // place is what lets a grid fill in while you are already scrolling it --
    // the delegate's Image sees its source change and fades the cover in.
    //
    // Indices are into the UNFILTERED list, because that is what the engine
    // drew; the filtered model is found by id so a filter typed while art was
    // still in flight cannot misplace a cover.
    // Art that arrived before the draw it belongs to, waiting for it.
    property var heldArt: []
    // Which request the visible draw came from. Artwork is resolved after its
    // reply is sent, so a batch can arrive for a menu you have already left --
    // and applyArt patches by ROW INDEX, which means those covers land on
    // whatever list is showing now. That is the cover that does not match the
    // cursor: not a stale binding, a stale event.
    property int drawReq: -1
    function applyArtEvent(name, data) {
        // Untagged events predate nothing and are trusted; a tagged one has to
        // belong to the draw on screen.
        if (data.req !== undefined && data.req !== root.drawReq) return
        if (name === "art") root.applyArt(data)
        else root.contextArt = data.path || ""
    }
    function flushHeldArt() {
        var q = root.heldArt
        root.heldArt = []
        for (var i = 0; i < q.length; i++) root.applyArtEvent(q[i].name, q[i].data)
    }

    function applyArt(data) {
        var items = data.items || []
        // UNFILTERED, the model IS the source list, so `src` is the row's own
        // index plus one and there is nothing to search for. Filtered, the two
        // diverge and a scan is the only honest way -- but a filter is a
        // transient state and a full grid of covers is not.
        var direct = root.filter.length === 0
        for (var k = 0; k < items.length; k++) {
            var i = items[k].i - 1                     // Lua is 1-based
            if (i < 0 || i >= root.allRows.length) continue
            var icon = items[k].icon || ""
            root.allRows[i].icon = icon
            var j = -1
            if (direct) {
                if (i < rows.count && rows.get(i).src === items[k].i) j = i
            }
            if (j < 0) {
                // By source index rather than by label: two rows can carry the
                // same text (a single and its album, a track appearing twice),
                // and the first match would take the wrong cover.
                for (var m = 0; m < rows.count; m++) {
                    if (rows.get(m).src === items[k].i) { j = m; break }
                }
            }
            if (j < 0) continue
            // ONLY WHAT CHANGED. Every draw's continuation reports every cover it
            // has resolved so far, not just the new ones -- so this was writing
            // the same path back over every row of the list on every redraw, and
            // a ListModel write is a change signal whether or not the value
            // differs. Each one made an Image re-evaluate its source, and a
            // whole grid of them doing it at once is exactly the "refresh" that
            // kept appearing when nothing had actually changed.
            if (rows.get(j).icon !== icon) rows.setProperty(j, "icon", icon)
        }
    }

    function applyFilter() {
        rows.clear()
        // While composing a query the history stays whole -- it is a suggestion
        // list, not a menu you are confined to.
        var f = root.composing ? "" : root.filter.toLowerCase()
        for (var i = 0; i < root.allRows.length; i++) {
            var r = root.allRows[i]
            // Substring, case-insensitive -- rofi's default matcher.
            // EVERY role is present on every append, even when empty. ListModel
            // fixes its roles from the first object it is given, so appending a
            // row without `icon` -- which is now every row, since art streams in
            // afterwards -- meant the role never existed and setProperty had
            // nothing to write to. That is why grids stayed grey.
            // `src` is the row's index in the UNFILTERED list, 1-based, which
            // is what the engine indexes. Filtering is done here, so without it
            // picking the third visible row asked the engine for its third row
            // -- and played a completely different track. Shift+Return had the
            // same fault, for the same reason.
            if (!f.length || String(r.label).toLowerCase().indexOf(f) >= 0)
                rows.append({label: r.label, icon: r.icon || "", key: r.key || "",
                             // The row's own track id, so the view can tell
                             // which row is playing without being told again.
                             id: r.id || "",
                             // The same row with its markup kept, when it has any.
                             // Filtering matches `label`, which is why that one
                             // stays plain -- see Util.serve_rows.
                             rich: r.rich || "", src: i + 1})
        }
    }

    // Lists that cross the engine boundary arrive as QVariantList proxies, not
    // as JS arrays: they index and have a length, but slice/indexOf are simply
    // absent -- and calling one throws mid-render, leaving the draw half applied
    // with no visible error at all. Everything the UI keeps gets copied first.
    function toArray(v) {
        var out = []
        if (v) for (var i = 0; i < v.length; i++) out.push(v[i])
        return out
    }

    // THE SAME MENU, ANSWERED AGAIN. Playing a track sends a step like any
    // other, and the engine plays it and hands back the very menu you were on --
    // it has to, because the transport glyph marking the playing row is baked
    // into the row's text, so moving it means redrawing. That is a REDRAW, not a
    // journey, and animating it as one had a fully cached list fade out, sit
    // under a loading glow and fade back in to say a marker had moved.
    //
    // Compared on crumb and scope rather than on rows: the rows are exactly what
    // a redraw changes.
    function sameMenu(d) {
        if (!d) return false
        if ((d.scope || "") !== root.scope) return false
        var c = d.crumb || []
        if (c.length !== root.crumb.length) return false
        for (var i = 0; i < c.length; i++) if (c[i] !== root.crumb[i]) return false
        return true
    }

    function render(d) {
        // The draw this was waiting on. Released FIRST, so bodyHeight is sizing
        // from the rows below rather than from the height it was holding.
        root.endDraw()
        // NOTHING TO DRAW IS NOT A MENU. Views that exist to produce an overlay
        // -- the art viewer, a details sheet -- and views that find they have
        // nothing to show -- an empty queue, no followed podcasts -- answer with
        // an empty draw and say the rest in an event. The menu you were standing
        // in is still the menu you are standing in.
        //
        // CHECKED HERE, ahead of everything else, and the transition is UNDONE
        // rather than merely skipped. Returning early further down was not
        // enough: by then the body had already faded out on its way to a menu
        // that never arrived, and nothing was left to fade it back. The rows
        // were all still there -- Liked looked empty because it was invisible,
        // and only reopening it brought it back.
        //
        // The freshness goes with it, or the next real menu would spare an
        // overlay that by then is stale.
        if (d && d.empty === true) {
            root.abortSwap()
            root.overlayFresh = false
            return
        }
        // Still going out. Held until it has, and applied by swapOut itself.
        if (swapOut.running) { root.heldDraw = d; return }
        // Back where we started: swap the rows in place and animate nothing.
        if (root.sameMenu(d)) { root.applyDraw(d, true); return }
        // Somewhere new, and we know it before the leaving half has begun --
        // so it begins now, with the draw held for it.
        root.heldDraw = d
        swapOut.restart()
    }

    // The rows, updated in place. Answers false when it cannot -- a different
    // number of rows, or a filter narrowing them -- and the caller rebuilds.
    function patchRows(list) {
        if (root.filter.length || list.length !== rows.count) return false
        for (var i = 0; i < list.length; i++) {
            var r = list[i], m = rows.get(i)
            if (m.label !== r.label) rows.setProperty(i, "label", String(r.label))
            var rich = r.rich || ""
            if (m.rich !== rich) rows.setProperty(i, "rich", rich)
            // AN EMPTY ICON NEVER CLEARS ONE. A draw carries no artwork at all:
            // Util.serve_run defers album_thumbs so the rows go out first, and
            // every cover arrives afterwards as an `art` event. So on a REDRAW
            // this wrote that absent icon over the cover the last art pass had
            // resolved -- every tile in the grid dropped to its placeholder and
            // the event that followed a moment later faded them all back in.
            //
            // That is the faint flicker on playing a single from an album grid:
            // not one tile changing, the whole grid's covers blinking. Lists
            // never showed it because a list row carries no cover.
            //
            // A cover that is genuinely withdrawn therefore keeps its last known
            // picture until the view is opened again, which is the right trade:
            // "not resolved yet" and "there is none" arrive here as the same
            // empty string, and one of them happens constantly.
            var icon = r.icon || ""
            if (icon.length && m.icon !== icon) rows.setProperty(i, "icon", icon)
            var key = r.key || ""
            if (m.key !== key) rows.setProperty(i, "key", key)
            var rid = r.id || ""
            if (m.id !== rid) rows.setProperty(i, "id", rid)
        }
        return true
    }

    function applyDraw(d, quiet) {
        // A DRAW MEANS THE OVERLAY IS DONE -- unless this draw is the one that
        // brought it. An overlay arrives as an EVENT, and the engine writes its
        // events before the response, so the reply that follows is the very menu
        // the overlay was opened from. Closing on that reply shut every viewer
        // the instant it opened: Albumart out of an action menu, an artist's
        // impression, a details sheet. Only the art views reached from Alt+a
        // survived, and only because those answer with an empty draw that never
        // gets this far.
        //
        // So: an overlay this round trip opened stays, and one left over from an
        // earlier menu goes -- which is the case this was written for, a session
        // resumed into a viewer that then sat on top of Main.
        if (!root.overlayFresh
            && (root.sheet.length || root.sheetRows.length || root.artPath.length)) {
            root.closeOverlay()
        }
        root.overlayFresh = false
        // The engine says how many path steps still describe WHERE YOU ARE;
        // anything beyond that ran an action and left no place behind it. Done
        // FIRST, because posKey() reads root.path -- a list keeps its identity,
        // and therefore its remembered cursor, across playing a track from it.
        //
        // A count rather than a flag: picking Album Details from an unscoped
        // action menu drops TWO steps, because it returns you to the grid the
        // menu was opened from, not to the menu.
        // `keep` counts steps INSIDE the current root, so it lands after that
        // root's own hop -- the segment boundary the engine measured against.
        if (d && d.keep !== undefined) {
            var want = root.rootAt(root.trailPos) + 1 + d.keep
            if (want < root.trailPos) {
                // ...and if that lands exactly where we stood BEFORE the step,
                // the trail was never left at all -- so it goes back whole,
                // including whatever lay ahead of the cursor. Truncating there
                // instead is what made playing a track after Alt+left cut the
                // forward trail the way Backspace does.
                //
                // Decided by `keep`, which is the engine saying whether the step
                // described a place. It used to be decided by "the redraw looks
                // like the menu we were already on", which an ACTION MENU always
                // does -- it is unscoped and wears its parent's crumb -- so
                // Shift+Return was discarded as a no-op and the next pick landed
                // in the grid behind it. That is the whole of "Album Details just
                // goes to the album grid".
                root.hops = (want === root.prePos && root.preHops.length > want)
                            ? root.preHops : root.hops.slice(0, want)
                root.trailPos = want
            }
        }
        root.filter = ""
        // The cover is NOT cleared here. Clearing it optimistically and waiting
        // for the draw's own context-art to put one back collapsed it to zero
        // width and grew it again on every redraw, which shoved the rows
        // sideways and back. The engine now always says what the cover is --
        // including that there is none -- so this can leave it alone and let the
        // two images cross-fade.
        root.allRows = root.toArray(d.rows)
        // A redraw of the same menu changes almost nothing -- one row gains the
        // transport glyph, one loses it -- so the model is PATCHED where it
        // differs instead of being emptied and refilled. Refilling destroys and
        // rebuilds every delegate, which is the flicker, and it takes the scroll
        // position and the cursor with it.
        // PATCHED, or rebuilt. Which one it was decides whether the cursor has to
        // be placed again below -- a patch leaves every row where it was, a
        // rebuild does not. Gating that on `quiet` instead was wrong for the one
        // case where a quiet redraw still rebuilds: the draw clears the FILTER,
        // so the list goes from a handful of matches back to all of it. The row
        // you picked was then somewhere else entirely and nothing went looking
        // for it -- which is "selecting a filtered item doesn't jump to it".
        var patched = quiet === true && root.patchRows(root.allRows)
        if (!patched) applyFilter()
        root.layout = d.layout || "grid"
        root.viewMesg = d.mesg || d.prompt || ""
        root.canDelete = d.del === true
        root.canTab = d.tab === true
        // The menu's own word that it has no subject -- see contextCover.wanted,
        // which refuses a backdrop to whole kinds of view; this refuses it to one
        // menu inside a view that otherwise wears one.
        root.noCover = d.art === false
        // ...and whether the cover it DOES wear is whatever is playing. See
        // coverArt: on a shelf the live poll value wins, so the backdrop follows
        // the music rather than the menu.
        root.artLive = d.artLive === true
        root.crumb = root.toArray(d.crumb)
        root.crumbRoots = root.toArray(d.roots)
        // Standing at the tip, THIS crumb is the deepest one -- remember it so
        // that stepping back can still show what lies ahead. Read after the
        // assignment above, never before: the crumb here is the one just drawn.
        if (root.trailPos >= root.hops.length) {
            root.fullCrumb = root.crumb.slice()
            root.fullRoots = root.crumbRoots.slice()
        }
        // Record where we are, keyed by how deep the crumb reads.
        if (root.crumb.length > 0) root.trailMap[root.crumb.length] = root.trailPos
        root.themeName = d.theme || ""
        root.scope = d.scope || ""
        root.lyricTimes = []; root.lyricFor = ""; root.lyricIndex = -1
        if (d.scope === "lyrics" && d.track) {
            var want = d.track
            root.call("lyrics", {id: want}, function (ly) {
                // Positional, so the cues must line up with the rows the view
                // drew. If they do not, the track has lyrics but not synced ones
                // -- show them, just do not pretend to follow along.
                if (ly && ly.synced && ly.lines && ly.lines.length === rows.count) {
                    root.lyricTimes = root.toArray(ly.times)
                    root.lyricFor = want
                }
            })
        }
        // The trail describes the menu again -- the step that played has been
        // dropped by `keep` -- so this is the moment the origin is knowable.
        // WHERE THE PLAYING TRACK CAN BE SEEN is an origin, whether or not you
        // played it from here. Recording only at the moment of playing left
        // Alt+c with nothing to go on for anything started in an earlier session,
        // or from a menu the trail no longer remembers -- and there is no honest
        // answer to "take me to it" without one.
        //
        // An ACTION MENU is never an origin: it is a list of verbs about a track,
        // not a place the track lives, so it records the list it was opened from.
        if (root.armOrigin.length || (root.playback.id && root.playingRowIndex() >= 0)) {
            var oid = root.armOrigin.length ? root.armOrigin : root.playback.id
            var opos = root.trailEnd()
            if (root.scope === "action" && opos > 0) opos -= 1
            root.armOrigin = ""
            root.originId = oid
            root.originHops = root.hops.slice(0, opos)
            root.originPos = opos
        }
        // Not on a patched redraw: the cursor never moved, and putting it back
        // where it already is scrolls the view to it.
        if (!patched) root.applyPos()
        // The first draw is the other half of the opening trigger: on a cold
        // start the panel has nothing in it when the host reveals it, and this
        // is the moment it does.
        if (!root.opened) root.showPanel()
        // A redraw arrives without arriving: nothing moved, so nothing animates.
        // The trail is NOT touched here -- see the keep block above, which is
        // where the engine says whether a step described a place.
        if (quiet) {
            root.bodyZoom = 1; root.bodyFade = 1
            return
        }
        // Arriving from behind wherever the outgoing menu went. Set rather than
        // animated: this is the START of the incoming half, and animating INTO a
        // start position would play the move backwards first.
        root.bodyZoom = 1 - root.navDir * root.zoomBy
        root.bodyFade = 0
        swapIn.restart()
        if (typeof SPOOT_DEBUG !== "undefined") {}
        console.log("render: rows=" + rows.count + " layout=" + root.layout
                    + " bodyH=" + root.bodyHeight + " item=" + (body.item ? "yes" : "NULL")
                    + " trail=" + root.trailPos + "/" + root.hops.length
                    + " crumb=" + JSON.stringify(root.crumb)
                    + " roots=" + JSON.stringify(root.crumbRoots))
    }

    // Restoring has to survive the Loader being ASYNCHRONOUS: right after a view
    // swap body.item is still null, so doing this inline from render() silently
    // did nothing and every revisit snapped to the top. Called from both here
    // and Loader.onLoaded, whichever happens second.
    function applyPos() {
        if (!body.item) return
        if (body.item.glideMs !== undefined) body.item.glideMs = 0
        // Alt+c opened this view: the playing row wins over the remembered
        // cursor. Consumed HERE rather than in render() because the Loader is
        // asynchronous -- whichever of the two calls finds a live view first is
        // the one that gets to place the cursor.
        if (root.seekPlaying) {
            root.seekPlaying = false
            if (root.cursorToPlaying()) return
        }
        var want = root.positions[posKey()]
        // Clamped -- a list can come back shorter than it was when you left it.
        body.item.currentIndex =
            Math.max(0, Math.min(rows.count - 1, want === undefined ? 0 : want))
    }
    property string viewMesg: ""
    // Raised by an overlay EVENT and cleared by the next draw. See applyDraw: it
    // is the difference between the overlay this menu just opened and one the
    // last menu left behind.
    property bool overlayFresh: false
    // Non-empty while a detail sheet is up. It owns Escape/Backspace until
    // dismissed, which is why the keymap asks about it first.
    property string sheet: ""
    // The theme an overlay was opened with -- meta (800px), binds (680), pods
    // (1000), art (1000), imp (640). rofi opened a differently sized WINDOW for
    // each of these; here the panel takes that size while the overlay is up.
    property string overlayTheme: ""
    // A text prompt the engine is waiting on (Rename Playlist, New Playlist).
    // It shares the typing buffer with search rather than owning a second one:
    // in both cases what you type is TEXT to submit, not a filter over rows.
    property string promptFor: ""
    // A STRUCTURED sheet, as opposed to the plain-text `sheet` above. Rendered
    // by a real layout, so it needs no padding and clips nothing.
    property var sheetRows: []
    property string sheetKind: ""
    // The art viewer. rofi could only show a picture as a giant row icon; this
    // is an image, sized to the panel, with the caption rofi put in its mesg.
    property string artPath: ""
    property string artMesg: ""
    // The cover of the thing an action menu is ABOUT. rofi could only name it in
    // the message bar; here it sits beside the verbs, so you can see what you
    // are about to act on.
    property string contextArt: ""
    // Set by the draw itself (Util.serve_draw's `art`): this menu is about
    // nothing you can picture, so it wears no cover however much artwork is
    // reachable from here. The kind-level refusals live in contextCover.wanted.
    property bool noCover: false
    // WHAT THE COVER SHOWS. A menu that is about something -- an album, an action
    // menu -- names its own; everything else wears the playing track's, which
    // arrives with the playback poll and therefore changes the moment the track
    // does, with nothing asked of the engine.
    // IT DOES NOT FOLLOW THE CURSOR. It used to: moving to a track from another
    // album faded that album in. But a cover that changes while you are READING
    // a list is a picture reacting to a cursor, not information -- and it made
    // the one thing the cover should say impossible to see, because playing a
    // track put its art up only for as long as the cursor stayed on that row.
    //
    // The cover follows PLAYBACK now. `artLive` is the engine saying this menu is
    // a shelf (Util.serve_shelf), so the live playback art is the right answer
    // and the poll's own value is used -- which is what makes the next track fade
    // in on autoplay with no redraw and nothing asked of the engine. Off a
    // shelf -- an action menu, an album's own page -- the draw named a subject
    // and that wins.
    readonly property int selIndex: body.item ? body.item.currentIndex : -1
    // Set by the draw. See Util.serve_draw's artLive.
    property bool artLive: false
    // WHICH OVERLAYS MOVE THE PANEL. The image viewer does: albumart and an
    // artist's impression are things you look AT, so the panel leaves the bottom
    // edge and centres on the output.
    //
    // LISTENING IS NOT ONE OF THOSE. It is spoot doing something and telling you
    // it is doing it -- the same class of thing as a menu -- and floating it in
    // the middle of the screen made a thirty-second wait feel like a modal the
    // app had thrown at you. It stays docked south where every other view lives,
    // and only the card's contents differ.
    readonly property bool artCentred:
        root.artPath.length > 0 && root.overlayTheme !== "listen"
    readonly property string coverArt:
        root.artLive ? (root.playback.art || root.contextArt)
                     : (root.contextArt.length ? root.contextArt : (root.playback.art || ""))
    // The crumb, as parts. The engine names the steps (Util.parts_from_stack);
    // the arrows are ZENON's and belong here.
    property var crumb: []
    // Indices into `crumb` where a new ROOT begins -- the engine measured them
    // while assembling the chain, so the UI never has to guess where one trail
    // ends and the next starts.
    property var crumbRoots: []
    // The separator BEFORE a part, as markup. A ROOT is joined by the trail
    // glyph, a step by the arrow: the seam between two trails has to read as a
    // seam rather than as one more step, which is the only thing that makes a
    // jump visible as a jump.
    //
    // One real space and one &nbsp; either side of the root glyph rather than two
    // of either: HTML collapses runs of real spaces, and a pair of &nbsp; would
    // give the width back but take away the line break -- and a separator is
    // exactly where a long chain wants to wrap.
    function crumbSep(isRoot) {
        return isRoot ? " &nbsp;" + zenon.crumbRootSep + "&nbsp; " : " \u203a "
    }
    // Which step the pointer is over, as an index into `crumb`. -1 is none.
    property int crumbHover: -1
    // The chain as markup. One text item rather than a row of them, because a
    // long daisy chain has to WRAP, and every container Qt has -- Flow included
    // -- left-aligns the lines it wraps onto. Only a text item centres each of
    // its own lines, which is what the bar has always done on one line and now
    // keeps doing on three.
    function esc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }
    // text-decoration:none because Qt underlines anchors by default, and an
    // explicit colour because it would otherwise paint them all link-blue.
    function crumbSpan(col, body, href) {
        var s = "<span style=\"color:" + col + "\">" + body + "</span>"
        return href === undefined ? s
             : "<a href=\"" + href + "\" style=\"color:" + col
               + ";text-decoration:none\">" + body + "</a>"
    }
    readonly property string crumbHtml: {
        var out = ""
        for (var i = 0; i < root.crumb.length; i++) {
            var seam = (root.crumbRoots || []).indexOf(i) >= 0
            if (i > 0) out += root.crumbSpan(seam ? zenon.crumbRoot : zenon.crumbArrow,
                                             root.crumbSep(seam))
            // The step you are ON is not a destination -- and now that the cursor
            // can sit anywhere along the trail, it has to SHOW. Bright means
            // "here", the same colour the root seams use; the steps behind stay
            // dim until hovered.
            var last = (i === root.crumb.length - 1)
            var col = last ? zenon.crumbRoot
                           : (root.crumbHover === i ? zenon.foreground : zenon.dim)
            out += root.crumbSpan(col, root.esc(root.crumb[i]), last ? undefined : i)
        }
        // What you stepped back OUT of, held at the arrow's own grey so it reads
        // as a path not taken rather than another destination. Inert on purpose:
        // one path step can spend two crumb parts, so a click here could not say
        // honestly where it would land. Alt+right walks them.
        for (var j = 0; j < root.crumbAhead.length; j++) {
            var k = root.crumb.length + j
            out += root.crumbSpan(zenon.crumbArrow,
                                  root.crumbSep((root.fullRoots || []).indexOf(k) >= 0)
                                  + root.esc(root.crumbAhead[j]))
        }
        return out
    }
    // The theme the engine says this view is drawn with, and the geometry that
    // follows from it. Everything below sizes from `g` -- no view names appear
    // in layout code.
    property string themeName: ""
    // What the view IS -- "liked", "album", "action" -- as the deepest scope on
    // the engine's stack names it. The theme says how a view is drawn; this says
    // what it is, and two shelves need the second to override the first.
    property string scope: ""
    // The theme's column count, and nothing overrules it.
    readonly property int columns: root.menuG.columns
    // The overlay's geometry wins while one is up, exactly as rofi's separate
    // window did -- otherwise a 640px artist impression would be drawn inside a
    // 1000px panel with dead space either side.
    readonly property var g: zenon.geom(root.overlayTheme.length ? root.overlayTheme
                                                                 : root.themeName)
    // ...and the MENU's own geometry, which an overlay never overrules. The two
    // used to be one, and everything that lays out the body read the merged
    // answer -- so an image card floating over a list silently relaid the list
    // to the card's shape. Whatever is behind an overlay is still the menu it
    // was, and it has to be measured as one.
    readonly property var menuG: zenon.geom(root.themeName)
    // LIVE LYRICS. `times` are lrclib's cues in seconds, parallel to the lines
    // the view is already showing; `lyricFor` is the track they belong to, so a
    // stale set cannot highlight against a different song.
    property var lyricTimes: []
    property string lyricFor: ""
    property int lyricIndex: -1
    // When you last moved the cursor yourself. Auto-follow stands down for a
    // moment after that, so scrolling through a song does not turn into a fight
    // with the sync pulling the selection back every line.
    property double lastManualMove: 0
    // Where the cursor was in each list you have visited. rofi needed pos_key
    // because every menu was a new process with no memory; this needs it for the
    // opposite reason -- one long-lived view swaps its model out from under the
    // same ListView, and without this every revisit snaps back to the top.
    property var positions: ({})
    // Crumb length -> the navigation state that produced it. Clicking a step in
    // the trail restores the exact path that drew it, which is why this records
    // rather than computes: a qualified view ("AURORA > Albums") spends two
    // crumb parts on ONE path step, so counting parts backwards would overshoot.
    property var trailMap: ({})
    // The DEEPEST crumb reached on this trail, remembered so that stepping back
    // can still show what lies ahead. Only ever grows while you walk backwards;
    // any move that truncates the trail clears it.
    property var fullCrumb: []
    // ...and its root boundaries, so a ghosted jump still reads as a jump.
    property var fullRoots: []
    // What Alt+right would walk back into, as crumb parts. A prefix test rather
    // than an index calculation: one path step can spend two crumb parts
    // ("AURORA > Albums"), so counting parts would drift. If the remembered
    // crumb no longer starts with the current one, the trail branched and there
    // is nothing ahead worth claiming.
    readonly property var crumbAhead: {
        var cur = root.crumb || [], full = root.fullCrumb || []
        if (full.length <= cur.length) return []
        for (var i = 0; i < cur.length; i++) if (full[i] !== cur[i]) return []
        return full.slice(cur.length)
    }
    readonly property int followGraceMs: 2000

    // Identity of the list on screen: entry point plus the path walked into it.
    // Two different albums are two different lists; the same album reached twice
    // is the same one.
    function posKey() {
        return root.entryCmd + "|" + root.entryKey + "|" + JSON.stringify(root.path)
    }
    function rememberPos() {
        if (body.item && rows.count) root.positions[posKey()] = body.item.currentIndex
    }

    // ONE command for every draw there is -- a tile, a view, a step, a resume.
    // The engine replays the hops it is given, so "where am I" and "how did I
    // get here" are the same question with the same answer.
    function refresh(dir) {
        // The WHOLE trail, plus where along it we stand. Sending only the
        // active part would have the engine store a trail already trimmed, and
        // a warm start would come back with nothing ahead to walk into.
        // `tip` rides along so the ghosted part survives a restart too: the hop
        // list says something is AHEAD, but only the deepest crumb knows what it
        // is called, and re-deriving that would mean replaying to the tip and
        // back on every cold start.
        // Deeper unless a caller says otherwise, because most navigation is.
        root.navDir = (dir === undefined) ? 1 : dir
        swapIn.stop()
        // A draw held for the transition that is being replaced belongs to a
        // menu nobody is going to any more. Dropped rather than carried, or
        // swapOut would finish and apply it -- drawing the menu you just left on
        // your way somewhere else.
        root.heldDraw = null
        root.heldArt = []
        // NOTHING ANIMATES YET. A step is not a journey until the answer says so:
        // playing a track, liking one, saving an album all come back as the menu
        // you were already on. This used to start leaving after 90ms if no answer
        // had arrived -- and an answer that has to reach Spotify and back never
        // arrives that fast, so every play faded the list out and snapped it
        // back. That flash was the "refresh"; the rows themselves were never
        // rebuilt.
        //
        // render() starts the leaving half instead, once it knows there is
        // somewhere to leave for.
        root.beginDraw()
        // The id is kept because the ARTWORK for this draw is stamped with it --
        // see drawReq. Held in a local first so the callback can name the very
        // request it is answering.
        var id = root.call("nav", {hops: root.hops, pos: root.trailPos,
                                   tip: root.fullCrumb, tipRoots: root.fullRoots},
                           function (d) { root.drawReq = id; root.render(d) })
        root.drawIds[id] = true
    }
    // Already standing exactly there, with nothing walked into it. Jumping where
    // you are is not a jump, and appending it daisy-chains a root onto itself for
    // nothing -- Tab inside the trail menu could do that forever.
    function atRoot(cmd, key) {
        return root.entryCmd === cmd && root.entryKey === key && root.path.length === 0
    }
    // A NEW ROOT, appended rather than replacing: jumping to Search from three
    // levels down leaves those levels behind you, walkable.
    // They answer whether they actually went anywhere, so a caller that has
    // follow-up work for the new view can tell that there is a new view.
    function openTile(key)  {
        if (root.atRoot("open", key)) return false
        root.pushHop({cmd: "open", key: key});  root.refresh(); return true
    }
    function openView(name) {
        if (root.atRoot("view", name)) return false
        root.pushHop({cmd: "view", key: name}); root.refresh(); return true
    }
    // alt is Shift+Return: the engine turns it into Util.alt_pressed, which is
    // exactly what rofi's exit code does, so the view opens its action menu.
    // True while the Search view is showing its history and nothing has been
    // submitted: there, what you type is a QUERY, not a filter over the history.
    // rofi expressed this with `custom` on the menu; here it is one predicate.
    readonly property bool isSearchPrompt: root.entryKey === "search" && root.path.length === 0
    // WHAT YOU TYPE IS TEXT TO SUBMIT, not a filter over rows: the search box,
    // and the prompts that ask for a name (New Playlist, Rename Playlist).
    // Everywhere else -- search RESULTS included, since those are an ordinary
    // list once the query has been answered -- typing narrows what is on screen.
    //
    // Named rather than spelled out at each use: the filter, the message bar and
    // Backspace all have to agree about which kind of typing this is, and they
    // were agreeing by coincidence.
    readonly property bool composing: root.isSearchPrompt || root.promptFor.length > 0

    // WHERE THE PLAYING TRACK WAS PLAYED FROM -- the exact menu, not the album it
    // happens to belong to. Those are rarely the same place: a track played out
    // of Liked lives on an album you may never have opened, and one picked out of
    // a search result lives somewhere you reached by typing.
    //
    // Recorded as the trail itself rather than as a name, because that is what
    // Alt+c has to restore: a position to walk to if the list is still on the
    // trail, and a segment to re-enter if it is not.
    property string armOrigin: ""
    property string originId: ""
    property var originHops: []
    property int originPos: 0
    // Whether the recorded origin is still a prefix of where we are -- if it is,
    // going there is a walk along this trail rather than a new journey.
    function originOnTrail() {
        if (root.originPos > root.hops.length) return false
        for (var i = 0; i < root.originPos; i++) {
            if (JSON.stringify(root.hops[i]) !== JSON.stringify(root.originHops[i])) return false
        }
        return true
    }

    // THE SELECTION, ACKNOWLEDGED. Anything you pick flashes -- a track, a tile,
    // a verb in an action menu -- because the acknowledgement is of the PICK,
    // not of what the pick turned out to do. Half of them navigate and the
    // transition covers those; the other half act, and before this they did so
    // in total silence.
    //
    // A sequence number rather than a boolean: picking the same row twice is two
    // events, and a flag that is already true has no way to say so.
    property int flashSrc: -1
    property int flashSeq: 0
    function flashRow(i) {
        if (i < 0 || i >= rows.count) return
        root.flashSrc = rows.get(i).src
        root.flashSeq++
    }

    function activate(i, alt) {
        root.rememberPos()
        root.flashRow(i)
        if (root.entryCmd === "main" && !alt) {
            if (rows.count) root.openTile(rows.get(i).key)
            return
        }
        var src = (i >= 0 && i < rows.count) ? rows.get(i).src : (i + 1)
        // A prompt is waiting: what you typed IS the answer. Same string-step
        // mechanism the search box uses.
        if (root.promptFor.length) {
            root.pushHop({step: root.filter})
            root.promptFor = ""; root.setFilter(""); root.refresh()
            return
        }
        if (root.isSearchPrompt && root.filter.length) {
            // Free-typed text wins over the highlighted history row, exactly as
            // it does in rofi when custom input is enabled.
            root.pushHop({step: root.filter})
            root.setFilter(""); root.refresh()
            return
        }
        // THE ROW THIS STEP PICKED, remembered so a `copied` event coming back
        // has something to mark. By `src` -- its index in the unfiltered list --
        // rather than by position: the draw that follows clears the filter, so
        // the row moves, and only src stays put through that.
        root.lastSrc = src
        // ...and the cursor is remembered by src for the same reason. rememberPos
        // stored where the row was among the FILTERED ones, so picking the third
        // match of a search put the cursor on the third row of the whole list
        // once the filter cleared -- somewhere you had not been looking at.
        if (root.filter.length && src > 0) root.positions[posKey()] = src - 1
        // Lua is 1-based, and so are the indices rofi hands back.
        root.pushHop({step: alt ? {i: src, alt: true} : src})
        root.refresh()
    }
    // Hides rather than exits. The engine, the token and every warm cache stay
    // alive, so the next summon draws immediately instead of paying for a cold
    // start. Falls back to quitting if the host did not install a Shell -- that
    // is the case when main.qml is run straight from qml6 for UI work.
    // A ONE-SHOT ACTION IS NOT A PLACE. Albumart, Details, Copy Web Link and
    // friends produce a result and leave you on the menu you invoked them from,
    // so the step that triggered one must come straight back off the path.
    //
    // Leaving it on was a loop: the path is replayed on every refresh, so the
    // viewer reopened itself the moment anything else happened -- and closing it
    // only dismissed the overlay, never the step that kept summoning it.
    function cancelPrompt() { root.promptFor = ""; root.setFilter("") }

    function closeOverlay() {
        // LEAVING THE IMAGE VIEWER IS AN ARRIVAL. That viewer is the one overlay
        // that moves the panel -- it centres on the screen and comes back to the
        // bottom edge -- so dismissing it does not reveal the menu, it brings the
        // panel back to where the panel lives. Playing the open animation is what
        // that motion IS: the same expand-and-fade a summon uses, because from
        // where you are sitting it is the same event.
        //
        // Only this one. A sheet is drawn inside the panel and never moves it, so
        // closing one is a change of contents and the ordinary flow covers it.
        //
        // THE ORDER MATTERS. Clearing artPath re-anchors the panel to the bottom
        // and resizes it from the card to the menu, and that resize is animated
        // (see the Behavior on panel height). Animating the open at the same time
        // plays it on a panel that is still travelling, which reads as a slide
        // rather than a summon.
        //
        // So the panel is blanked, cleared, and animated once it has settled --
        // the resize happens at zero opacity and is never seen. This was written
        // for a slower version of the same problem, when the panel WAS the
        // surface and clearing artPath meant a re-anchor round trip through
        // Wayland; the delay outlives that because the resize outlives it too.
        // ...and only for the overlay that actually moved it. The listening card
        // never left the bottom edge (see root.artCentred), so there is no
        // journey back for the open animation to be, and replaying it there is a
        // panel flashing itself for nothing.
        var wasArt = root.artCentred
        if (wasArt) {
            openAnim.stop(); closeAnim.stop()
            root.collapsing = false
            root.opened = true
            root.showFactor = 0
        }
        root.sheet = ""
        root.sheetRows = []
        root.sheetKind = ""
        root.artPath = ""
        root.overlayTheme = ""
        // AND THE VIEW GOES BACK WHERE IT WAS. The card widened the panel while
        // it was up, so every column boundary moved and the cursor's row is no
        // longer where the scroll position says it is -- which reads as a list
        // showing two half-columns of text. Deferred, because the panel's width
        // and height are still settling in this same frame.
        Qt.callLater(root.snapToCursor)
        if (wasArt) reopenDelay.restart()
    }
    // Long enough for the compositor to have re-anchored and resized the surface,
    // short enough to read as one movement rather than two. A guess at a number
    // the compositor does not report -- but a safe one in the direction that
    // matters: the panel is invisible until this fires, so being late costs a
    // few frames of nothing, where being early costs the whole animation.
    Timer {
        id: reopenDelay
        interval: 110
        onTriggered: openAnim.restart()
    }

    // Overlays (art, sheets) arrive as EVENTS, before the response that carries
    // `keep`. Dropping the step that opened one immediately is what stops the
    // viewer re-summoning itself on the next refresh.
    function snapToCursor() {
        var v = body.item
        if (v && v.snap && v.currentIndex >= 0) v.snap(v.currentIndex)
    }

    function popTransient() {
        if (root.trailPos <= 0) return
        root.hops = root.hops.slice(0, root.trailPos - 1)
        root.trailPos = root.hops.length
    }

    // OPENING AND CLOSING, as one gesture. 0 is gone, 1 is here; the panel reads
    // both its scale and its opacity off it, so it expands and fades together
    // rather than doing one and then the other.
    //
    // Cold and warm are the same animation on purpose -- from the outside they
    // are the same act, and a resident process that reappeared differently from
    // a fresh one would only be advertising its own plumbing.
    //
    // ONE value, not two. Scale and opacity were split when the open overshot,
    // because opacity has nowhere to go past 1 -- Qt clamps it -- so a single
    // factor would have spent the whole overshoot on scale. With no overshoot
    // there is nothing to split: the two move together on the same curve, and
    // two properties saying so would be one property said twice.
    property real showFactor: 0
    // Which way this one is going. Opening expands: a small, even growth out of
    // the bottom edge. Closing COLLAPSES: it folds down into that same edge,
    // mostly vertically and barely at all sideways, which is a different move
    // rather than the first one run backwards -- Escape should not look like a
    // summon in reverse.
    //
    // Both still ride the one animated value, so the two halves cannot drift
    // apart in timing; only where they start and end differs.
    property bool collapsing: false
    // The fold is gentler than it was, for the same reason as the curve: 0.72 in
    // 140ms is a lurch however it is eased. Far enough to read as folding into
    // the edge, not so far that the last frames are a blur.
    readonly property real panelX: root.collapsing ? 0.985 + 0.015 * root.showFactor
                                                   : 0.94 + 0.06 * root.showFactor
    readonly property real panelY: root.collapsing ? 0.82 + 0.18 * root.showFactor
                                                   : 0.90 + 0.10 * root.showFactor
    // Guards against replaying the open on a redraw, and against the first cold
    // reveal being missed: `Shell` is handed to QML after the file has loaded, so
    // whichever of the two triggers below arrives first is the one that opens it.
    property bool opened: false
    // Out of the bottom edge and up to full size, fading as it goes, and no
    // further -- it arrives and stops. Longer than the close: arriving is worth
    // watching, leaving is not.
    NumberAnimation {
        id: openAnim
        target: root; property: "showFactor"
        to: 1; duration: 200; easing.type: Easing.OutCubic
    }
    // InOutSine, not InCubic. Same 140ms -- the collapse was not too slow, it was
    // too abrupt at both ends: InCubic leaves at a standstill and then snaps out
    // at full speed, so the fold started with a jolt and stopped with one. An
    // eased-in-and-out curve has no hard edge at either end, which is the whole
    // of what makes a short move read as smooth rather than as a cut.
    NumberAnimation {
        id: closeAnim
        target: root; property: "showFactor"
        to: 0; duration: 140; easing.type: Easing.InOutSine
        // The surface goes away only once the animation has played. Hiding first
        // and animating after would animate nothing, in a window nobody can see.
        onFinished: if (typeof Shell !== "undefined") Shell.conceal()
    }
    function showPanel() {
        root.opened = true
        root.collapsing = false
        closeAnim.stop()
        // From the bottom of the curve every time. Restarting without this would
        // begin wherever a half-finished close had left it.
        root.showFactor = 0
        openAnim.restart()
    }
    Connections {
        target: typeof Shell !== "undefined" ? Shell : null
        // Every summon, cold or warm: the host calls reveal() for both.
        function onRevealed() { root.showPanel() }
        // `spoot --listen` at a shell that is already resident. A SIGNAL rather
        // than the startView property it used to re-set, because only bootstrap
        // read that and bootstrap runs once -- so the flag worked on a cold start
        // and never again. See Shell::askListen.
        function onListen() { root.openListen() }
    }
    // Appended as a root like any other jump, so the trail you were on is still
    // behind you and Alt+left walks back into it. Nothing happens if you are
    // already standing there, which is what makes pressing the keybind twice
    // harmless rather than a second thirty-second recording.
    function openListen() { root.openView("listen") }

    function dismiss() {
        // HIDE ONLY. Going home first sent `main`, which resets the session
        // stack to empty -- so every Escape quietly destroyed the very thing a
        // warm start restores from, and re-summoning always landed on Main.
        // Leaving the view alone means the next reveal shows exactly where you
        // were, and the stack on disk stays deep for a real cold start.
        if (typeof Shell === "undefined") { Qt.quit(); return }
        root.opened = false
        root.collapsing = true
        openAnim.stop(); closeAnim.restart()
    }
    // Jump to a step in the trail. `n` is a crumb length, so part 0 ("Main") is
    // n=1. Anything we have stood at is restorable exactly; anything else falls
    // back to home rather than guessing.
    function jumpToCrumb(n) {
        if (n >= root.crumb.length) return          // already there
        var pos = root.trailMap[n]
        // A cursor, not a destination -- so a click behaves exactly like holding
        // Alt+left that many times, trail and all.
        if (pos === undefined || pos > root.hops.length) { if (n <= 1) root.goHome(); return }
        root.rememberPos(); root.trailPos = pos; root.refresh(-1)
    }

    // JUMPING to Main is a new root like any other: it appends, so Alt+left
    // still walks back into wherever you were. It is a destination, not an
    // undo -- clearing the trail is what Alt+delete is for.
    function openMain() {
        if (root.atRoot("main", "")) return
        root.pushHop({cmd: "main", key: ""}); root.refresh()
    }

    // CLEARS the trail -- "alt delete / clear session", and the fallback for
    // anything that finds itself without a trail to stand on.
    function goHome() {
        root.hops = []; root.trailPos = 0
        root.fullCrumb = []; root.fullRoots = []
        root.trailMap = ({})
        root.refresh(-1)
    }

    // Walking the trail. Non-destructive in both directions -- what is ahead of
    // the cursor stays there until you go somewhere new.
    function trailBack() {
        // At Main there is nothing behind. A navigation key does not exit --
        // Escape and Backspace are the ways out.
        if (root.trailPos <= 0) return
        root.rememberPos(); root.trailPos -= 1; root.refresh(-1)
    }
    function trailForward() {
        if (root.trailPos >= root.hops.length) return
        root.rememberPos(); root.trailPos += 1; root.refresh()
    }
    function setFilter(f) { root.filter = f; root.applyFilter() }
    function activateCurrent(alt) {
        if (rows.count && body.item) { root.activate(body.item.currentIndex, alt === true); return }
        // NO ROWS IS NOT NOTHING TO DO. The search box lists past queries, and on
        // a cache that has none it has no rows at all -- so requiring one under
        // the cursor made Return do nothing there, and the only way to get a
        // first history entry is to search. Search was unusable until it had
        // already been used.
        //
        // Composing is exactly the state where what you typed is the answer
        // rather than a filter over rows, so it is also exactly the state where
        // there needing to BE a row is a misreading. See root.composing.
        if (root.composing && root.filter.length) root.activate(-1, alt === true)
    }
    // dx moves within a row, dy between rows. A list is one column wide, so dy
    // is the only axis that means anything there -- which is also how rofi
    // behaves in a list versus a grid.
    function move(dx, dy) {
        if (!body.item || rows.count === 0) return
        root.lastManualMove = Date.now()
        // Yours to steer: instant. See RowList.glideMs.
        if (body.item.glideMs !== undefined) body.item.glideMs = 0
        var cols = root.columns
        var n = rows.count
        var i = body.item.currentIndex + dx + dy * cols
        // WRAPS, but only for a single step. Off the bottom comes back to the
        // top and off the top to the bottom, which is what a list of a few rows
        // wants and what holding Down through a long one expects at the end.
        //
        // A PAGE does not wrap: Page Down near the end means "as far as that
        // goes", and landing back at row 1 from a key that means "further on" is
        // the opposite of what was asked.
        if (Math.abs(dx) + Math.abs(dy) === 1) {
            if (i < 0) i = n - 1
            else if (i >= n) i = 0
        }
        body.item.currentIndex = Math.max(0, Math.min(n - 1, i))
    }
    // A PAGE, not three rows. `lines` is what the theme says fits on screen, and
    // move() multiplies by the column count itself, so this is one screenful in
    // a list and one in a grid without either being spelled out here.
    function page(dir) {
        root.move(0, dir * Math.max(1, root.menuG.lines))
    }
    function moveTo(i) {
        root.lastManualMove = Date.now()
        if (!body.item) return
        if (body.item.glideMs !== undefined) body.item.glideMs = 0
        body.item.currentIndex = (i < 0 ? rows.count - 1 : i)
    }
    function control(action, by) {
        var a = {action: action}
        if (by !== undefined) a.by = by
        // The reply carries fresh playback state, so the bar and the markers
        // update from the action itself rather than on the next poll.
        root.call("control", a, function (p) { root.playback = p || ({}) ; root.syncPos(p) })
    }
    // Named so a keymap test says which phase a binding is waiting on, instead
    // of the key appearing broken.
    // Alt+c: put the cursor on the row that is playing. Done HERE rather than in
    // the engine because the answer is already on screen -- format_entries marks
    // the playing row with the transport glyph, so the row that wears it is the
    // row to jump to. No request, no round trip.
    // Puts the cursor on the row the engine marked as playing, if it drew one.
    // format_entries wears the transport glyph on that row in every list where
    // the track appears, so the row that has it is the row to move to -- no
    // request, no round trip.
    // Which row wears the transport glyph, or -1. format_entries marks the
    // playing row in every list the track appears in, so this doubles as the
    // test for "is the playing track in this list at all" -- which is what makes
    // a list an origin worth remembering.
    // Which row IS the playing track, by id. It used to hunt for the transport
    // glyph in the row's text, which meant the answer could only change when the
    // text did -- that is, when the whole menu was rebuilt. It also matched
    // Main's Playback tile, which is LABELLED with what is playing without being
    // it.
    function playingRowIndex() {
        var id = root.playback.id || ""
        if (!id.length) return -1
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).id === id) return i
        }
        return -1
    }
    function cursorToPlaying() {
        if (!body.item || !rows.count) return false
        var i = root.playingRowIndex()
        if (i < 0) return false
        root.lastManualMove = Date.now()
        body.item.currentIndex = i
        // Straight there, not glided. A jump you asked for inside the menu you
        // are already in is a cursor move, and animating one is just a slower
        // cursor. The glide belongs to the synced lyric advancing on its own,
        // which is a thing happening TO the view.
        body.item.positionViewAtIndex(i, ListView.Contain)
        root.rememberPos()
        return true
    }
    // Set while a draw is on its way BECAUSE of Alt+c, so the cursor lands on the
    // playing row of the view it opens rather than wherever that view was left.
    property bool seekPlaying: false
    // ALT+C, UNIVERSAL. One key, one meaning, everywhere: take me to what is
    // playing. rofi could express only the first of these three, and only in the
    // views whose loops had been wired for it by hand.
    //
    //   1. It is on screen -- move the cursor to it.
    //   2. Its list is somewhere on the trail -- WALK there, exactly as Alt+left
    //      or Alt+right would. This is the one that matters: the list a track
    //      came from is usually a place you have already been, and opening a
    //      second copy of it as a new root would leave the first one dangling
    //      behind you and the trail describing a journey nobody took.
    //   3. Nowhere on the trail -- open its album as a new root, which is the
    //      only honest thing left.
    //
    // The whole trail is searched, not just the part behind the cursor: the list
    // may be AHEAD of where you are standing, and walking forward to it is as
    // valid as walking back. Searched from the far end so the most recent visit
    // wins when a list appears on the trail twice.
    function jumpToPlaying() {
        if (root.cursorToPlaying()) return
        // THE EXACT LIST IT WAS PLAYED FROM -- recorded when it started playing,
        // because nothing can work it out afterwards. Matching on the album it
        // belongs to was the wrong question: a track played out of Liked or out
        // of a search result belongs to an album you may never have opened.
        if (root.originId.length && root.originId === (root.playback.id || "")) {
            root.rememberPos()
            root.seekPlaying = true
            if (root.originOnTrail()) {
                // Still on this trail: a walk, exactly as Alt+left or Alt+right
                // would be, and nothing behind or ahead of you is disturbed.
                var back = root.originPos < root.trailEnd()
                root.trailPos = root.originPos
                root.refresh(back ? -1 : 1)
                return
            }
            // GONE FROM THE TRAIL -- branched away from since. The list is
            // re-entered as a NEW ROOT, rebuilt from the segment that led to it:
            // its own root hop and the steps taken inside it, so what opens is
            // that list and not merely something with the same name.
            var r = -1
            for (var i = root.originPos - 1; i >= 0; i--) {
                if (root.originHops[i] && root.originHops[i].cmd) { r = i; break }
            }
            if (r >= 0) {
                var hs = root.activeHops()
                for (var j = r; j < root.originPos; j++) hs.push(root.originHops[j])
                root.hops = hs
                root.trailPos = hs.length
                root.fullCrumb = []; root.fullRoots = []
                root.refresh()
                return
            }
            root.seekPlaying = false
        }
        // NEVER PLAYBACK. This key means one thing -- take me to the track -- and
        // Playback is a menu of verbs, not the place the track lives; landing
        // there is the key quietly doing something else. With nothing recorded
        // there is no answer, so it says so rather than inventing one.
        root.notify("Nowhere to jump to \u2014 nothing is playing from a list")
    }

    // DELETE, where it means something. The engine reports which menus claim the
    // key -- the search history and the trail history, the two that hold records
    // rather than places -- so the binding is offered exactly there instead of
    // being sent blind into a list that would read it as an ordinary Return and
    // navigate. It is a path step like any other, with a flag on it, the same
    // shape Shift+Return uses.
    property bool canDelete: false
    // ...and whether Tab belongs to the menu on screen. Two claim it -- the trail
    // menu cycles Trail Steps against Trail History, the search results cycle
    // their type picker -- and everywhere else Tab opens the trail menu. Same
    // shape as canDelete, and for the same reason: the engine knows which menus
    // claim a key, so the UI never has to guess from a view's name.
    property bool canTab: false
    function tabHere() {
        if (!root.canTab || !body.item || !rows.count) return root.openView("trail-jump")
        root.rememberPos()
        root.pushHop({step: {i: rows.get(body.item.currentIndex).src, tab: true}})
        root.refresh()
        return true
    }
    function deleteEntry() {
        if (!root.canDelete || !body.item || !rows.count) {
            root.notify("Nothing to delete here")
            return
        }
        root.rememberPos()
        root.pushHop({step: {i: rows.get(body.item.currentIndex).src, del: true}})
        root.refresh()
    }
    function goBack() {
        root.rememberPos()
        // DESTRUCTIVE, unlike trailBack: this removes the step rather than
        // stepping over it, so there is nothing to walk forward into.
        //
        // Standing mid-trail, the first press spends itself on the part ahead:
        // that stretch is what you walked back out of, and cutting it is the
        // more likely intent than deleting the step under you while a forward
        // path still dangles off it. The view does not change -- only what
        // Alt+right could still reach. The NEXT press then removes a step, as
        // it always does.
        if (root.trailPos < root.hops.length) {
            root.hops = root.activeHops()
            root.fullCrumb = []; root.fullRoots = []
            return
        }
        if (root.trailPos > 0) {
            // May remove a ROOT hop, which lands you on the tip of the segment
            // before it -- the trail reads as one walk, so it unwinds as one.
            root.hops = root.hops.slice(0, root.trailPos - 1)
            root.trailPos = root.hops.length
            root.fullCrumb = []; root.fullRoots = []
            root.refresh(-1)
        }
        else root.dismiss()
    }

    // --- live playback -------------------------------------------------------
    // One request a second for the truth, sixty frames a second for the motion.
    property real progress: 0
    property real positionMs: 0
    property real posAtPoll: 0
    property double polledAt: 0

    // m:ss, the way every player writes it. Presentation, so it lives here
    // rather than in the engine.
    function clock(ms) {
        if (!ms || ms < 0) ms = 0
        var t = Math.floor(ms / 1000)
        var m = Math.floor(t / 60)
        var sec = t % 60
        return m + ":" + (sec < 10 ? "0" : "") + sec
    }

    // The line for the current instant. Runs off positionMs, so it advances on
    // the same 60fps clock the fill does rather than on the 1Hz poll -- a line
    // lands when it is sung, not up to a second later.
    function syncLyrics() {
        if (!root.lyricTimes.length) return
        // Only for the track the cues belong to: skipping to the next song must
        // not leave the previous song's lines marching along.
        if (root.playback.id !== root.lyricFor) { root.lyricIndex = -1; return }
        var t = root.positionMs / 1000
        var i = -1
        for (var k = 0; k < root.lyricTimes.length; k++) {
            if (root.lyricTimes[k] <= t) i = k; else break
        }
        if (i === root.lyricIndex) return
        root.lyricIndex = i
        if (!body.item || i < 0) return
        // Hands off while you are steering. The grace window restarts on every
        // manual move, so holding an arrow key never gets yanked back mid-scroll.
        if (Date.now() - root.lastManualMove < root.followGraceMs) return
        // The one move that glides. A line becoming the sung one is continuous
        // -- the song did not cut to it -- so the highlight travels to it and
        // the list scrolls with it, at the same pace. Raised here rather than
        // set on the view, so every other way the cursor moves stays instant.
        if (body.item.glideMs !== undefined) body.item.glideMs = 220
        body.item.currentIndex = i
        if (body.item.followTo) body.item.followTo(i)
        else body.item.positionViewAtIndex(i, ListView.Contain)
    }

    // HOW FAR IN WE ARE, corrected once a second against the player itself.
    //
    // The correction used to be applied whatever it said, and playerctl's answer
    // wobbles by a few tens of milliseconds from one poll to the next -- so the
    // fill was nudged backwards and forwards every second and the clock beside
    // it flickered between two values on the boundary. Nothing was wrong with
    // the position; the reading of it was noisy.
    //
    // A small disagreement is therefore believed but not moved to: the
    // interpolator carries on from where it already was, so the fill never steps
    // sideways. A LARGE one is real -- a seek, a track change, a pause that
    // happened somewhere else -- and still snaps, because that is the truth
    // arriving rather than noise about it.
    //
    // Deliberately NOT a Behavior on the fill's width. That width is rewritten
    // sixty times a second, and easing a value which is already continuous only
    // adds lag to it.
    readonly property int posSlackMs: 400
    function syncPos(p) {
        var pos = p && p.position ? p.position : 0
        var now = Date.now()
        if (root.playback.playing === true && root.polledAt > 0) {
            var expected = root.posAtPoll + (now - root.polledAt)
            if (Math.abs(expected - pos) < root.posSlackMs) {
                root.posAtPoll = expected
                root.polledAt = now
                return
            }
        }
        root.posAtPoll = pos
        root.polledAt = now
    }

    Timer {
        interval: 1000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.call("playback", {}, function (p) {
            root.playback = p || ({})
            root.syncPos(p)
            // NOTHING IS ASKED OF THE ENGINE WHEN THE TRACK CHANGES. The marker
            // and the cover are both bound to root.playback, so autoplay moving
            // on repaints two rows and one picture and touches nothing else. A
            // redraw stood here, and it was the last rofi-shaped thing in the
            // hot path: rebuilding a menu of 672 rows in Lua to say that a
            // marker had moved one row down.
        })
    }
    Timer {
        // The interpolator. Nothing is asked of the engine here at all -- the
        // fill and the clock advance from the last known position and the wall
        // clock, which is what makes them smooth over a 1Hz truth.
        interval: 16; running: root.playback.playing === true; repeat: true
        onTriggered: {
            var dur = root.playback.duration || 0
            if (dur <= 0) { root.progress = 0; return }
            var pos = root.posAtPoll + (Date.now() - root.polledAt)
            root.positionMs = Math.max(0, Math.min(dur, pos))
            root.progress = Math.max(0, Math.min(1, pos / dur))
            root.syncLyrics()
        }
    }

    Component {
        id: gridView
        TileGrid {
            theme: zenon
            model: rows
            flashSrc: root.flashSrc
            flashSeq: root.flashSeq
            playingId: root.playback.id || ""
            playingAlbumId: root.playback.albumId || ""
            paused: root.playback.playing !== true
            columns: root.columns
            // NOT while composing: there the typing is a query, and applyFilter
            // deliberately leaves the rows alone, so there is nothing on screen
            // that matched it.
            filter: root.composing ? "" : root.filter
            focus: false
        }
    }
    Component {
        id: listView
        RowList {
            theme: zenon
            model: rows
            columns: root.columns
            rowHeight: zenon.rowHeight
            activeIndex: root.lyricIndex
            copiedSrc: root.copiedSrc
            flashSrc: root.flashSrc
            flashSeq: root.flashSeq
            playingId: root.playback.id || ""
            paused: root.playback.playing !== true
            // Per-theme, with ZENON's defaults where a theme says nothing.
            centered: root.menuG.center === true
            rowSize: root.menuG.rowSize || zenon.fontSize
            rowWeight: root.menuG.rowWeight || zenon.fontWeight
            // See TileGrid above: the search box and the name prompts type a
            // QUERY, and nothing in the list behind them matched it.
            filter: root.composing ? "" : root.filter
            focus: false
        }
    }

    // EVERYTHING VISIBLE, so that opening and closing can be one gesture. The
    // panel grows out of the bottom edge and fades up as it goes, and Escape
    // plays it backwards -- transformOrigin Bottom because the surface is
    // anchored south, so the edge it is attached to is the edge it should
    // appear to come out of.
    //
    // A wrapper rather than the same two lines on the ground, the column and
    // both overlays: they have to move together or the animation is four
    // animations that happen to agree.
    //
    // The keymap deliberately stays OUTSIDE it -- input is not a visual, and a
    // half-faded panel must still answer the key that is closing it.
    // CLICK AWAY TO CLOSE. Under the panel and across the whole output, which is
    // the only place this could be: pointer events stop at the edge of a surface,
    // so a menu-sized window never hears the click that dismissed it.
    //
    // Bounds-checked rather than relying on stacking. The panel's ground is a
    // plain Rectangle, and an Item that does not take mouse events lets them fall
    // straight through to whatever is beneath -- so without this test, clicking
    // the panel's own padding would close it.
    MouseArea {
        id: outside
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: function (m) {
            var p = outside.mapToItem(panel, m.x, m.y)
            if (p.x < 0 || p.y < 0 || p.x > panel.width || p.y > panel.height)
                root.dismiss()
        }
    }

    Item {
        id: panel
        // A structured sheet sizes the panel to ITSELF; every other view takes
        // the width its theme declares. Clamped to the screen so a pathological
        // value cannot push it off.
        // The image viewer widens it to whatever the picture needs, because the
        // picture is a fixed size and the panel is not: art.rasi says the window
        // is 1000 and the icon is 1000, which cannot both be true once the frame
        // around it is drawn. The frame is what gives, and the panel grows by it.
        width: root.sheetRows.length
               ? Math.min(keySheet.naturalWidth + zenon.sheetPad * 2, Screen.width - 80)
               : root.artPath.length
                 ? Math.min(Screen.width - 40, artCard.width + zenon.borderWidth * 2)
                 : root.g.width
        // A sheet is still a panel and sizes to itself. The art viewer is a card
        // ON the menu, so the panel only has to grow enough to hold it -- and
        // when the menu is already taller, it does not grow at all.
        height: root.artPath.length
                ? Math.max(root.menuHeight, artCard.height + zenon.messagePadV * 4)
                : (root.overlayUp ? root.bodyHeight + zenon.borderWidth : root.menuHeight)
        // IT RESIZES SMOOTHLY between menus of different heights. It used to
        // snap, at the instant the held draw was applied -- which is invisible
        // going to a TALLER menu, because the panel grows into space that was
        // empty anyway, and obvious going to a shorter one, where everything
        // below the body jumps up while the body is still fading in over it.
        //
        // Matched to the incoming half of the transition, so the panel finishes
        // arriving at the same moment its contents do.
        Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        // WHERE IT SITS. Docked south for a menu -- that is ZENON's whole layout,
        // a panel rising off the bottom edge -- and centred on the output for the
        // image viewer, which is a thing you look AT rather than a thing you
        // reach for. Both are plain anchors now; this used to be a call into the
        // host asking the compositor to re-anchor the SURFACE, which took long
        // enough that the exit animation played before it landed.
        // artCentred, not artPath: the listening card is an image overlay too and
        // sizes the panel like one, but it does not MOVE it. See root.artCentred.
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: root.artCentred ? parent.verticalCenter : undefined
        anchors.bottom: root.artCentred ? undefined : parent.bottom
        // Anchored south, so the edge it is attached to is the edge it grows
        // out of and folds back into. Scale rather than `scale:` because the two
        // axes move by different amounts on the way out -- see panelX/panelY.
        transform: Scale {
            origin.x: panel.width / 2
            origin.y: panel.height
            xScale: root.panelX
            yScale: root.panelY
        }
        opacity: root.showFactor
        // --- the panel (ZENON `window`) -----------------------------------------
        Rectangle {
            anchors.fill: parent
            color: zenon.ground
            radius: zenon.radius
            border.width: zenon.borderWidth
            border.color: zenon.borderCol
            // radius rounds all four corners; ZENON rounds only the top pair, so the
            // bottom is squared off again by a strip of the same colour.
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: zenon.radius
                color: zenon.ground
            }
        }

        Column {
            anchors.fill: parent
            // Inside the border, not on it. ZENON draws a 1px frame with rounded top
            // corners; content laid flush to the window edge painted over it, which
            // showed as the album cover clipping the frame on the left.
            anchors.margins: zenon.borderWidth

            // --- input bar (ZENON `inputbar`, search.rasi) ----------------------
            //
            // FIRST in the column, because search.rasi orders its mainbox
            // [inputbar, message, listview] and every theme that has one puts it
            // above the message bar. Drawn only where the theme leaves it enabled --
            // which is search and nothing else, see Theme.glyphSearch.
            //
            // What you type in the search box is a QUERY, not a filter over the
            // history rows behind it, and until now it had nowhere to appear except
            // the message bar, where it read as a filter with a match count after
            // it. This is the field it always belonged in.
            Item {
                id: inputBar
                width: parent.width
                visible: root.themeName === "search"
                height: visible ? Math.max(promptGlyph.implicitHeight,
                                           entryText.implicitHeight) + zenon.entryPad * 2
                                : 0
                Text {
                    id: promptGlyph
                    anchors { left: parent.left; leftMargin: zenon.promptPadL
                              verticalCenter: parent.verticalCenter }
                    text: zenon.glyphSearch
                    color: zenon.playing
                    font { family: zenon.fontFamily; pointSize: zenon.promptSize
                           weight: Font.DemiBold }
                }
                Text {
                    id: entryText
                    anchors { left: promptGlyph.right; leftMargin: zenon.promptPadR
                              verticalCenter: parent.verticalCenter }
                    // As wide as the text needs and no wider, so the caret can sit
                    // against its end rather than at a fixed stop. Sized rather than
                    // anchored on both sides because the caret anchors to THIS, and
                    // anchoring the two to each other is a loop.
                    width: Math.min(implicitWidth,
                                    inputBar.width - promptGlyph.width - zenon.promptPadL
                                    - zenon.promptPadR - zenon.entryPad - caretWidth - 4)
                    readonly property int caretWidth: 2
                    text: root.filter
                    color: zenon.playing
                    // From the LEFT, so the end you are typing at is the end you can
                    // still see once a query outgrows the field.
                    elide: Text.ElideLeft
                    font { family: zenon.fontFamily; pointSize: zenon.entrySize
                           weight: Font.DemiBold }
                }
                // rofi drew a cursor here and ZENON never styled it, so it takes the
                // entry's own colour and height. It is what says "type" when the
                // field is empty, which is the whole state the search box opens in.
                Rectangle {
                    id: caret
                    anchors { left: entryText.right; leftMargin: 2
                              verticalCenter: parent.verticalCenter }
                    width: entryText.caretWidth
                    height: entryText.implicitHeight - 2
                    color: zenon.playing
                    visible: inputBar.visible
                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        running: inputBar.visible
                        NumberAnimation { from: 1; to: 0; duration: 500
                                          easing.type: Easing.InOutQuad }
                        NumberAnimation { from: 0; to: 1; duration: 500
                                          easing.type: Easing.InOutQuad }
                    }
                }
            }

            // --- message bar (ZENON `message`) ---------------------------------
            //
            // A Column inside an Item, rather than one Rectangle whose height was
            // added up from its children by hand. That arithmetic worked, but it
            // read the heights of items that were ANCHORED BACK to it, and Qt saw
            // message.height depending on message.height and abandoned the
            // binding -- leaving the bar whatever size it happened to be when the
            // loop was cut, which is how a trail with three steps in it drew no
            // trail at all.
            //
            // A positioner has no such problem: it sizes itself from what is in
            // it, its children take their WIDTH from it and nothing takes a
            // height back. Each line still pays for its own height -- an empty
            // caption occupies nothing, which is what keeps a blank row from
            // appearing above the trail on Main, where there is no caption to
            // have.
            Item {
                id: message
                width: parent.width
                readonly property bool hasMesg: messageText.text.length > 0
                height: msgCol.height
                // NO `visible: height > 0`. In Qt Quick an item's `visible`
                // reports its EFFECTIVE visibility, so a false parent makes every
                // child read false too -- and this bar's height is added up from
                // whether its children are visible. That closes into a state that
                // sustains itself: nothing to show, so hide; hidden, so the
                // children report nothing to show. It could only be escaped by
                // there happening to be a caption, which is why the trail
                // vanished on exactly the views that have none.
                //
                // A bar with nothing in it is already invisible: its column is
                // zero high and the ground behind it fills a zero-high item.
                // Saying so twice was what broke it.
                Rectangle {
                    anchors.fill: parent
                    color: zenon.messageBg
                    // TOP RULE TOO, under the input bar. ZENON gives the message
                    // bar a bottom border and search.rasi alone overrides it to
                    // `1px 0px 1px 0px` -- because search is the one menu with
                    // something ABOVE this bar, and without the rule the field
                    // and the caption ran into each other as one block.
                    Rectangle {
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: 1
                        color: zenon.separator
                        visible: inputBar.visible
                    }
                    Rectangle {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 1
                        color: zenon.separator
                    }
                }
                Column {
                    id: msgCol
                    width: parent.width
                    // From the CONTENT, never from message.visible: that is
                    // derived from this column's height, so asking it here would
                    // be the same loop again in a smaller circle -- and it
                    // resolves to "nothing to show", which is a bar that never
                    // appears rather than one that misbehaves.
                    topPadding: (messageText.visible || crumbRow.visible) ? zenon.messagePadV : 0
                    bottomPadding: topPadding
                    spacing: 0
                Text {
                    id: messageText
                    visible: message.hasMesg
                    // Inside the padding and ELIDED. It was neither: given the
                    // column's full width with nothing to stop it, a long
                    // caption -- the playing track's name and every artist on it
                    // -- ran off both edges of the panel. ZENON truncates the
                    // same line for the same reason (truncate_text, 49 chars).
                    x: zenon.messagePadH
                    width: msgCol.width - zenon.messagePadH * 2
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    // What you typed wins over what the view is called: while
                    // filtering, the thing you want to see is your own query.
                    //
                    // Unless there is a field for it. With the input bar up the
                    // query has a home of its own, and echoing it here as well --
                    // with a match count against rows it does not even filter --
                    // was the message bar standing in for a widget that was missing.
                    text: inputBar.visible
                          ? root.viewMesg
                          : root.promptFor.length
                            ? (root.promptFor + "  \u203a  " + root.filter)
                            : (root.filter.length ? (root.filter + "  \u2500  " + rows.count)
                                                  : root.viewMesg)
                    color: zenon.playing
                    font.family: zenon.fontFamily
                    font.pointSize: zenon.fontSize
                    font.bold: true
                }

                // THE TRAIL. rofi could only put this in the same one-line mesg as
                // everything else; here it is its own line, dim, with the arrows
                // darker than the names so the names read first -- which is exactly
                // what Util.crumb_arrow does in the rofi build.
                // THE TRAIL, as chrome rather than a menu. rofi could only draw it
                // as a line of text and needed a separate window to navigate it;
                // here every step is a control -- click one and you are there.
                //
                // It spans the bar and centres itself rather than being a narrow item
                // centred in it, because those are the same thing on one line and only
                // the first stays centred once a long daisy chain wraps.
                Text {
                    id: crumbRow
                    // Width from the column, height its own. A wrapping Text with
                    // a fixed width already reports the WRAPPED height as its
                    // implicit one, so the column adds up the right number
                    // without this having to state it -- and without the cycle
                    // that stating it used to cost.
                    x: zenon.messagePadH
                    width: msgCol.width - zenon.messagePadH * 2
                    // A single part is the name of the menu already on screen --
                    // nothing a trail could tell you. No trail, no bar.
                    visible: (root.crumb || []).length > 1 || root.crumbAhead.length > 0
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    textFormat: Text.RichText
                    text: root.crumbHtml
                    font { family: zenon.fontFamily; pointSize: zenon.fontSize; bold: true }
                    // Hit-tested rather than laid out as separate items: linkAt asks
                    // the same text engine that drew the chain which step is under the
                    // pointer, so hover and click agree with what you can see even
                    // mid-wrap.
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: root.crumbHover >= 0 ? Qt.PointingHandCursor
                                                          : Qt.ArrowCursor
                        function stepAt(x, y) {
                            var l = crumbRow.linkAt(x, y)
                            return l.length ? parseInt(l) : -1
                        }
                        onPositionChanged: function (m) { root.crumbHover = stepAt(m.x, m.y) }
                        onExited: root.crumbHover = -1
                        onClicked: function (m) {
                            var n = stepAt(m.x, m.y)
                            if (n >= 0) root.jumpToCrumb(n + 1)
                        }
                    }
                }
                }
            }

            // --- the current view ------------------------------------------------
            // An Item around the Row purely so the loading sweep and the corners
            // have somewhere to live: a Row positions everything you put in it,
            // and both of those sit ACROSS the body rather than beside the cover.
            Item {
            id: bodyArea
            width: parent.width
            height: root.bodyHeight

            Row {
                anchors.fill: parent
                spacing: 0
                // The menu transition. The chrome around it deliberately holds
                // still: only what CHANGED between the two menus moves.
                transformOrigin: Item.Center
                scale: root.bodyZoom
                opacity: root.bodyFade

                // Only a list gets a cover beside it: a grid already shows the
                // artwork of everything in it, and an action menu is the one view
                // whose subject is otherwise invisible.
                Item {
                    id: contextCover
                    // NO BACKDROP where the menu is not about a track. The
                    // playing track's cover beside Liked says "this is what is
                    // playing out of this list"; beside System or the trail menu
                    // it says nothing at all, and a picture that means nothing is
                    // just a picture in the way.
                    //
                    // Lyrics are the same case for a different reason: the words
                    // ARE the track, so restating it in a picture beside them
                    // only narrows the column they are read in.
                    // Search is the same case again: a box you are typing a
                    // query into is not about a track, and the cover of whatever
                    // happens to be playing beside it is decoration.
                    //
                    // Those four are KINDS of view. A single menu inside a view
                    // that does wear a cover can say the same of itself, and
                    // says it on the draw rather than being named again here --
                    // see root.noCover.
                    readonly property bool wanted:
                        root.coverArt.length > 0 && root.layout === "list"
                        && !root.noCover
                        && root.themeName !== "trail" && root.themeName !== "search"
                        && root.scope !== "system" && root.scope !== "lyrics"
                    width: wanted ? root.bodyHeight : 0
                    height: root.bodyHeight
                    visible: width > 0
                    // TWO IMAGES, so one cover can give way to the next instead
                    // of blinking out and back. The lower one holds whatever is
                    // already on screen; the upper one loads the new cover behind
                    // it at zero opacity and fades up once it is ready, and only
                    // then does the lower one take the same source -- which costs
                    // nothing, it is the same file and it is cached.
                    //
                    // A single Image cannot do this: changing `source` drops it to
                    // Loading, and there is nothing left underneath to look at.
                    Image {
                        id: coverUnder
                        anchors.fill: parent
                        asynchronous: true
                        cache: true
                        fillMode: Image.PreserveAspectCrop
                        clip: true
                    }
                    Image {
                        id: coverTop
                        // FLUSH. No margins: the cover is a square the exact height
                        // of the rows beside it, meeting the panel edge and the
                        // message bar with nothing between. An inset here read as a
                        // black border around every cover.
                        anchors.fill: parent
                        source: zenon.fileUrl(root.coverArt)
                        asynchronous: true
                        cache: true
                        // Crop, not fit: a cover that is not exactly square must
                        // fill the box rather than letterbox itself inside it, which
                        // is the other way gaps appear.
                        fillMode: Image.PreserveAspectCrop
                        clip: true
                        opacity: status === Image.Ready ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                        onStatusChanged: if (status === Image.Ready) coverUnder.source = source
                    }
                    // NO ANIMATION ON THE WIDTH. A cover appearing or going is a
                    // change to the width of everything beside it, so easing it
                    // drags the whole list left and right -- which is motion the
                    // list did not ask for and cannot absorb. The cover changing
                    // from one track to the next is a change of PICTURE, and the
                    // two images above cross-fade it in place.
                }

            Loader {
                id: body
                // By id, not by child index: positional lookups break the moment
                // anything is inserted, and they say nothing about what they mean.
                width: parent.width - contextCover.width
                height: root.bodyHeight
                sourceComponent: root.layout === "grid" ? gridView : listView
                // Asynchronous: a grid of 700 rows must not stall the frame that
                // swaps the view in. This is not rofi -- nothing here blocks.
                asynchronous: true
                onLoaded: root.applyPos()
                // NOT focused. GridView and ListView are focus scopes, so a focused
                // view takes every key press and the keymap never runs -- which is
                // exactly why Return, Escape and Backspace all did nothing. The
                // keymap owns input and moves the cursor itself.
                focus: false
            }
            }

            // THE WAIT, made visible. A glow across the whole top of the body,
            // breathing while the answer is on its way.
            //
            // It PULSES rather than travels: nothing here knows how far along the
            // engine is, and a bar that crept rightwards would be claiming progress
            // it cannot measure. Breathing says "working" and claims nothing.
            //
            // No edge anywhere: it is the falloff itself, brightest where the rows
            // will start and gone before the middle of the menu, so it bleeds into
            // the list rather than sitting in front of it. And it hangs LOWEST in the
            // middle -- light spilling from the header, not a rule drawn across it.
            Item {
                id: glow
                anchors.fill: parent
                visible: root.blanked
                clip: true
                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    running: root.blanked
                    NumberAnimation { from: 0.2; to: 1.0; duration: 620
                                      easing.type: Easing.InOutSine }
                    NumberAnimation { from: 1.0; to: 0.2; duration: 620
                                      easing.type: Easing.InOutSine }
                }
                Shape {
                    id: glowShape
                    // Drawn 100 units wide and STRETCHED across the body, because
                    // the fill is a radial gradient and a circle stretched sideways
                    // is the shape this wants: a wide, shallow ellipse. The stretch
                    // is horizontal only, so the depths below are plain pixels.
                    width: 100
                    height: glow.height
                    transform: Scale { xScale: glow.width / glowShape.width }
                    ShapePath {
                        strokeWidth: 0
                        // Centred just above the top edge, so the light reaches
                        // about 60px down at the middle of the menu and about 40 at
                        // either end. Enough sag to see, not enough to notice.
                        fillGradient: RadialGradient {
                            centerX: 50; centerY: -8; centerRadius: 70
                            focalX: 50;  focalY: -8
                            GradientStop { position: 0.0;  color: zenon.fade(zenon.playing, 0.34) }
                            GradientStop { position: 0.45; color: zenon.fade(zenon.playing, 0.13) }
                            GradientStop { position: 1.0;  color: zenon.fade(zenon.playing, 0.0) }
                        }
                        startX: 0; startY: 0
                        PathLine { x: glowShape.width; y: 0 }
                        PathLine { x: glowShape.width; y: glowShape.height }
                        PathLine { x: 0;               y: glowShape.height }
                    }
                }
            }
            }

            // --- notification -----------------------------------------------------
            // Above the now-playing strip when there is a track, at the very foot of
            // the panel when there is not -- it is the last thing in the column
            // either way, and nowBar collapses to nothing on its own with nothing
            // playing. So this needs no rule about where to sit; the column already
            // has one.
            //
            // It grows the panel rather than overlaying it. A toast that floats over
            // the rows would hide whichever one it landed on, and the row it lands on
            // is not its business.
            Rectangle {
                id: noticeBar
                width: parent.width
                height: root.notice.length ? noticeText.implicitHeight + zenon.messagePadV * 2 : 0
                visible: height > 0
                clip: true
                color: zenon.messageBg
                Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Rectangle {
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: 1
                    color: zenon.separator
                }
                Text {
                    id: noticeText
                    anchors.centerIn: parent
                    width: parent.width - zenon.messagePadH * 2
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: root.notice
                    color: zenon.notice
                    font { family: zenon.fontFamily; pointSize: zenon.fontSize; bold: true }
                }
            }

            // --- now playing ------------------------------------------------------
            // The progress IS the bar: a fill that sweeps under the text rather than
            // a separate rule below it. Ahead of the fill the line is green on grey;
            // behind it, black on green. Two layers of the same content -- the lower
            // one plain, the upper one inverted and clipped to the fill -- so the
            // letters line up exactly and the colour change happens mid-glyph.
            Item {
                id: nowBar
                width: parent.width
                // ACTIVE means a track is loaded, playing OR paused -- a paused
                // track is still the thing you are on, and hiding it would make
                // pause look like stop. Nothing loaded at all collapses the bar.
                readonly property bool active: !!(root.playback && root.playback.name)
                readonly property string trackText: {
                    var p = root.playback
                    if (!p || !p.name) return ""
                    // The transport glyph and separator are the engine's own, so
                    // this strip reads as the same program as the message bar.
                    var glyph = p.playing ? zenon.glyphPlay : zenon.glyphPause
                    return glyph + p.name + (p.artists ? zenon.sep + p.artists : "")
                }
                height: active ? zenon.nowBarHeight : 0
                visible: height > 0
                clip: true
                Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                // The unplayed remainder.
                Rectangle {
                    anchors.fill: parent
                    color: zenon.messageBg
                    Rectangle {
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: 1
                        color: zenon.separator
                    }
                }
                // The played portion: a dark green ground BEHIND the line rather
                // than an inverted copy of it. The track and the clock stay green
                // throughout, so the fill reads as progress instead of as the text
                // changing colour mid-word. No animation on the width -- it is
                // already driven every frame by the interpolator, and easing a value
                // that is itself continuous only adds lag.
                Item {
                    id: played
                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                    width: parent.width * root.progress
                    clip: true
                    // Lit from below rather than filled flat: the same idea as the
                    // loading glow, turned the other way up so the light rises out of
                    // the window edge instead of falling from the header. It stays
                    // dark enough at the top for green text to read over it, which is
                    // the constraint the flat fill was chosen for in the first place.
                    Rectangle {
                        anchors.fill: parent
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: zenon.progressFill }
                            GradientStop { position: 0.55; color: zenon.progressFill }
                            GradientStop { position: 1.0
                                           color: zenon.fade(zenon.playing, 0.22) }
                        }
                    }
                    // THE PLAYHEAD. A soft edge where the fill ends, breathing while
                    // the track plays and still when it does not -- so the strip has
                    // a pulse exactly as long as there is something to have one. The
                    // only moving part: a bar that pulsed along its whole length
                    // would be asking to be looked at, and this one is furniture.
                    Rectangle {
                        anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                        width: Math.min(56, played.width)
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: zenon.fade(zenon.playing, 0.0) }
                            GradientStop { position: 1.0; color: zenon.fade(zenon.playing, 0.30) }
                        }
                        SequentialAnimation on opacity {
                            loops: Animation.Infinite
                            running: root.playback.playing === true && nowBar.active
                            // Slow, and never all the way down: this sits on screen
                            // for the length of every track, so it breathes at the
                            // pace of breathing rather than of a spinner.
                            NumberAnimation { from: 0.45; to: 1.0; duration: 1400
                                              easing.type: Easing.InOutSine }
                            NumberAnimation { from: 1.0; to: 0.45; duration: 1400
                                              easing.type: Easing.InOutSine }
                        }
                    }
                }
                NowContent {
                    anchors.fill: parent
                    theme: zenon
                    fg: zenon.playing
                    track: nowBar.trackText
                    icons: root.playback.icons || ""
                    elapsed: root.clock(root.positionMs)
                    total: root.clock(root.playback.duration || 0)
                shuffle: root.playback.shuffle === true
                repeatMode: root.playback.repeat_ || "off"
                }

            }
        }

        // --- detail sheet --------------------------------------------------------
        Rectangle {
            id: sheetPanel
            anchors.fill: parent
            // Nearly opaque, unlike the panel itself: rofi drew a sheet in its own
            // window with its own theme, so it never competed with a grid behind it.
            // Here it does, and text over album covers is unreadable.
            color: Qt.rgba(0, 0, 0, 0.96)
            // A sheet IS the window while it is up, so it wears the window's frame.
            // Filling the panel edge to edge painted over ZENON's border and its
            // rounded top corners, and the sheet came up as a bare black rectangle.
            radius: zenon.radius
            border.width: zenon.borderWidth
            border.color: zenon.borderCol
            visible: opacity > 0
            opacity: (root.sheet.length || root.sheetRows.length) ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

            Flickable {
                anchors.fill: parent
                // The same padding the window was sized with, so the measured fit
                // and the drawn inset cannot disagree.
                anchors.margins: zenon.sheetPad
                contentHeight: root.sheetRows.length ? keySheet.contentHeight
                                                     : sheetText.implicitHeight
                clip: true

                PairSheet {
                    id: keySheet
                    width: parent.width
                    theme: zenon
                    rows: root.sheetRows
                    labelColor: root.sheetKind === "details" ? zenon.fieldName : zenon.keyCap
                    wrapValues: root.sheetKind === "details"
                    visible: root.sheetRows.length > 0
                }
                Text {
                    id: sheetText
                    visible: root.sheetRows.length === 0
                    width: parent.width
                    text: root.sheet
                    color: zenon.foreground
                    font.family: zenon.fontFamily
                    font.pointSize: zenon.sheetFontSize
                    font.weight: zenon.sheetFontWeight
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                }
            }
        }

        // --- art viewer ----------------------------------------------------------
        // A CARD OVER THE MENU, not a panel instead of it. It used to fill the
        // whole surface and paint the menu out, so opening a cover meant leaving
        // wherever you were; now the menu stays where it is, dimmed, and the
        // picture floats in the middle of it. Backing out of one puts you
        // straight back into a view that never went anywhere.
        Item {
            anchors.fill: parent
            visible: opacity > 0
            opacity: root.artPath.length ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

            // The menu is still there, just behind. Dark enough that the picture
            // is what you are looking at, light enough that you can see you have
            // not gone anywhere.
            Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.62) }

            Rectangle {
                id: artCard
                anchors.centerIn: parent
                width: artImage.width + zenon.messagePadV * 2
                height: artCap.implicitHeight + artImage.height + zenon.messagePadV * 3
                color: zenon.ground
                radius: zenon.radius
                border.width: zenon.borderWidth
                border.color: zenon.borderCol
                clip: true

                // LISTENING rings. Only while songrec is running -- the same card
                // otherwise shows a still cover, which should not pulse. Three
                // circles expanding and fading on a stagger, so the window says
                // "receiving" rather than "frozen" during a thirty-second wait.
                Repeater {
                    model: root.overlayTheme === "listen" ? 3 : 0
                    delegate: Rectangle {
                        anchors.centerIn: parent
                        property real phase: 0
                        width: (root.g.icon || 300) * (0.55 + phase * 0.85)
                        height: width
                        radius: width / 2
                        color: "transparent"
                        border.width: 2
                        border.color: zenon.playing
                        opacity: (1 - phase) * 0.45
                        SequentialAnimation on phase {
                            loops: Animation.Infinite
                            running: root.overlayTheme === "listen"
                            // Staggered so the rings chase each other outward
                            // instead of pulsing as one thick band.
                            PauseAnimation { duration: index * 600 }
                            NumberAnimation { from: 0; to: 1; duration: 1800
                                              easing.type: Easing.OutCubic }
                        }
                    }
                }

                // THE CAPTION SITS ABOVE THE PICTURE, as it did in rofi: art.rasi
                // and imp.rasi both order their mainbox [message, listview].
                Text {
                    id: artCap
                    anchors { top: parent.top; horizontalCenter: parent.horizontalCenter
                              topMargin: zenon.messagePadV }
                    width: parent.width - zenon.messagePadH
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: root.artMesg
                    color: zenon.foreground
                    font.family: zenon.fontFamily
                    // art.rasi and imp.rasi say Bold 12; listen.rasi says 13.
                    font.pointSize: root.overlayTheme === "listen"
                                    ? zenon.listenCapSize : zenon.fontSize
                    font.bold: true
                }
                Image {
                    id: artImage
                    anchors { top: artCap.bottom; topMargin: zenon.messagePadV
                              horizontalCenter: parent.horizontalCenter }
                    // EXACTLY the size the theme names -- art.rasi 1000,
                    // imp.rasi 640, listen.rasi 300 -- as a square, both sides.
                    // Not fitted to the window: the WINDOW is what gives way,
                    // widening to hold the picture and its frame (see root.width).
                    width: root.g.icon || 400
                    height: width
                    source: zenon.fileUrl(root.artPath)
                    asynchronous: true
                    cache: false        // a viewer shows one image; caching wastes memory
                    // CROP, not fit. An album cover is square and either does the
                    // same thing; an artist photo is not, and fitting one inside
                    // a square box leaves the band of dead space under it that
                    // made the bottom of an artist image look misshapen. Cropping
                    // fills the square the theme asked for.
                    clip: true
                    fillMode: Image.PreserveAspectCrop
                    smooth: true
                    opacity: status === Image.Ready ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                    // A slow breath while listening, so the icon is alive too.
                    SequentialAnimation on scale {
                        loops: Animation.Infinite
                        running: root.overlayTheme === "listen"
                        NumberAnimation { from: 1.0; to: 1.06; duration: 900; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 1.06; to: 1.0; duration: 900; easing.type: Easing.InOutSine }
                    }
                }
            }
        }

    }

    // --- keys ----------------------------------------------------------------
    Keymap { app: root }
}
