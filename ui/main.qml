// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// The shell: one persistent surface, a message bar, and whatever view is
// current. There is no menu stack of windows here -- the engine owns the session
// stack, so this asks what to draw rather than remembering it.
import QtQuick
import QtQml
import QtQuick.Window
import QtQuick.Shapes
import QtQuick.Effects
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
    // `overlayUp` STOOD HERE, and with it every branch that let a sheet decide the
    // panel's shape: the panel took the sheet's width and height, the column of
    // bars inside it was faded out so it would not lay itself out past the new
    // bottom edge, and the body borrowed the sheet's line count.
    //
    // A sheet is a CARD now (see sheetCard), floating over an untouched panel the
    // way the image viewer and the action menus do. There is nothing left for the
    // panel to do about one, so all of it is gone -- including snapToCursor, which
    // existed only to put the list back after the panel had finished resizing.
    readonly property int bodyHeight: {
        // THE ART VIEWER AND THE SHEETS DO NOT TOUCH THIS. Both are cards
        // floating over the menu, so the menu underneath keeps the shape it had
        // -- which it did not, because this returned the CARD's line count for
        // it: art.rasi is one line tall, so a 671-row list was laid out one row
        // high, and a GridView flowing top to bottom answers that by running the
        // list into 671 COLUMNS. Closing the card left it parked among them,
        // sideways. That is the "garbled text, like two columns" coming back
        // from Alt+a.
        // NO ROWS MEANS NO BODY. This had a floor of one, which drew an empty
        // row's worth of panel for a list that genuinely has nothing in it -- a
        // search history before you have searched for anything. The floor was
        // never load-bearing for the loading case either: rows are deliberately
        // left standing until the next draw applies, so a menu in flight is
        // sized by the rows still on screen rather than by this.
        return root.usedRows * (layout === "grid" ? zenon.cellHeightFor(root.cellW)
                                                  : zenon.rowHeight)
    }
    // A CARD USED TO GROW THE PANEL. `ctxExtra` stood here: the room the card
    // needed beyond what the menu already had, added to the panel so the card had
    // somewhere to be. It could not be added to the LIST -- a RowList is a
    // GridView flowing top to bottom, so changing its height changes how many
    // rows fit in a column and the whole list re-flows underneath the card -- so
    // it went to the panel instead and the list was centred in the extra space.
    //
    // Which is why a card over a SHORT list shoved that list upward: three rows
    // of menu, a twelve-row card, and the panel grew nine rows to hold it with the
    // three rows floating in the middle. The card is not inside the panel any
    // more (see ctxLayer, now a child of the panel rather than of the body), so
    // there is nothing to make room for and the panel never changes shape when a
    // card opens. See root.cardY, which is what keeps it on screen instead.
    // Every bar in the column pays for itself, and each collapses to nothing
    // when it has nothing to say -- the input bar outside search, the message
    // bar with no caption and no trail, the notification between notifications,
    // the now-playing strip with nothing loaded.
    // An overlay IS the panel: it draws its own caption above its own picture and
    // covers everything else, so the panel is exactly as tall as it. Adding the
    // chrome underneath reserved room for a message bar and a now-playing strip
    // that the overlay then painted over -- which is the empty band that sat
    // below every cover and every artist image.
    readonly property int menuHeight: message.height + bodyHeight
                                     + noticeBar.height + zenon.borderWidth
    // A sheet is still a panel and sizes the window to itself. The art viewer is
    // a card ON the menu, so the surface only has to grow enough to hold it --
    // and when the menu is already taller, it does not grow at all.
    // NOT visible from QML. The host shows the window only after asking
    // LayerShellQt for it -- get() has to run before the platform window exists
    // or the surface is created as an ordinary toplevel and the compositor tiles
    // it like any other app. Showing here cost exactly that on the first run.
    visible: false
    color: "transparent"          // the rounded panel below paints the ground

    // Everything the UI Settings menu can change, as the engine last sent it.
    property var settings: ({})
    Theme { id: zenon; cfg: root.settings }

    // WHERE SPOOT SITS, split into the two halves the anchors need. Nine
    // positions, stored as one string by the engine, read here and nowhere else.
    readonly property string anchorV: (root.settings.position || "bottom-center").split("-")[0]
    readonly property string anchorH: (root.settings.position || "bottom-center").split("-")[1]

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
        // Already known -- see listenWanted, which is armed from `startView` at
        // construction so a cold `spoot --listen` never shows the panel at all.
        // The host reveals the window and then spends a round trip resuming the
        // trail; that stretch is what used to be the flash.
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
                return
            }
            var rid = root.call("restore", {}, function (r) {
                root.drawReq = rid
                if (r && r.rows && r.rows.length) root.render(r)
                else root.goHome()
                // NOTHING TO DO HERE. openListen used to be called beside
                // goHome, which is a REQUEST rather than a redraw -- two navs in
                // flight, and the listener's empty one arrived last and won, so no
                // menu was ever drawn. It is handed to the draw instead, and
                // listenWanted was set before either branch ran.
            })
        })
    }
    // `spoot --listen` IS WAITING FOR A MENU TO EXIST.
    //
    // The listener is a card over wherever you are, and on a cold start there is
    // no "wherever you are" until the first draw lands. A one-shot rather than a
    // call at each of bootstrap's exits: two of the three are asynchronous, and
    // the one that raced is the one nobody would notice until they tried it.
    //
    // TRUE AT CONSTRUCTION, not from bootstrap. `startView` is a context property
    // set before the QML is loaded (see main.cpp), so this is already the right
    // answer before the host reveals the window -- and it has to be: bootstrap
    // runs a turn LATER, by which point showPanel has begun and the panel is
    // already fading up. Setting the wish there left the dim easing down against
    // an opening panel, which is a flicker rather than a flash but is still not
    // nothing. Declared here, the panel never begins to appear at all.
    property bool listenWanted: (typeof startView !== "undefined" && startView === "listen")
    // HAS A MENU EVER BEEN DRAWN. Cold starts open the panel before the answer to
    // that is yes; see showPanel, which waits for it.
    property bool firstDrawn: false
    ListModel { id: rows }
    // The card's rows. A second model rather than a second app: the engine hands
    // back ONE draw per round trip (see Util.serve_run), so the only way to have
    // a list and the menu about one of its rows on screen at once is to keep the
    // list where it is and put the menu somewhere else.
    ListModel { id: ctxRows }

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
    // A HOP THAT ONLY EVER OPENED A CARD. Going THROUGH an action menu does leave
    // its step on the trail -- it has to, or the engine could not replay the path
    // to wherever you ended up -- but the menu itself is still not a place, so
    // walking back over that step must not stop on it. Recognised by its shape
    // rather than remembered: an alt step IS the gesture that opens a context
    // menu, so nothing has to be stored, nothing has to survive nav.json, and a
    // trail written by an older build reads correctly too.
    // HOW MANY STEPS THE ENGINE SHOULD STILL BE COUNTING, if every hop that
    // produced the current card described a place. Compared against the draw's
    // own `keep` -- see applyContext, where a shortfall is the engine saying the
    // verb you picked ACTED rather than went anywhere.
    //
    // Walked rather than added: a root hop among them (Alt+Return) starts the
    // count again, because that is what a root means and `keep` counts steps
    // inside the current one.
    function ctxKeepWanted() {
        var n = root.path.length
        for (var i = 0; i < root.ctxHops.length; i++) {
            if (root.ctxHops[i].cmd) n = 0
            else n++
        }
        return n
    }
    // THE ROW THE CARD IS ABOUT, in the list behind it. A copy receipt is drawn
    // on a row of THAT list, so `lastSrc` has to name something in it -- the
    // verb's own index named whichever track happened to sit at the same
    // position, which is how Copy Web Link put its tick on an unrelated row.
    readonly property int ctxSubjectSrc: {
        var h = root.ctxHops.length ? root.ctxHops[0] : null
        return (h && h.step && typeof h.step === "object" && h.step.i !== undefined)
               ? h.step.i : -1
    }
    function isCtxHop(h) {
        return !!(h && h.step && typeof h.step === "object" && h.step.alt === true)
    }
    // ...and walking past it, in whichever direction you were going. Guarded
    // against a trail of nothing but alt steps, which cannot happen and would
    // spin here if it did.
    function skipCtx(pos, dir) {
        var guard = 0
        while (pos > 0 && pos <= root.hops.length
               && root.isCtxHop(root.hops[pos - 1]) && guard++ <= root.hops.length) {
            pos += (dir < 0 ? -1 : 1)
        }
        return Math.max(0, Math.min(root.hops.length, pos))
    }
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
    // -1, not 0: cleared means "no snapshot", and `want` is never negative, so
    // the test above cannot match a spent one even before preHops is consulted.
    property int prePos: -1
    // THE ROW, NOT MERELY WHERE IT SAT.
    //
    // A path step is an INDEX, replayed against whatever the engine draws at that
    // depth -- and it is only ever the right row while the list is still the list
    // it was picked from. It often is not: a revalidation lands, a playlist is
    // edited in another client, a shelf refreshes underneath you. Then the index
    // picks something else, and because every step after it in the path is fed to
    // whatever menu that opened, the whole tail is spent on rows nobody chose --
    // "selecting a track from an album opens another album", and the toast about
    // a playlist that was never a playlist.
    //
    // So the step carries the row's ID beside its index wherever the row has one.
    // The engine checks the two agree before taking the answer and looks the id up
    // when they do not; see ui_menu's replay. Rows without one -- verbs in a card,
    // settings values -- send the index alone and behave exactly as they did.
    //
    // ONE FUNCTION because four gestures build a step (a pick, Shift+Return, Tab,
    // Delete, a middle-click queue) and a step that carries an id from three of
    // them is worse than one that carries it from none.
    function rowStep(m, i, extra) {
        var st = extra || {}
        var inRange = !!m && i >= 0 && i < m.count
        // Lua is 1-based, and so are the indices rofi handed back; out of range
        // keeps the old arithmetic rather than inventing a row.
        st.i = inRange ? m.get(i).src : (i + 1)
        var rid = inRange ? (m.get(i).id || "") : ""
        if (rid.length) st.id = rid
        return st
    }

    function pushHop(h) {
        // Going somewhere puts the card away. Every root and every ordinary step
        // comes through here, so this is the one place it has to be said.
        root.closeContext()
        // ...AND THE BRANCH TAKES THE CRUMB MAP WITH IT. Whatever was ahead of the
        // cursor is about to stop existing; see root.forgetAhead.
        root.forgetAhead(root.trailPos)
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
    // the same reason the panel's own open runs a little past its close.
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
        root.runSetup()
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
            // THE ENGINE CAME BACK. Everything in flight died with it, so the
            // callbacks are dropped rather than left to leak, the loading glow is
            // released, and the menu is asked for again -- which the engine
            // answers from the session it restores on start. From the outside a
            // crash is now a flicker and a line in the notice bar, instead of a
            // window that stops answering and never says why.
            else if (name === "engine-restarted") {
                root.pending = ({})
                root.drawIds = ({})
                root.inFlight = 0
                root.endDraw()
                root.abortSwap()
                root.notify("engine restarted")
                root.refresh(0)
            }
            // ...and when it cannot start at all, say so rather than spinning.
            else if (name === "engine-lost") {
                root.inFlight = 0
                root.endDraw()
                root.abortSwap()
                root.notify("engine keeps failing to start \u2014 try: spoot --doctor", true)
            }
            // See Util.view_trail_jump: the engine cannot walk a path that spans
            // roots, so it names the step and this does the walking.
            else if (name === "jump") { root.jumpTrail(data.crumb || 0) }
            // CLEAR SESSION. The trail lives here while spoot is open, so the
            // engine emptying its own files cleared nothing visible -- the next
            // draw arrived carrying the same hops. This is the UI dropping them,
            // which is exactly what Alt+Delete does. See Util.clear_trail.
            else if (name === "home") root.goHome()
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
            // WHAT A FIRST RUN STILL OWES: the account, then the playback
            // device. Sent once at startup and only when one of them is
            // outstanding, so a machine that is signed in never sees this path.
            else if (name === "setup") root.onSetup(data)
            else if (name === "sheet") {
                root.sheetRows = root.toArray(data.rows)
                root.overlayFresh = true
                root.sheetKind = data.kind || ""
                root.sheetTitle = data.title || ""
                root.overlayTheme = data.theme || "meta"
            }
            else if (name === "listening") {
                // A PILL, not a picture. This used to borrow the art overlay
                // wholesale -- a 300px speaker glyph with a caption under it --
                // because in the rofi build a window with an image was the only
                // way to look busy. What spoot is doing is a sentence; the pill
                // is that sentence with a light going round it. See listenPill.
                root.overlayFresh = true
                root.artMesg = root.listenLines[
                    Math.floor(Math.random() * root.listenLines.length)] + "\u2026"
                root.overlayTheme = "listen"
            }
            else if (name === "prompt") {
                root.promptFor = data.prompt || ""
                root.setFilter(data.preset || "")
                // THE STEP THAT RAISED THE FIELD STAYS ON THE PATH, and this is
                // the whole of "create new playlist doesn't work".
                //
                // It used to come off here, on the reasoning that the engine
                // answered nil and stayed put so the step was not a place. It is
                // not -- and it is still an ANSWER. `Create New Playlist` is row
                // one of a real menu, and the text is the answer to the field
                // that row opened: the engine reads them in that order (see
                // ui_ask, which takes the step AFTER the one its menu consumed).
                // Dropping the row put the typed name where the row answer
                // belonged, so the playlists grid -- a by_index menu -- was handed
                // a string and the engine raised "attempt to compare number with
                // string". Nothing was ever created.
                //
                // Not a place is handled where every other step's is: `keep`
                // says so on the next draw and applyWhere trims it, so this
                // leaves no crumb behind either way. Giving up on the field is
                // the one case that has to drop it by hand -- see cancelPrompt.
            }
            // HOW TO LOOK, from the engine. Sent before the first draw and again
            // whenever a setting changes, so a change lands live rather than at
            // the next launch -- Theme is bound straight to this.
            else if (name === "settings") root.settings = data
            else if (name === "art-view") {
                root.artPath = data.path || ""
                root.overlayFresh = true
                root.artMesg = data.mesg || ""
                root.overlayTheme = data.theme || "art"
                // A FRAME, but only a rule. The margin is exactly the border and
                // not a pixel more, so nothing is drawing attention to the
                // container -- the picture still ends where the picture ends, and
                // the 2px edge is what separates it from whatever it floats over.
                // Its title rides a bar of its own on top, the way every other
                // caption in spoot sits on the message ground rather than on the
                // artwork behind it.
                root.artPad = zenon.artBorder
                // The VIEWER does have to fit: it asks for 1000px, which no
                // narrow output can give it. Worked out once, here, rather than
                // as a live binding that would re-answer as the card leaves.
                root.artIcon = Math.max(160,
                    Math.min(zenon.geom(root.overlayTheme).icon || 400,
                             root.width - zenon.sheetPad * 4,
                             root.height - zenon.sheetPad * 10))
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
        if (name === "art") { root.applyArt(data); return }
        // A CARD'S OWN PICTURE goes in the card and nowhere else. It used to be
        // written into the LIST's backdrop with artLive turned off to make it
        // stick, which is why opening a track's action menu inside an album wiped
        // the album's sleeve. The two are separate state now, so a card can wear
        // its subject while the list behind goes on wearing its own.
        if (data.own) { root.cardArt = data.path || ""; return }
        root.contextArt = data.path || ""
        root.contextArtFor = data.id || ""
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
        root.fillRows(rows, root.allRows, root.filter)
    }
    // The card's half of the same thing. Typing while a context menu is up
    // narrows ITS verbs, not the list behind it -- which is the whole reason the
    // two models and the two filters exist.
    function applyCtxFilter() {
        root.fillRows(ctxRows, root.ctxAll, root.ctxFilter)
    }
    // ONE FILLER. It used to be applyFilter's body, with the model and the source
    // named inline; a context menu needs the identical walk over a different pair
    // and copying it would have been two rules for what a match is.
    function fillRows(model, source, filter) {
        model.clear()
        var f = root.narrows ? filter.toLowerCase() : ""
        for (var i = 0; i < source.length; i++) {
            var r = source[i]
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
                model.append({label: r.label, icon: r.icon || "", key: r.key || "",
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

    // A CONTEXT MENU NEEDS SOMETHING TO SIT ON. A session restored straight into
    // an action menu, and Alt+Return -- which pushes a root hop of its own -- both
    // arrive with nothing drawn underneath. There the menu is the only thing there
    // is, so it is drawn as one, and the full-panel path stays a live route rather
    // than becoming a branch nothing reaches.
    function isContext(d) { return d && d.context === true && rows.count > 0 }

    function render(d) {
        // ANY DRAW AT ALL RELEASES THE ARM. The listen's own answer is its reply
        // rather than a draw (see openListen), so this is insurance: a menu
        // arriving while the panel is armed dark means something other than a
        // listen is happening, and the panel has to be visible for it.
        root.listenArming = false
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
            // A STEP THAT DREW NOTHING WAS NOT A PLACE. Alt+y on a track with no
            // lyrics says so and draws no menu -- and the hop that asked stayed on
            // the trail, so every refresh after it replayed the step, said it
            // again, and swallowed whatever you had actually pressed. Playing
            // another track just re-announced that the first one had no lyrics.
            //
            // The overlay EVENTS used to drop the step themselves, each in its own
            // handler, and a plain one-line message had no handler to do it in.
            // Worse, they had stopped being right: a card's steps are provisional
            // and live on ctxHops, so Track Details opened from one ate a real
            // trail step instead. Decided here now, at the single moment the
            // engine has said "there is no menu at the end of this", and on
            // whichever list the step actually went to.
            if (root.ctxHops.length) root.ctxHops = root.ctxShown.slice()
            else root.popTransient()
            // ...AND THE SNAPSHOT IS SPENT HERE TOO, which is the third and last
            // route out of a draw. preHops is good for exactly one draw --
            // applyWhere clears it and applyContext clears it -- and this branch
            // returns before either runs, which the openListen note further down
            // says in as many words: "the draw comes back empty, so applyWhere
            // never ran".
            //
            // So a step that drew nothing left a plausible-looking trail from an
            // earlier branch alive into the NEXT step, where applyWhere's test is
            // two small integers agreeing -- and when they did, `hops` was
            // replaced wholesale by a path nobody had walked in a while. The
            // crumb still read correctly, because it comes from the draw, and
            // nothing looked wrong until the step after that: the engine replayed
            // the stale path and answered about a row in a menu one level up.
            // That is picking a track in an album and opening an album from the
            // step before it, and -- when the shifted index lands on a menu with
            // an "Add to Playlist" row -- the toast about a playlist that is no
            // longer there, from a place that was never a playlist.
            root.preHops = []
            root.prePos = -1
            return
        }
        // AN ACTION MENU GOES ON TOP OF THE MENU, not in place of it. Decided
        // before anything else about the transition, because there is no
        // transition: the body is staying exactly where it is.
        if (root.isContext(d)) {
            // ...and if a swap had already begun -- a leftover from a request
            // still in flight when this one answered -- it has nothing to swap
            // to any more. Put the body back, or the card would sit over a list
            // that is halfway faded out.
            if (swapOut.running || root.heldDraw) root.abortSwap()
            root.applyContext(d)
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
    //
    // Told WHICH model and WHICH filter, because the card redraws the same way
    // the body does: Like and Play answer with the same action menu one row
    // different, and rebuilding it would blink the card for a marker moving.
    function patchRows(model, list, filter) {
        if (filter.length || list.length !== model.count) return false
        for (var i = 0; i < list.length; i++) {
            var r = list[i], m = model.get(i)
            if (m.label !== r.label) model.setProperty(i, "label", String(r.label))
            var rich = r.rich || ""
            if (m.rich !== rich) model.setProperty(i, "rich", rich)
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
            if (icon.length && m.icon !== icon) model.setProperty(i, "icon", icon)
            var key = r.key || ""
            if (m.key !== key) model.setProperty(i, "key", key)
            var rid = r.id || ""
            if (m.id !== rid) model.setProperty(i, "id", rid)
        }
        return true
    }

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
    //
    // Its own function because a CONTEXT draw shares exactly this and nothing
    // else below it: opening a card retires a stale viewer, and moves the trail
    // not at all.
    function dropStaleOverlay() {
        if (!root.overlayFresh && root.overlayAsked) root.closeOverlay()
        root.overlayFresh = false
    }

    // WHERE THIS DRAW LEAVES YOU, as opposed to what it puts on screen. Only
    // applyDraw calls this: a context menu is not a place, so none of it applies
    // to one. Runs FIRST, because the trail arithmetic moves trailPos and
    // everything after it reads that.
    function applyWhere(d) {
        root.dropStaleOverlay()
        // A CARD'S HOPS WERE A JOURNEY AFTER ALL. This answer is a real menu, so
        // the provisional steps that produced it described places -- they join
        // the trail here, ahead of the keep block, which then trims whichever of
        // them merely acted, exactly as it does for any other step. Held off
        // until this moment so that the far commoner case, a verb that acts and
        // answers with the same card, never touches the trail at all.
        if (root.ctxHops.length) {
            root.preHops = root.hops
            root.prePos = root.trailPos
            root.hops = root.activeHops().concat(root.ctxHops)
            root.trailPos = root.hops.length
            root.fullCrumb = []; root.fullRoots = []
            root.ctxHops = []
            root.ctxShown = []
        }
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
        // ...BUT A STEP THAT RAISED A FIELD IS NOT SPENT. It is half of an answer
        // waiting for the other half, and `keep` cannot know that: the view took
        // the step, put a prompt up and stayed exactly where it was, which is
        // indistinguishable from a verb that acted -- so the trim below drops it,
        // and the typed name then lands where the ROW answer belonged. That is
        // the second half of "create new playlist doesn't work", and the reason
        // taking popTransient out of the prompt handler was not enough on its own:
        // this was doing the same thing one step later.
        //
        // The prompt event is written before the response, so promptFor is
        // already set by the time this draw is applied. Cancelling drops the step
        // by hand -- see cancelPrompt -- and submitting appends the text to it.
        if (d && d.keep !== undefined && !root.promptFor.length) {
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
                root.forgetAhead(want)
            }
        }
        // AND THE SNAPSHOT IS SPENT. preHops describes the trail as it stood
        // immediately before the step this draw answers, which makes it good for
        // exactly one draw. Nothing cleared it, so it outlived its step and sat
        // there as a plausible-looking trail from some earlier branch -- and the
        // test above is two small integers agreeing, which they do by coincidence
        // often enough. When they did, `hops` was replaced wholesale by a path
        // nobody had walked in a while: the crumb still read correctly (it comes
        // from the draw), so nothing looked wrong until the next step was sent --
        // and the engine, replaying that stale path, answered about a row in a
        // menu one level up. That is Shift+Return opening the action menu of an
        // item in the previous trail step.
        //
        // Cleared here rather than guarded harder, because "valid for the next
        // draw only" is the actual rule and a one-shot is how you say it.
        root.preHops = []
        root.prePos = -1
    }

    // WHAT THIS MENU IS -- its name in the trail, the view it counts as, and the
    // keys it claims. The other half applyDraw shares with a context menu: a card
    // floating over a list is still the menu with the keyboard, so Delete and Tab
    // have to follow it rather than staying with the list underneath.
    function applyIdentity(d) {
        root.canDelete = d.del === true
        root.canTab = d.tab === true
        root.scope = d.scope || ""
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
        root.lyricTimes = []; root.lyricFor = ""; root.lyricIndex = -1
        if (d.scope === "lyrics" && d.track) {
            var want = d.track
            root.call("lyrics", {id: want}, function (ly) {
                // Positional, so the cues must line up with the rows the view
                // drew. If they do not, the track has lyrics but not synced ones
                // -- show them, just do not pretend to follow along.
                // ...and not into a view that has since been left. The row-count
                // test below usually catches that by accident; this says it.
                if (root.scope !== "lyrics") return
                if (ly && ly.synced && ly.lines && ly.lines.length === rows.count) {
                    root.lyricTimes = root.toArray(ly.times)
                    root.lyricFor = want
                }
            })
        }
    }

    function applyOrigin() {
        // The trail describes the menu again -- the step that played has been
        // dropped by `keep` -- so this is the moment the origin is knowable.
        // WHERE THE PLAYING TRACK CAN BE SEEN is an origin, whether or not you
        // played it from here. Recording only at the moment of playing left
        // Alt+c with nothing to go on for anything started in an earlier session,
        // or from a menu the trail no longer remembers -- and there is no honest
        // answer to "take me to it" without one.
        //
        // An ACTION MENU is never an origin: it is a list of verbs about a track,
        // not a place the track lives. That used to need a step subtracted here to
        // say so; now it costs no step at all, so trailEnd() already names the
        // list it was opened from and there is nothing to correct.
        if (root.armOrigin.length || (root.playback.id && root.playingRowIndex() >= 0)) {
            var oid = root.armOrigin.length ? root.armOrigin : root.playback.id
            var opos = root.trailEnd()
            root.armOrigin = ""
            root.originId = oid
            root.originHops = root.hops.slice(0, opos)
            root.originPos = opos
        }
    }

    // AN ACTION MENU, PUT ON TOP. Everything about where you are still happens --
    // the trail moved, the crumb grew, this menu claims the keyboard -- and the
    // only thing that does NOT is the half of applyDraw that replaces the body:
    // no allRows, no themeName, no positions, no swap animation, and no cover.
    //
    // The cover especially. The engine marks every action menu `art=false`, which
    // through applyDraw would strip the backdrop off the list showing behind the
    // card -- a visible change to something that did not change. A context menu
    // has no backdrop of its own and takes none away.
    function applyContext(d) {
        // ...AND SPENDS THE SNAPSHOT, for the reason applyWhere clears it. A
        // plain Return that turns out to answer with a card comes HERE and never
        // reaches applyWhere, so this is the other way a preHops set by pushHop
        // could outlive the step that took it.
        root.preHops = []
        root.prePos = -1
        // NOT applyWhere. Nothing about the trail changed: the hops that produced
        // this card are not on it, so there is no `keep` arithmetic to do and no
        // position to move. Only the stale-viewer sweep is shared.
        root.dropStaleOverlay()
        // A STEP THAT ANSWERED WITH A CARD WAS NEVER A PLACE -- the mirror of the
        // adoption applyWhere does in the other direction, and the last route by
        // which a card could still land on the trail.
        //
        // Shift+Return and openCard both put their step on ctxHops before asking,
        // because the UI knows in advance that those open a card. A plain Return
        // cannot know: `Seek` is row two of the Playback menu and looks like any
        // other row until the answer comes back saying `context`. So that step
        // went on the trail, and everything downstream followed it -- backing out
        // of the card had to take a trail step off, and taking a step off the
        // trail means a round trip, so closing Seek fetched and redrew Playback
        // although it had never gone anywhere.
        //
        // Moved here, the card is a card however it was reached: ctxShown gets a
        // tail to revert to when a verb is used, and goBack closes it for nothing.
        if (!root.ctxHops.length && root.hops.length
                && root.trailPos === root.hops.length) {
            root.ctxHops = [root.hops[root.hops.length - 1]]
            root.hops = root.hops.slice(0, root.hops.length - 1)
            root.trailPos = root.hops.length
            root.fullCrumb = []; root.fullRoots = []
            root.forgetAhead(root.trailPos)
        }
        // A CONTEXT MENU DOES NOT SURVIVE BEING USED. `keep` is the engine saying
        // which of the steps behind this draw described a place; when the last
        // provisional one did not, the verb ACTED -- Play, Like, Albumart, Copy
        // Web Link -- and what came back is this same menu redrawn rather than a
        // menu you went to. The card closes on the pick, like a context menu
        // anywhere else, instead of sitting there over a list it has finished
        // with. That it stayed is why backing out of Albumart still found it, and
        // why the next Backspace went one level too far.
        //
        // Shift+Return on a verb is the case this must NOT catch: it opens a
        // nested action menu, the step survives, keep matches, and the new card
        // replaces the old.
        //
        // ...and `sticky` is the other. Seek is a menu you use REPEATEDLY -- ten
        // seconds, ten more, back a minute -- so closing it on the pick and
        // asking the list behind it again meant every nudge cost a round trip
        // and came back as a fresh card with its cursor on the first row. The
        // menu says so itself (see the engine's view_seek); nothing about a draw
        // could be read to guess it.
        if (d.keep !== undefined && d.keep < root.ctxKeepWanted()) {
            // THE STEP IS STILL SPENT, even where the card is not. This is the
            // whole of what `keep` was saying, and a sticky card that merely
            // ignored it broke something much worse than a cursor: ctxHops is
            // sent as `tail` on every draw and the engine REPLAYS it, so a pick
            // left on the tail is a verb re-executed on the next one. Two nudges
            // of a minute moved the playhead three.
            //
            // ctxShown is the tail as the card on screen was drawn -- the step
            // that OPENED it and nothing since -- which is exactly the tail this
            // pick should leave behind. The same snapshot a verb that opens a
            // viewer reverts to, for the same reason.
            if (d.sticky && root.ctxUp) {
                root.ctxHops = root.ctxShown.slice()
                // ...and no closeContext and no refresh: fall through, and the
                // redraw is the same eight rows, which patchRows patches in
                // place. The card does not blink and the cursor is not touched.
            } else {
                root.closeContext()
                // AN OVERLAY THIS PICK OPENED SURVIVES THE REFRESH BELOW. Track
                // Details, Album Details and Albumart all arrive as an EVENT
                // just ahead of this draw, and the round trip below is a SECOND
                // draw -- which would find the sheet sitting there with
                // overlayFresh already spent, decide it was left over from an
                // earlier menu, and close it on sight. It is not left over: the
                // pick that opened it is still in flight. Re-armed rather than
                // never cleared, so an overlay that genuinely IS stale still goes.
                if (root.overlayAsked) root.overlayFresh = true
                // ...and the list behind is asked again, because the verb may
                // well have changed it -- Like moves a heart on the very row the
                // card was about. Same menu, so applyDraw patches the rows in
                // place and nothing moves or fades. This is the one round trip a
                // card costs, and it buys correctness rather than a redraw of
                // something unchanged.
                root.refresh(0)
                return
            }
        }
        root.ctxShown = root.ctxHops.slice()
        root.ctxTheme = d.theme || ""
        // HOW ITS ROWS ARE ARRANGED, from the menu that knows. Absent means one
        // column, which is every card but the window-position picker.
        root.ctxColsWanted = d.cols || 1
        // ...AND WHETHER THEY ARE WORDS OR PICTURES, from the same menu. See
        // Util.ui_pick.
        root.ctxCells = d.cells || ""
        // 1-based on the wire, like every index the engine sends.
        root.ctxActive = (typeof d.active === "number") ? d.active - 1 : -1
        // WHICH FACE THIS CARD IS SHOWING, for the one menu that has two. Empty
        // for every other card, which is what tabHere reads to tell them apart.
        root.ctxMode = d.mode || ""
        // THIS CARD'S HEADER IS A FIELD, not a caption -- the search box, and
        // nothing else. See Util.serve_draw's `field` and ctxTitleBar below.
        root.ctxField = d.field === true
        root.ctxMesg = d.mesg || d.prompt || ""
        var list = root.toArray(d.rows)
        // Same rule the body follows: patch where the shape allows it, rebuild
        // where it does not. Liking a track answers with this very menu one word
        // different, and rebuilding it for that would blink the card.
        var patched = root.patchRows(ctxRows, list, root.ctxFilter)
        root.ctxAll = list
        if (!patched) {
            root.ctxFilter = ""
            root.applyCtxFilter()
        }
        // ONLY WHAT THE CARD OWNS. applyIdentity is the BODY's identity -- its
        // scope, its crumb, the trail map, the lyric cues -- and a card is not
        // the body: it is drawn over a list that has not moved.
        //
        // Calling it here is the whole of "the seek menu redraws the list after
        // you pick another track". The Seek card answers with scope `seek`, which
        // was written over the list's own; the card then closes without a draw,
        // so nothing put it back; and the next real draw compared `liked` against
        // a remembered `seek`, decided it was a different menu, and played the
        // whole swap animation over rows that were already correct. See sameMenu.
        //
        // Delete and Tab are the exception: those two keys act on the CARD while
        // it has the keyboard, so it has to say whether they mean anything.
        root.canDelete = d.del === true
        root.canTab = d.tab === true
        root.applyOrigin()
        // The card places its own cursor, and only when it is new -- a patched
        // redraw leaves every row where it was, so moving the cursor would be the
        // card scrolling under a keypress that did not ask it to.
        if (!patched && ctxList) ctxList.currentIndex = 0
        root.measureCtx()
        root.ctxUp = true
        if (!root.opened) root.showPanel()
        // THE SAME LINE THE BODY LOGS. ui/check.sh proves a draw happened by
        // finding one of these, and proves it was not blank by reading its row
        // count -- so a menu that stops logging stops being checked. Shift+Return
        // is one of the seven things that guard drives.
        console.log("render: rows=" + ctxRows.count + " layout=context"
                    + " card=" + root.ctxCardWidth + "x" + root.ctxCardHeight
                    + " theme=" + root.ctxTheme
                    + " trail=" + root.trailPos + "/" + root.hops.length
                    + " crumb=" + JSON.stringify(root.crumb))
    }
    // Any draw that is not a context menu puts the card away. One place, so a
    // route that forgets to close it cannot exist -- and dismiss() and goHome()
    // call it too, because neither goes through a draw.
    function closeContext() {
        root.ctxHops = []
        root.ctxShown = []
        // ABOVE THE GUARD, with the other two. Everything below it is state the
        // card draws with, and dropping that while no card is up is nothing. This
        // one reaches OUT of the card -- it takes the backdrop off the list behind
        // it -- so if it were ever set with ctxUp false it would sit there hiding
        // the cover for the rest of the session with nothing on screen to explain
        // it. applyContext sets the two together today and cannot get between
        // them; cleared here, it cannot start to.
        if (!root.ctxUp) return
        root.ctxUp = false
        root.ctxField = false
        root.ctxFilter = ""
        root.ctxAll = []
        root.ctxColsWanted = 1
        root.ctxCells = ""
        root.ctxActive = -1
        root.ctxMode = ""
        root.cardArt = ""
        root.ctxFlashSrc = -1
        ctxRows.clear()
    }

    function applyDraw(d, quiet) {
        // applyWhere FIRST, then the card. applyWhere is where a card's
        // provisional hops become real, and closeContext throws them away -- so
        // closing first meant a verb that navigated arrived somewhere the trail
        // had no record of: the crumb read three deep and the trail still said
        // one, and Backspace out of the album it opened landed on Main.
        root.applyWhere(d)
        root.closeContext()
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
        var patched = quiet === true && root.patchRows(rows, root.allRows, root.filter)
        if (!patched) applyFilter()
        root.layout = d.layout || "grid"
        root.viewMesg = d.mesg || d.prompt || ""
        // The menu's own word that it has no subject -- see contextCover.wanted,
        // which refuses a backdrop to whole kinds of view; this refuses it to one
        // menu inside a view that otherwise wears one.
        root.noCover = d.art === false
        // ...and whether the cover it DOES wear is whatever is playing. See
        // coverArt: on a shelf the live poll value wins, so the backdrop follows
        // the music rather than the menu.
        root.artLive = d.artLive === true
        // ...AND THE COVER, IF THE DRAW BROUGHT ONE. It does when the picture was
        // already on disk, which closes the gap between the rows arriving and the
        // context-art event that follows them -- the gap in which a shelf still
        // wore the previous track's art. See Util.serve_draw_cover.
        if (typeof d.cover === "string" && d.cover.length) root.contextArt = d.cover
        // ...AND WHO IT IS ABOUT, SAID SEPARATELY. This was inside the branch
        // above, so a shelf that could not ship its cover said nothing about the
        // track either -- and that is the album case exactly. Open an album while
        // a track from somewhere else is playing and it is not a shelf: it wears
        // its own sleeve, no coverFor. Play a track IN it and it becomes one --
        // but the med-res file for those rows was never fetched (they all share
        // one sleeve, so the list draws no per-row thumbs), the cache-only lookup
        // missed, and coverFor went with it. contextArtFor stayed empty, artBehind
        // read false, and the backdrop fell through to the poll -- which still
        // named the track from the other list. That is the flash.
        //
        // Named on its own, artBehind is true for exactly the one poll interval
        // the engine is ahead by, and the album's sleeve -- already correct on
        // screen -- simply stays put until playback agrees with it.
        root.contextArtFor = d.coverFor || ""
        // ...and whether to ask again. A draw that is NOT stale is the refresh
        // having landed, so it also puts the counter back for the next shelf.
        if (d.stale === true) {
            root.drawStale = root.staleTries < 3
        } else {
            root.drawStale = false
            root.staleTries = 0
        }
        // NOT in applyIdentity: this is the PANEL's geometry, and a context menu
        // deliberately leaves the panel shaped like the menu underneath it. The
        // card reads its own theme from root.ctxTheme instead.
        root.themeName = d.theme || ""
        root.applyIdentity(d)
        root.applyOrigin()
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
        // ...AND THE PANEL OPENS ONTO IT. On a cold start showPanel ran before any
        // of this existed and held its animation back for exactly this moment, so
        // the pop happens at the panel's real height rather than growing into it.
        // Warm starts never reach the branch: firstDrawn is long since true.
        if (!root.firstDrawn) {
            root.firstDrawn = true
            if (root.opened && root.showFactor === 0) openAnim.restart()
        }
        // A MENU EXISTS NOW, so a pending `--listen` has something to sit on. Spent
        // on the way past, so a later draw cannot reopen it. See listenWanted.
        // Arming BEFORE clearing the wish, so the dim never lapses between the two
        // -- they are one condition read by one binding.
        if (root.listenWanted) {
            root.listenArming = true
            root.listenWanted = false
            Qt.callLater(root.openListen)
        }
        console.log("render: rows=" + rows.count + " layout=" + root.layout
                    + " panel=" + panel.width + "x" + panel.height
                    + "@" + panel.x + "," + panel.y
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
    // --- THE CONTEXT MENU -------------------------------------------------
    // An action menu, drawn as a card OVER the list it was opened from instead of
    // replacing it. The engine has called these context menus in comments since
    // before the Qt port -- "no Util.scope and no trail step", see
    // Util.open_playlist_actions -- and now says so on the draw itself; this is
    // the half that draws them like one.
    //
    // A CARD LEAVES THE PANEL ALONE: it keeps the menu underneath on screen and
    // shaped exactly as it was, and it owns Escape only while it is up. Every
    // overlay spoot has works this way now -- the viewer, the listener, the
    // sheets and these -- which is why nothing here has to say which kind it is.
    property bool ctxUp: false
    // THE HOPS THAT PRODUCED THE CARD, and the only place they live. An action
    // menu is not somewhere you have been, so opening one costs no trail step, no
    // crumb, no nav.json entry and nothing to walk back into with Alt+left -- the
    // engine is simply asked to answer one more row than the trail describes.
    //
    // They accumulate while the answers keep being menus (an action menu opened
    // from an action menu), and they are thrown away when the card closes --
    // which is why closing costs no request at all: the list underneath never
    // went anywhere, and it is still on screen.
    //
    // The one exception is a verb that NAVIGATES. Then the answer is a real menu,
    // these hops were a journey after all, and they join the trail on the way
    // through -- see applyDraw, where `keep` then trims whichever of them merely
    // acted, exactly as it does for any other step.
    property var ctxHops: []
    // ctxHops AS THE CARD ON SCREEN WAS DRAWN. A verb that answers with nothing
    // -- Albumart, Track Details, anything that opens a viewer instead of a menu
    // -- must leave the card exactly as it is, so the provisional step that asked
    // for it goes back off. Reverting to a snapshot rather than popping one,
    // because an empty answer can also arrive when no card is up at all.
    property var ctxShown: []
    property var ctxAll: []
    property string ctxFilter: ""
    property string ctxMesg: ""
    // Its own theme, kept apart from root.themeName for the same reason its rows
    // are kept apart from `rows`: themeName is the PANEL's geometry and the panel
    // is still the menu underneath.
    property string ctxTheme: ""
    readonly property var ctxG: zenon.geom(root.ctxTheme)
    // THE CARD'S SHAPE, taken from the model and never from the item. bodyHeight
    // grows to hold the card (see bodyHeight), so a card that sized itself against
    // the space it is being given would be a binding loop.
    // HOW MANY COLUMNS THE CARD'S ROWS FLOW INTO. One for every card there is
    // except the window-position picker, which is nine places arranged the way
    // they sit on the screen -- see Util.ui_pick's `cols`. A card that says
    // nothing takes one, which is what every card did before this existed.
    readonly property int ctxCols: Math.max(1, root.ctxColsWanted)
    property int ctxColsWanted: 1
    // WHAT THE CARD'S ROWS ARE. Empty for every card there is except the
    // window-position picker, whose rows are pictures of the screen rather than
    // names of places on it. See Util.ui_pick's `cells` and RowList.cellKind.
    property string ctxCells: ""
    // ...AND WHICH ROW IS THE VALUE IT IS CURRENTLY SET TO, 0-based, or -1. Not
    // the cursor: a picker opens with the cursor wherever it was left and the
    // setting is wherever it is. See RowList.activeIndex, which the lyrics view
    // uses for the same distinction between what is live and where you are.
    property int ctxActive: -1
    // HOW TALL ONE OF THOSE ROWS IS. A row of words is a row of words; a picture
    // of a screen needs to be a shape you can recognise, and a 26px cell three of
    // which have to stack is a line, not a monitor.
    readonly property int ctxRowH: root.ctxCells === "anchor" ? zenon.rowHeight * 3
                                                              : zenon.rowHeight
    // The face a two-faced card is showing -- only the trail menu sends one. See
    // Util.view_trail_jump and tabHere.
    property string ctxMode: ""
    // A CARD THAT TAKES THE BACKDROP DOWN WITH IT.
    //
    // A CARD WHOSE HEADER IS SOMEWHERE TO TYPE. Only the search box asks for it;
    // every other card wears a caption. See QueryField.
    property bool ctxField: false
    // ROWS DOWN THE CARD, which is not the row COUNT once there is more than one
    // column: nine cells in three columns is three rows tall.
    readonly property int ctxRowsUsed: Math.ceil(ctxRows.count / root.ctxCols)
    // ...AND WHAT WILL FIT ON THE OUTPUT. The card is not inside the panel any
    // more, so nothing else is bounding it -- and a card is drawn on the surface,
    // which is the whole screen, so running past that is running off it.
    readonly property int ctxFits: Math.max(1, Math.floor(
        (root.height - zenon.sheetPad * 2 - zenon.rowHeight - zenon.messagePadV * 4)
        / root.ctxRowH))
    // A FIELD CARD MAY LEGITIMATELY HAVE NO ROWS -- a query that matches none of
    // the queries remembered under it -- and the floor of one then reserved a
    // row's worth of ground with nothing in it: a black band under the field as
    // soon as you typed something new. Every other card is a menu of verbs and
    // always has at least one, so the floor stays for those.
    readonly property int ctxLines: {
        var n = Math.min(root.ctxRowsUsed, root.ctxG.lines, root.ctxFits)
        return Math.max(root.ctxField ? 0 : 1, n)
    }
    // THE CAPTION, AS THE MENU WROTE IT. Most cards caption themselves in one
    // line; the trail menu writes two -- what it is, and what Tab does from here,
    // which is the one binding you cannot discover by looking. The card drew a
    // single elided line, so becoming a card cost that menu its hint.
    readonly property var ctxMesgLines:
        root.ctxFilter.length ? [root.ctxFilter + "  \u2500  " + ctxRows.count]
                              : (root.ctxMesg.length ? root.ctxMesg.split("\n") : [""])
    // TITLE BAR, ROWS, EDGE -- and nothing after the rows. The bar carries its own
    // padding (messagePadV either side of the caption) and the rows carry theirs
    // inside each row, so a further messagePadV * 2 under the last one was a band
    // of ground with nothing above or below it to balance against: the card sat
    // flush at the top and loose at the bottom.
    // HOW TALL THE CARD'S HEADER IS -- a caption of one or more lines, or the
    // query field that replaces it. Named once because the bar is drawn from it
    // and the card is sized from it, and those two disagreeing is a card with its
    // rows tucked under its own title.
    readonly property int ctxHeaderH:
        (root.ctxField ? zenon.rowHeight
                       : root.ctxMesgLines.length * zenon.rowHeight)
        + zenon.messagePadV * 2
    readonly property int ctxCardHeight: root.ctxHeaderH
                                       + root.ctxLines * root.ctxRowH
                                       + zenon.borderWidth
    // THE CARD'S OWN BACKDROP, square against its rows -- the same shape the body
    // wears beside a list, at the size the card happens to be. Zero when the card
    // is about nothing picturable, and a Row with a zero-wide first child is a
    // Row with one child, so nothing else has to know.
    readonly property int ctxCoverW: root.cardArt.length ? root.ctxLines * root.ctxRowH : 0
    // AS WIDE AS ITS LONGEST VERB, which is what makes it a card rather than a
    // second panel. The `action` theme declares 1000px because as a FULL menu it
    // had to match the one it was replacing, and a 1000px card over a 1000px panel
    // is just the old behaviour with a border. The theme width becomes a cap.
    //
    // Measured the way PairSheet measures its columns -- TextMetrics knows the
    // width of a string before a single delegate exists -- but assigned from a
    // function rather than computed in a binding, because a binding that WRITES to
    // the thing it reads re-triggers itself.
    property int ctxCardWidth: 0
    function measureCtx() {
        // THE ROWS DECIDE. The caption may widen the card, but only so far: a
        // track's caption is its name, its artist and its album, and letting that
        // set the width outright made the card exactly as wide as the panel it is
        // supposed to be sitting ON -- which is the old full-menu behaviour with a
        // border drawn round it.
        //
        // Half the menu's declared width is where it stops and starts eliding.
        // The verbs are what you act on; the caption is a reminder of what they
        // are about, and a reminder can be trimmed.
        var w = 0
        ctxMetrics.font.bold = false
        for (var i = 0; i < root.ctxAll.length; i++) {
            ctxMetrics.text = String(root.ctxAll[i].label)
            if (ctxMetrics.width > w) w = ctxMetrics.width
        }
        ctxMetrics.font.bold = true
        ctxMetrics.text = root.ctxMesg
        var cap = Math.min(ctxMetrics.width, root.ctxG.width / 2)
        ctxMetrics.font.bold = false
        // ...times the number of columns, because every column has to hold the
        // widest row: a 3x3 measured as though it were a list came out a third of
        // the width it needed and elided all nine cells.
        //
        // NEVER WIDER THAN SPOOT. The card overhangs the panel vertically on
        // purpose -- that is the whole point of it not living in the body -- but
        // a card wider than the window it is sitting on does not read as floating
        // over spoot, it reads as a mistake. Height is what a short list needed;
        // width was never the problem.
        // A FIELD CARD HAS A FLOOR. Every other card is as wide as its longest
        // verb, which is the right answer for a menu and the wrong one for
        // somewhere you type: the search card came out 214px because the queries
        // remembered in it happened to be short, and a box that narrow is not one
        // you would start typing a sentence into. See root.ctxField.
        root.ctxCardWidth = Math.min(root.ctxG.width, panel.width,
                                     Math.max(
                                        root.ctxField ? 500 : 0,
                                        Math.ceil(w + zenon.rowPadH * 4) * root.ctxCols,
                                        Math.ceil(cap) + zenon.rowPadH * 4)
                                     + root.ctxCoverW)
    }
    // The cover is part of the width, and it arrives after the rows -- so the
    // measurement has to be taken again when it lands. measureCtx assigns to the
    // thing a binding would have to read, which is why it is a function.
    onCtxCoverWChanged: root.measureCtx()
    // ...and when it becomes a field, which changes the floor above.
    onCtxFieldChanged: root.measureCtx()
    TextMetrics {
        id: ctxMetrics
        font.family: zenon.fontFamily
        font.pointSize: root.ctxG.rowSize || zenon.fontSize
        font.weight: root.ctxG.rowWeight || zenon.fontWeight
    }
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
    // WHAT THE SHEET CALLS ITSELF, on the bar across its top. A card with no
    // title is a slab of text with no idea what it is about -- and every other
    // floating thing in spoot wears one. See Util.detail_sheet's `title`.
    property string sheetTitle: ""
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
    // Set by the draw. See Util.serve_draw's artLive.
    property bool artLive: false
    // THIS SHELF IS A COPY THE ENGINE KNOWS IS OLD, and the real one is already
    // being fetched. The engine cannot push -- it answers requests and does not
    // speak unprompted -- so landing that refresh on the open that paid for it
    // means asking once more, a moment later, which is all this is.
    //
    // Bounded at three tries, and given up on rather than retried forever: a
    // revalidator that fails leaves the ledger entry in place (see
    // Util.reval_sweep), so `stale` would go on being true and this would go on
    // asking. Three is enough for a refresh that is going to arrive at all.
    property bool drawStale: false
    property int staleTries: 0
    Timer {
        id: staleRetry
        // Long enough that a refresh has usually landed, short enough to read as
        // the list settling rather than as a second visit.
        interval: 1200
        repeat: false
        // NOT OVER ANYTHING THE USER IS IN THE MIDDLE OF. A redraw replaces the
        // body and clears the filter, so asking again under a typed filter would
        // throw away what was typed; under a card or a prompt it would redraw the
        // thing in front instead, which is not what is stale. Every one of those
        // ends by itself, and the next draw re-arms this if the copy is still old.
        //
        // AND THAT INCLUDES A PICTURE, which is the whole of "albumart closes on
        // its own". This named the card and the prompt by hand and forgot the
        // viewer -- so opening a cover over a shelf that happened to be stale
        // armed a 1200ms timer, the refresh it fired came back as a draw, and
        // applyWhere's dropStaleOverlay found an overlay whose freshness had
        // already been spent and closed it. Nothing the user did; a housekeeping
        // round trip walking out through the thing they were looking at.
        //
        // `anythingUp` is the list of things in front of the rows and already
        // exists for exactly this question -- naming three of its four members
        // here was the second copy that fell behind.
        running: root.drawStale && !root.anythingUp && root.filter.length === 0
        // Cleared before the ask, so the binding above settles instead of
        // restarting the timer the moment it fires. The answer decides whether
        // there is another one.
        onTriggered: { root.drawStale = false; root.staleTries++; root.refresh(0) }
    }
    // IS AN OVERLAY IN FLIGHT -- one that has been ASKED for, whether or not it
    // has finished appearing. `artPath` is the request and `artShown` below is the
    // latch; the difference matters, and it used to be decided by whichever
    // spelling each of five copies of this expression happened to use.
    //
    // This is the one a DRAW asks: should this new menu retire the overlay in
    // front of it, and does the keymap belong to that overlay rather than to the
    // rows. See dropStaleOverlay, applyContext and Keymap's modal branch.
    readonly property bool overlayAsked:
        root.sheet.length > 0 || root.sheetRows.length > 0
        || root.artPath.length > 0 || root.listenMode

    // ...AND IS ONE ON SCREEN, which is what a CLICK asks. Off the latch, so it
    // is still true through the fade out -- a picture you can still see is a
    // picture a click should close. Excludes the listener, which every caller
    // handles ahead of this because leaving it means leaving spoot.
    readonly property bool viewerUp:
        root.artShown.length > 0 || root.sheet.length > 0 || root.sheetRows.length > 0

    // ...AND IS ANYTHING AT ALL IN FRONT OF THE ROWS. What makes a click on the
    // list a dismissal rather than a pick -- see RowList.inert and dismissTop,
    // which are the two halves of the same rule and had a copy each.
    readonly property bool anythingUp:
        root.viewerUp || root.promptFor.length > 0 || root.ctxUp

    // WHICH OVERLAYS MOVE THE PANEL. The image viewer does: albumart and an
    // artist's impression are things you look AT, so the panel leaves the bottom
    // edge and centers on the output.
    //
    // LISTENING IS NOT ONE OF THOSE. It is spoot doing something and telling you
    // The listening card, which is the art overlay wearing a different hat: same
    // scrim, same card, same picture slot -- and a different shape, place and
    // caption, because it is a thing working rather than a thing to look at.
    readonly property bool listenMode: root.overlayTheme === "listen"
    // THE PICTURE'S SIZE, TAKEN ONCE WHEN IT OPENS. This used to be read live off
    // root.g -- which falls back to the MENU's geometry the moment overlayTheme
    // clears, and a menu theme names no icon, so it landed on the 400 default. On
    // the way out the listener's 300px image therefore jumped to 400 and the card
    // stretched upward as it faded. An overlay's size is settled when it opens and
    // has no business changing while it is up.
    // LATCHED WHEN THE OVERLAY OPENS, and deliberately not derived from anything.
    // listenMode flips the instant overlayTheme clears -- which is WHILE the card
    // is still fading out -- so every piece of geometry reading it recomputed
    // mid-fade: the padding jumped, the picture jumped, and the card visibly
    // stretched on its way off screen. Measured it doing exactly that: 264x291
    // while listening, 264x1260 one frame after the overlay theme cleared.
    //
    // Behaviour reads listenMode, which must flip at once -- the panel has to come
    // back, the poll has to stop. SHAPE reads these, which must not.
    // `artIsListen` STOOD HERE, latched so the card's geometry would not recompute
    // while it faded out -- the listener and the viewer were one card, so every
    // number in it had two answers and the wrong one arrived mid-fade. They are
    // two items now; this card is the viewer, and it has one answer for everything.
    property int artIcon: 400
    property int artPad: 5
    // WHAT SPOOT SAYS WHILE IT WORKS. A fixed line under a spinner is furniture;
    // a different one each time is the app having a personality for the eight
    // seconds you are looking at it. Picked once per spawn -- see the `listening`
    // event -- so it does not shuffle under you mid-listen.
    readonly property var listenLines: [
        "spoot is listening", "spoot is snooping", "spoot is calibrating",
        "spoot is eavesdropping", "spoot is all ears", "spoot is tuning in",
        "spoot is holding its breath", "spoot is consulting the archives",
        "spoot is narrowing it down", "spoot is pricking up its ears",
        "spoot is checking its notes", "spoot is running the tape back"
    ]
    // WHICH TRACK THE DRAW'S BACKDROP WAS ABOUT, from the context-art event. Empty
    // when the draw did not say -- an older engine, or a menu with no subject.
    property string contextArtFor: ""
    // THE PICTURE A CARD IS ABOUT -- the row it was opened from, or the track the
    // listener just named. Empty when the card is about nothing you can picture,
    // which is most of them: a list of verbs, a confirmation, a settings picker.
    // See Util.serve_card_art.
    property string cardArt: ""
    // THE POLL IS BEHIND THE PICK, for up to its own interval. On a shelf the
    // backdrop follows playback, which is what makes autoplay fade the next cover
    // in with nothing asked of the engine -- and it is also why playing a track out
    // of a DIFFERENT list showed the previous track's cover for a moment: the rows
    // were the new list's, the poll still named the old song.
    //
    // The engine is not behind: Util.play_or_toggle adopts the track the moment the
    // request goes out, so the cover the draw named is already right. So while the
    // poll and the draw disagree about WHICH TRACK, the draw wins; once they agree
    // -- which is the same instant the values become identical anyway -- playback
    // takes back over and autoplay works as before.
    readonly property bool artBehind:
        root.contextArtFor.length > 0 && root.playback.id !== undefined
        && root.contextArtFor !== root.playback.id
    // ...AND IT EXPIRES.
    //
    // The rule above is "the draw is ahead of the poll, so the draw wins until
    // they agree" -- and they only ever agree if the poll catches up to the track
    // the DRAW named. Let the music move on by itself and it never does: the poll
    // goes to a third track, contextArtFor still names the first, artBehind stays
    // true, and the backdrop is pinned to a cover from two tracks ago. With spoot
    // closed there is no new draw to correct it, so it sits there for the rest of
    // the session -- the whole of "the backdrop never changes when spoot is
    // closed".
    //
    // A DEADLINE, not an identity. What the draw's answer is worth is one poll
    // interval of being right; past that the poll is the better witness whatever
    // the two say. So the name is dropped shortly after it is set and playback
    // takes back over -- which is also exactly what autoplay needs.
    onContextArtForChanged: if (root.contextArtFor.length) artForLife.restart()
    Timer {
        id: artForLife
        // Comfortably over the 1s poll and well under a track, so it covers the
        // gap it exists for and nothing else.
        interval: 1600
        onTriggered: root.contextArtFor = ""
    }
    readonly property string coverArt:
        root.artLive
            ? (root.artBehind ? (root.contextArt || root.playback.art || "")
                              : (root.playback.art || root.contextArt))
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
    // -- left-aligns the lines it wraps onto. Only a text item centers each of
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
    // WHAT THE STEP YOU ARE ON SAYS, now that it is the only thing saying it.
    //
    // The trail's name for a step is deliberately short -- "Liked Tracks" -- and
    // the title row above it carried the engine's detailed version of the same
    // thing, "Liked Tracks  ⋯  691 tracks". That row is gone (see nowRow, which
    // took its place), so the detail has nowhere else to live: the last step
    // carries it instead. It is also the only step this can be done to, because
    // it is the only one that is not a destination you click back to -- the ones
    // behind you have to stay the short names they are addressed by.
    //
    // ...AND WHAT YOU TYPED WINS OVER BOTH, for exactly the reason the title row
    // gave: while filtering, the thing you want to see is your own query and how
    // much of the list it left. That feedback had no other home either.
    //
    // Not while COMPOSING -- the search box and the name prompts draw the text
    // you are typing in a field of their own, and echoing it here as well was the
    // message bar standing in for a widget that was missing.
    readonly property string crumbHere: {
        if (root.filter.length && !root.composing)
            return root.filter + "  \u2500  " + rows.count
        return root.viewMesg
    }
    readonly property string crumbHtml: {
        var out = ""
        for (var i = 0; i < root.crumb.length; i++) {
            var seam = (root.crumbRoots || []).indexOf(i) >= 0
            // The step you are ON is not a destination -- and now that the cursor
            // can sit anywhere along the trail, it has to SHOW. Bright means
            // "here", the same colour the root seams use; the steps behind stay
            // dim until hovered.
            var last = (i === root.crumb.length - 1)
            var col = last ? zenon.crumbRoot
                           : (root.crumbHover === i ? zenon.foreground : zenon.dim)
            // THE ARROW BELONGS TO THE STEP IT INTRODUCES, and takes its colour.
            // It had a grey of its own -- darker than the dimmest step -- which
            // read as a chain of bright words strung on something else's rule.
            // The root SEAM keeps its own colour: that glyph is not punctuation
            // between steps, it is the mark that says a different trail starts
            // here, and it has to carry across whatever the steps either side of
            // it are doing.
            if (i > 0) out += root.crumbSpan(seam ? zenon.crumbRoot : col,
                                             root.crumbSep(seam))
            // The step you are ON says it in full; every step behind it keeps the
            // short name it is addressed by. See root.crumbHere.
            var name = (last && root.crumbHere.length) ? root.crumbHere : root.crumb[i]
            out += root.crumbSpan(col, root.esc(name), last ? undefined : i)
        }
        // What you stepped back OUT of, held at the arrow's own grey so it reads
        // as a path not taken rather than another destination.
        //
        // ...AND CLICKABLE NOW, which it was not. It was inert on the grounds that
        // one path step can spend two crumb parts, so a click could not say
        // honestly where it would land -- true, and it was equally true of the
        // steps BEHIND you, which were clickable all along and quietly did nothing
        // for exactly that reason. jumpToCrumb answers it for both directions now:
        // the nearest depth at or before the part you clicked, which for a
        // qualified step is the one place both of its parts describe.
        //
        // Walking back and then forward again by clicking is the same gesture
        // twice, and having only one half of it work read as the trail being
        // half a control.
        for (var j = 0; j < root.crumbAhead.length; j++) {
            var k = root.crumb.length + j
            // Arrow and step in ONE span, so the two share a colour here for the
            // same reason they do above -- these are all at the walked-out grey
            // rather than at the step's own, and brighten under the pointer
            // exactly as a step behind you does.
            out += root.crumbSpan(root.crumbHover === k ? zenon.foreground
                                                        : zenon.crumbArrow,
                                  root.crumbSep((root.fullRoots || []).indexOf(k) >= 0)
                                  + root.esc(root.crumbAhead[j]), k)
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
    // A MAXIMUM, NOT A COUNT. The setting says how many covers may go across;
    // a shelf with five things on it has no use for ten columns, and dividing
    // the panel by ten anyway would draw those five at a tenth of the width
    // each with half the window empty beside them. So the grid uses whichever
    // is smaller, and a small shelf lays out at full size.
    readonly property int columns: Math.max(1, Math.min(root.menuG.columns,
                                                        rows.count || root.menuG.columns))
    // The width one cell gets, which is what decides how big its cover can be.
    // The body is the panel inside its border, and the grid divides that -- by
    // the columns it is ACTUALLY using, so the cover only shrinks when there are
    // genuinely that many of them.
    readonly property int cellW: Math.floor((root.menuG.width - zenon.borderWidth * 2)
                                           / Math.max(1, root.columns))
    // HOW MANY ROWS THE BODY ACTUALLY DRAWS -- what is on screen, not what the
    // page allows, which is what bodyHeight multiplies by.
    readonly property int usedRows: Math.min(Math.ceil(rows.count / Math.max(1, root.columns)),
                                             root.menuG.lines)
    // WHICHEVER LIST HAS THE KEYBOARD. A context menu is modal but NAVIGABLE, so
    // its keys cannot be swallowed the way a sheet swallows them -- they have to
    // reach the card instead of the body. Named once here rather than branched
    // inside each of the six functions that move a cursor or read a row, which
    // is the difference between one routing rule and six.
    readonly property var focusItem: root.ctxUp ? ctxList : body.item
    readonly property var focusModel: root.ctxUp ? ctxRows : rows
    readonly property var focusG: root.ctxUp ? root.ctxG : root.menuG
    // ...AND HOW MANY COLUMNS IT IS ACTUALLY DRAWN IN, which is not what its
    // theme declares. A card's columns come from the menu that sent it (ctxCols --
    // the window-position picker is three wide and its theme says nothing), and
    // the body clamps the theme's count to the number of rows it actually has, so
    // a shelf of three tiles is three columns and not five.
    //
    // move() read focusG.columns, so Down in the 3x3 picker stepped one cell
    // instead of one row -- "cursor movement is not all-directional" -- and Down
    // in a short grid overshot the row below it.
    readonly property int focusCols: root.ctxUp ? root.ctxCols : root.columns
    // AN OVERLAY THAT *IS* THE PANEL BRINGS ITS OWN GEOMETRY -- a details sheet
    // slides over the rows and takes the whole window, so the window becomes the
    // shape the sheet asks for.
    // NOTHING OVERRULES IT ANY MORE. This used to switch on `overlayTheme`, which
    // meant an artist impression squeezed the menu behind it from 1000px down to
    // art.rasi's 640 and sprang it back on close -- the main window being
    // compressed. That was narrowed to sheets, and now that a sheet floats too
    // there is no overlay left that reshapes the panel: `g` is simply the menu's.
    readonly property var g: root.menuG
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
    // ...AND ENTRIES FOR HOPS THAT NO LONGER EXIST ARE LIES. This is keyed on how
    // deep the crumb read, so `trailMap[3]` recorded on one branch is answered to
    // `trailMap[3]` asked on another -- and every branch is three deep sooner or
    // later. Clicking a crumb step then restored a cursor position from a trail
    // nobody had walked in a while: the crumb still read correctly (it comes from
    // the draw), so nothing looked wrong until the next step was sent. It is the
    // same shape of fault as the pre-step snapshot preHops used to keep, and the
    // same answer -- invalidate it the moment the thing it describes is gone.
    //
    // WHAT SURVIVES A TRUNCATION is everything at or before the cut: those entries
    // name hops that are still there, in the same order, so they still describe the
    // same places. Only what was ahead of the cursor goes.
    function forgetAhead(pos) {
        var keep = ({})
        for (var k in root.trailMap)
            if (root.trailMap[k] <= pos) keep[k] = root.trailMap[k]
        root.trailMap = keep
    }
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
    // WHERE A FLOATING CARD SITS. Centred on the PANEL -- a card is about what
    // spoot is showing, so it belongs over spoot rather than in the middle of the
    // desktop the way the image viewer does -- and then pushed back inside the
    // screen, because a card taller than the panel, centred on a panel docked to
    // the bottom edge, would hang off the output entirely.
    //
    // PANEL-LOCAL, since every caller is a child of the panel: panel.x/panel.y
    // convert to the surface, which is the whole output (see root.width).
    //
    // One expression per axis, and placed rather than anchored, for the reason the
    // art card is (see its x and y): an item anchored two ways on one axis
    // stretches, and clearing an anchor by binding it to undefined does not
    // reliably let go.
    function cardX(w) {
        var lo = zenon.sheetPad - panel.x
        var hi = root.width - zenon.sheetPad - w - panel.x
        return Math.round(Math.max(Math.min((panel.width - w) / 2, hi), lo))
    }
    function cardY(h) {
        var lo = zenon.sheetPad - panel.y
        var hi = root.height - zenon.sheetPad - h - panel.y
        return Math.round(Math.max(Math.min((panel.height - h) / 2, hi), lo))
    }

    function posKey() {
        return root.entryCmd + "|" + root.entryKey + "|" + JSON.stringify(root.path)
    }
    function rememberPos() {
        // NOT WHILE A CARD IS UP. posKey() names the path, and with a context
        // menu open the path includes the step that opened it -- so this would
        // file the LIST's cursor under the CARD's key and grow `positions` a dead
        // entry per action menu. The list's own cursor was already stored on the
        // way in, by the activate() that opened the card.
        if (root.ctxUp) return
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
        // GOING SOMEWHERE RESETS THE BUDGET. Only the stale retry asks with a
        // direction of zero, so anything else is a new place and gets its own
        // three tries. See staleRetry.
        if (root.navDir !== 0) root.staleTries = 0
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
                                   // BESIDE the trail, never in it. See ctxHops:
                                   // the engine walks these and then leaves them
                                   // out of the crumb, out of what it echoes back
                                   // and out of nav.json.
                                   tail: root.ctxHops,
                                   // The deepest crumb this trail reached -- or,
                                   // when nothing is ahead of the cursor, simply
                                   // the one on screen. It used to send only the
                                   // former, and pushHop clears that: so the trail
                                   // menu, which is opened BY a pushHop, was handed
                                   // an empty path and fell back to listing the one
                                   // segment the engine can see by itself.
                                   tip: root.fullCrumb.length ? root.fullCrumb : root.crumb,
                                   tipRoots: root.fullCrumb.length ? root.fullRoots
                                                                   : root.crumbRoots},
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
    // A VIEW THAT IS A CARD, opened BESIDE the trail rather than onto it. Some
    // views the engine serves draw a floating card and nothing else -- Seek is
    // eight verbs about the track already playing, the listener's result is one
    // track it just recognised -- and neither is a place you have gone to.
    //
    // Put on the trail they behaved like one, which is both of the things wrong
    // with Seek: the crumb grew a step, so backing out had to take that step off,
    // and taking a step off the trail means a round trip -- the parent list was
    // fetched and redrawn although it had never gone anywhere. Beside it, closing
    // is exactly closeContext() and costs nothing (see goBack).
    //
    // The engine agrees on its own: a hop sent as `tail` is walked and then left
    // out of the crumb, which is what views.sh's ctx: probes pin.
    //
    // This was open-coded at the listener's result and nowhere else, which is why
    // that one card behaved correctly and Seek did not.
    function openCard(name) {
        root.ctxHops = root.ctxHops.concat([{cmd: "view", key: name}])
        root.refresh()
    }
    // alt is Shift+Return: the engine turns it into Util.alt_pressed, which is
    // exactly what rofi's exit code does, so the view opens its action menu.
    // True while the Search view is showing its history and nothing has been
    // submitted: there, what you type is a QUERY, not a filter over the history.
    // rofi expressed this with `custom` on the menu; here it is one predicate.
    // THE SEARCH BOX IS UP. It used to be a VIEW you had navigated to -- "the
    // search menu, before a query has been submitted" -- and it is a card now, so
    // the card says so for itself. See ctxField and Util.serve_draw's `field`.
    readonly property bool isSearchPrompt: root.ctxUp && root.ctxField
    // WHAT YOU TYPE IS TEXT TO SUBMIT, not a filter over rows: the search box,
    // and the prompts that ask for a name (New Playlist, Rename Playlist).
    // Everywhere else -- search RESULTS included, since those are an ordinary
    // list once the query has been answered -- typing narrows what is on screen.
    //
    // Named rather than spelled out at each use: the filter, the message bar and
    // Backspace all have to agree about which kind of typing this is, and they
    // were agreeing by coincidence.
    readonly property bool composing: root.isSearchPrompt || root.promptFor.length > 0
    // A FIELD IS UP, whichever of the two it is: a prompt the engine raised (New
    // Playlist, Rename) or the search box. They are the same thing -- somewhere
    // to type, floating over whatever you were looking at -- and the search box
    // used to be a bar inside the panel instead, which is one widget written
    // twice. See promptCard, and the note where the input bar stood.
    // Only the engine's own prompts float on their own card now: the search box
    // lives in the header of the search card, with its history under it.
    readonly property bool fieldUp: root.promptFor.length > 0
    // What it is asking for. The engine names its own prompts; the search box is
    // the one whose label this side knows.
    readonly property string fieldLabel:
        root.promptFor.length > 0 ? root.promptFor : "Search"
    // ...and WHETHER TYPING NARROWS THE ROWS, which is a different question and
    // was answered by `composing` only because nobody had asked it separately.
    //
    // Everywhere but a prompt asking for a NAME -- New Playlist, Rename -- where
    // what is on screen is not a menu you are choosing from and there is nothing
    // for the characters to narrow.
    //
    // The search box DOES narrow now. The query you are typing and a filter over
    // your past queries are the same characters, so a history of thirty searches
    // gets out of the way while you type the thirty-first instead of sitting there
    // whole. Return still submits what you TYPED rather than the row under the
    // cursor -- free text wins there, as it does in rofi -- so narrowing the list
    // underneath costs nothing and reaches an old query in fewer keys.
    readonly property bool narrows: root.promptFor.length === 0

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
    // IS THERE A PLAYER BEHIND ANY OF THIS. The poll always names a track -- on a
    // cold start, the last one Spotify remembers, hours old and loaded nowhere --
    // and until the engine started saying so there was no way to tell that apart
    // from a track paused a moment ago. See Util.played_here.
    readonly property bool playbackLive: root.playback.live === true
    // YOU PICKED SOMETHING, so the cursor is spent. The engine says the same on
    // its next poll -- picking a track plays it, and playback then has a player
    // behind it -- but a poll is up to a second away and the acknowledgement of a
    // keypress cannot be. Never reset: "selecting any track removes the cursor" is
    // about the selection, not about whether the track turned out to be playable.
    property bool picked: false
    // WHERE YOU LEFT OFF. Empty as soon as either of the above says the question
    // has been answered, which is why no view needs to know any of this.
    //
    // A `replaySession` TEST STOOD HERE, gating these on the setting from the UI
    // side. The engine answers it now -- with Session Replay off and nothing
    // played this session, Util.serve_playback reports no track at all -- so
    // `playback.id` is already empty and a second copy of the rule over here was
    // one more place to keep in agreement with it.
    readonly property string lastId:
        (root.playbackLive || root.picked) ? "" : (root.playback.id || "")
    readonly property string lastAlbumId:
        (root.playbackLive || root.picked) ? "" : (root.playback.albumId || "")
    // ...and the marker's own id, which is now the one that has to be earned.
    readonly property string liveId: root.playbackLive ? (root.playback.id || "") : ""
    // The same track's other id, where Spotify relinked it. See RowList's
    // playingAltId and the engine's serve_playback.
    readonly property string liveAltId:
        root.playbackLive ? (root.playback.altId || "") : ""
    readonly property string liveAlbumId:
        root.playbackLive ? (root.playback.albumId || "") : ""
    property int flashSrc: -1
    property int flashSeq: 0
    // The card's own pair. Both lists match a flash by `src`, so one shared
    // counter had picking the third verb in a card sweep the third ROW of the
    // list behind it at the same moment -- an acknowledgement of something
    // nobody touched.
    property int ctxFlashSrc: -1
    property int ctxFlashSeq: 0
    function flashRow(i) {
        var m = root.focusModel
        if (i < 0 || i >= m.count) return
        if (root.ctxUp) { root.ctxFlashSrc = m.get(i).src; root.ctxFlashSeq++; return }
        root.flashSrc = m.get(i).src
        root.flashSeq++
    }

    function activate(i, alt) {
        // NOT WHILE THE LIST UNDER THE POINTER IS ON ITS WAY OUT.
        //
        // A pick is an INDEX -- `src` below, the row's position in the unfiltered
        // list -- and the engine replays it against whatever menu it draws at that
        // depth. render holds an arriving draw and animates the old body out
        // first, and for the whole of that fade the previous rows are still in the
        // model and still under the pointer: a click there computes its index
        // against a list the engine has already moved past, and every index after
        // it in the path is shifted by one.
        //
        // swapOut/heldDraw and not root.inFlight, which would be the wrong gate: a
        // sticky card fires pick after pick against requests still in flight by
        // design -- that is what Seek is -- and none of those swap anything.
        if (swapOut.running || root.heldDraw) return
        root.rememberPos()
        root.flashRow(i)
        // The cursor is spent. See root.picked -- picking THIS row or any other is
        // the answer to the question it was asking. Not a verb in a card, which
        // is a choice ABOUT a track rather than a choice of one; the ones that do
        // start playback set it the honest way, through the engine's next poll.
        if (!root.ctxUp) root.picked = true
        // Main's tiles are OPENED, not stepped into -- but only Main's own. A card
        // in front of them is a list of verbs, and its rows carry no tile key at
        // all, so this branch would have opened `undefined`.
        if (root.entryCmd === "main" && !root.ctxUp) {
            var tile = rows.count ? rows.get(i).key : ""
            // SHIFT+RETURN ON PLAYBACK IS THE PLAYING TRACK'S ACTION MENU -- the
            // same destination the key reaches from any track row, so the tile
            // behaves like the row it stands in for.
            //
            // Sent as a CARD rather than as a step, because Main is not a menu
            // the engine walks: Util.serve_main builds the grid and answers,
            // reading no path, so a step aimed at it did nothing at all and Main
            // simply redrew. `track-actions` is the same view by name.
            if (alt) {
                if (tile === "playback") { root.openCard("track-actions"); return }
                // No other tile offers a second gesture; treat the key as plain
                // rather than dropping the press.
            }
            if (tile.length) root.openTile(tile)
            return
        }
        var m = root.focusModel
        // The step this pick will send, built once here because the index inside
        // it is also what the flash, the cursor memory and `lastSrc` are keyed by
        // -- see root.rowStep, which is where "which row is this" is decided.
        var step = root.rowStep(m, i, alt ? {alt: true} : {})
        var src = step.i
        // A prompt is waiting: what you typed IS the answer. Same string-step
        // mechanism the search box uses.
        if (root.promptFor.length) {
            // liveFilter for the reason the search branch below takes it: the two
            // are the same string whenever no card is up, and only one of them
            // stays right if one ever is.
            root.pushHop({step: root.liveFilter})
            root.promptFor = ""; root.setFilter(""); root.refresh()
            return
        }
        if (root.isSearchPrompt && root.liveFilter.length) {
            // Free-typed text wins over the highlighted history row, exactly as
            // it does in rofi when custom input is enabled.
            //
            // ON THE CARD'S OWN STEPS, not on the trail. The search box is a card
            // and its step lives in ctxHops; pushHop would call closeContext and
            // drop that step, so the trail would gain the query with no Search in
            // front of it and the engine would replay it against the wrong menu.
            // Sent as a card step, the answer is a real menu -- the results -- and
            // applyWhere adopts BOTH steps onto the trail when it lands.
            root.ctxHops = root.ctxHops.concat([{step: root.liveFilter}])
            root.setFilter(""); root.refresh()
            return
        }
        // THE ROW THIS STEP PICKED, remembered so a `copied` event coming back
        // has something to mark. By `src` -- its index in the unfiltered list --
        // rather than by position: the draw that follows clears the filter, so
        // the row moves, and only src stays put through that.
        root.lastSrc = (root.ctxUp && root.ctxSubjectSrc > 0) ? root.ctxSubjectSrc : src
        // ...and the cursor is remembered by src for the same reason. rememberPos
        // stored where the row was among the FILTERED ones, so picking the third
        // match of a search put the cursor on the third row of the whole list
        // once the filter cleared -- somewhere you had not been looking at.
        //
        // Not for a card: `positions` is keyed by the view you are standing in,
        // and the card is not it. Writing there would move the LIST's cursor to
        // wherever a verb happened to sit.
        if (!root.ctxUp && root.filter.length && src > 0) root.positions[posKey()] = src - 1
        // Lua is 1-based, and so are the indices rofi hands back.
        // PROVISIONAL, when this is a card's step or the gesture that opens one.
        // Shift+Return on a row IS that gesture everywhere it does anything, and
        // every menu it reaches answers `context`. If one ever does not, applyWhere
        // adopts the hop into the trail and the result is exactly what pushHop
        // would have given -- so the wrong guess costs nothing.
        var hop = {step: step}
        if (root.ctxUp || alt) root.ctxHops = root.ctxHops.concat([hop])
        else root.pushHop(hop)
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
    function cancelPrompt() {
        root.promptFor = ""
        root.setFilter("")
        // AND THE STEP GOES WITH IT. While the field is up that step is still an
        // answer waiting for its second half (see the prompt event); abandoned,
        // it is a row that would open the field again on the next refresh.
        root.popTransient()
    }

    function closeOverlay() {
        // GIVING UP STOPS THE RECORDER. Nothing used to: the card went away and
        // songrec kept the audio monitor until it timed out, which is why a
        // second attempt could find the device busy and why killing spoot left it
        // running. Sent before the state is cleared, while we still know it was a
        // listen that is being abandoned.
        if (root.listenMode) root.call("listen-stop", {})
        // LEAVING THE IMAGE VIEWER USED TO BE AN ARRIVAL. The viewer moved the
        // panel -- it centered on the screen and came back to the bottom edge --
        // so dismissing it did not reveal the menu, it brought the panel home,
        // and the open animation was replayed to be that journey.
        //
        // The viewer draws on the surface now and the panel never leaves the
        // bottom edge, so there is no journey to play and the whole blank-clear-
        // reopen dance it needed has gone with it. Closing a viewer is a change
        // of what is on top and nothing else.
        root.sheet = ""
        root.sheetRows = []
        root.sheetKind = ""
        root.sheetTitle = ""
        root.artPath = ""
        root.overlayTheme = ""
        root.listenArming = false
        // A CALL TO snapToCursor STOOD HERE, putting the list back after a sheet
        // had finished resizing the panel: every column boundary moved with it,
        // so the cursor's row was no longer where the scroll position said it
        // was, and the list showed two half-columns of text. Nothing resizes the
        // panel any more -- see sheetCard -- so there is nothing to put back.
    }

    // Overlays (art, sheets) arrive as EVENTS, before the response that carries
    // `keep`. Dropping the step that opened one immediately is what stops the
    // viewer re-summoning itself on the next refresh.

    function popTransient() {
        if (root.trailPos <= 0) return
        root.hops = root.hops.slice(0, root.trailPos - 1)
        root.trailPos = root.hops.length
        root.forgetAhead(root.trailPos)
    }

    // OPENING AND CLOSING, as one gesture. 0 is gone, 1 is here; the panel reads
    // both its scale and its opacity off it, so it expands and fades together
    // rather than doing one and then the other.
    //
    // Cold and warm are the same animation on purpose -- from the outside they
    // are the same act, and a resident process that reappeared differently from
    // a fresh one would only be advertising its own plumbing.
    //
    // TWO VALUES AGAIN, and this time they have to be. `showFactor` is the fade
    // and is clamped at 1 by definition; `riseFactor` is the geometry and
    // deliberately goes past 1 and comes back, which is the settle. One value
    // could carry both only while nothing overshot.
    property real showFactor: 0
    property real riseFactor: 0
    // Dimmed all the way out while the listener is up. Its own property so it can
    // be eased without easing the open and close, which animate showFactor
    // themselves -- see the panel's opacity.
    // Not readonly: a Behavior animates the property it is attached to, which a
    // read-only one forbids. The binding still drives it.
    property real listenDim: (root.listenMode || root.listenArming || root.listenExit
                              || root.listenWanted) ? 0 : 1
    // WHILE THE LISTENER IS ON ITS WAY, TOO. listenMode only flips when the
    // `listening` event lands, and that is a round trip behind the key: the host
    // reveals the window FIRST (see the socket handler in main.cpp), so the menu
    // popped in at full size and full opacity and then dimmed out again the
    // moment the engine answered. That is the flash. Armed the instant the view
    // is asked for, so the panel never comes up at all.
    property bool listenArming: false
    // ...AND IT STAYS DOWN ON THE WAY OUT. Escape out of the listener LEAVES --
    // you asked spoot to name a song, not to browse -- and the keymap does that
    // as closeOverlay() then dismiss(). The first drops listenMode, so the dim
    // began easing back to 1 while the second was already flying the panel out:
    // opacity is showFactor * listenDim, one falling and one rising, and their
    // product peaked in the middle. That is the flash on the way out. Held at 0
    // for the length of the close instead, so what leaves is what was there.
    property bool listenExit: false
    // ...AND NOT EASED WHEN THE PANEL WAS NOT THERE. Every `spoot --listen` goes
    // through reveal(), which puts showFactor back to 0 before openListen runs --
    // so the arm lands while there is nothing on screen and the dim can be
    // instant. Opened from inside spoot the panel IS up, showFactor is 1, and it
    // fades the way it always did.
    Behavior on listenDim {
        enabled: root.showFactor > 0
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }
    // IT POPS. Out of its own center, past full size by a hair, and back --
    // fast enough that the overshoot is felt rather than watched. A panel that
    // floats has no edge to unfold from, so it expands from the middle of
    // itself, which is the only point on it that is not going anywhere.
    //
    // 0.90 is the whole of the growth. Smaller reads as a zoom, and at this
    // speed a zoom is a flicker.
    readonly property real panelScale: 0.94 + 0.06 * root.riseFactor
    // Guards against replaying the open on a redraw, and against the first cold
    // reveal being missed: `Shell` is handed to QML after the file has loaded, so
    // whichever of the two triggers below arrives first is the one that opens it.
    property bool opened: false
    // THE POP, softened. Still out of the center and still quick, but the
    // numbers that made it snap are the numbers that made it read as a jolt: a
    // 0.10 growth at overshoot 2.6 in 170ms is nearly three times full speed at
    // the moment it crosses 1. Two thirds of the travel over a longer 210ms, at
    // an overshoot you feel rather than see, is the same gesture without the
    // whip-crack -- and the pixels move slowly enough for the compositor to have
    // something to interpolate, which is most of what "smooth" is.
    ParallelAnimation {
        id: openAnim
        NumberAnimation {
            target: root; property: "showFactor"
            to: 1; duration: 120; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: root; property: "riseFactor"
            to: 1; duration: zenon.popIn
            easing.type: Easing.OutBack; easing.overshoot: zenon.popBack
        }
    }
    // AND OUT, at the open's pace rather than faster than it. The close was
    // shorter and its wind-up nearly as large, which put more travel into less
    // time -- so the half of the gesture with the least to say was the half that
    // moved quickest, and that is what read as rough. 190ms against the open's
    // 210, at a smaller overshoot, makes them the same move in both directions.
    // The fade still waits until the shrink is mostly done: go out together and
    // it is a dissolve; go out last and the panel is seen to leave. Both halves
    // land on the same frame.
    ParallelAnimation {
        id: closeAnim
        NumberAnimation {
            target: root; property: "riseFactor"
            to: 0; duration: zenon.popOut
            easing.type: Easing.InBack; easing.overshoot: zenon.popBackOut
        }
        SequentialAnimation {
            PauseAnimation { duration: 90 }
            NumberAnimation {
                target: root; property: "showFactor"
                to: 0; duration: 100; easing.type: Easing.InOutSine
            }
        }
        // The surface goes away only once the animation has played. Hiding first
        // and animating after would animate nothing, in a window nobody can see.
        onFinished: if (typeof Shell !== "undefined") Shell.conceal()
    }
    function showPanel() {
        root.opened = true
        // A NEW SUMMON IS NOT THE LAST ONE'S EXIT. Cleared before showFactor goes
        // back to 0, so the dim is restored instantly rather than eased -- the
        // same gate the Behavior uses. See listenExit.
        root.listenExit = false
        closeAnim.stop()
        // From the bottom of the curve every time. Restarting without this would
        // begin wherever a half-finished close had left it.
        root.showFactor = 0
        root.riseFactor = 0
        // ...AND ONLY ONCE THERE IS SOMETHING TO OPEN ONTO.
        //
        // A warm summon has rows already and pops at its real height. A COLD start
        // is revealed by the host before the first draw has landed, so the same
        // animation played against an empty body -- the panel appeared as a sliver
        // and then grew as the rows arrived. The first render says so plainly:
        // `panel=1000x1`.
        //
        // Deferred to that draw instead (see firstDrawn in render), which is the
        // only moment the two starts differ at all.
        if (root.firstDrawn) openAnim.restart()
        // ...AND THE BACKDROP CATCHES UP. Everything else on the panel is a
        // binding and is simply correct by the time it is drawn; the cover is a
        // cross-fade, and an animation started while the window was hidden has
        // no reason to have advanced. See coverTop.settle -- it is a no-op
        // unless the top image is decoded and still invisible.
        coverTop.settle()
    }
    // THE EDGE, while the panel is away. A second layer surface -- see Dock.qml
    // and Shell::dockRegion -- armed the moment spoot closes and unmapped by the
    // host the moment it opens. Declared here rather than as a root of its own so
    // it reads the playback state that is already live in this file: the poll runs
    // whether or not the panel is up, which is what makes the dock a window onto
    // the same state rather than a second copy of it.
    // ONE PER MONITOR. A layer surface binds to a single output, so a single dock
    // armed exactly one screen and the edge you walked into on any other was
    // dead. An Instantiator rather than a Repeater because these are Windows, not
    // Items -- there is nothing to lay out, only to exist.
    Instantiator {
        model: Qt.application.screens
        delegate: Dock {
            required property var modelData
            theme: zenon
            playback: root.playback
            positionMs: root.positionMs
            art: root.playback.art || ""
            icons: root.playback.icons || ""
            liked: root.playback.liked === true
            anchorV: root.anchorV
            anchorH: root.anchorH
            screenName: modelData.name
            scrW: modelData.width
            scrH: modelData.height
            scrX: modelData.virtualX
            scrY: modelData.virtualY
            tracked: root.cursorTracked
            curX: root.cursorX
            curY: root.cursorY
            // Not while spoot itself is up -- the host unmaps every dock on reveal
            // for the same reason, since both are overlay surfaces on the same
            // edge -- and not at all when it is switched off. Unarmed means no
            // surface is mapped rather than one mapped and hidden, so turning it
            // off costs nothing at all. Defaults to on: `!== false` rather than a
            // truth test, so a settings payload that predates the key still gets
            // the dock rather than silently losing it.
            armed: !root.opened && root.settings.dock !== false
            onOpenRequested: if (typeof Shell !== "undefined") Shell.reveal()
            onActionsRequested: {
                if (typeof Shell !== "undefined") Shell.reveal()
                root.openCard("track-actions")
            }
            onControlRequested: function (action, by) {
                root.control(action, by === 0 ? undefined : by)
            }
        }
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
        // WHERE THE POINTER IS, while spoot is closed. The docks read it to know
        // you are approaching their edge without accepting input over it -- see
        // Shell::watchCursor and Dock.qml's trackedNear.
        function onCursorMoved(x, y) { root.cursorX = x; root.cursorY = y }
    }
    property int cursorX: -1
    property int cursorY: -1
    // Only Hyprland answers `cursorpos`; anywhere else the docks fall back to a
    // shallow band you have to touch. Asked once, because the answer is about the
    // session and cannot change inside it.
    readonly property bool cursorTracked:
        (typeof Shell !== "undefined") && Shell.cursorWatchable()
    // Watched only while the panel is away, which is the only time a dock is up.
    // Spoot starts revealed, so the watch starts off and the first dismiss turns
    // it on -- no second Component.onCompleted needed (there is already one on
    // this object, and two is a parse error rather than two handlers).
    onOpenedChanged: if (typeof Shell !== "undefined") Shell.watchCursor(!root.opened)
    // Appended as a root like any other jump, so the trail you were on is still
    // behind you and Alt+left walks back into it. Nothing happens if you are
    // already standing there, which is what makes pressing the keybind twice
    // harmless rather than a second thirty-second recording.
    function openListen() {
        // ALREADY LISTENING IS NOTHING TO DO. Pressing the keybind twice must not
        // be a second thirty-second recording, and must not re-arm the dim for a
        // listen that is already up.
        if (root.listenMode) return
        // A COMMAND, NOT A VIEW. It used to be openView("listen"), which put a hop
        // on the trail for something that draws no menu -- and because the draw
        // comes back empty, applyWhere never ran, so the hop was never adopted or
        // trimmed and stayed there. Every navigation after that replayed it and
        // started another recording. See the note in the engine where the `listen`
        // view used to be.
        root.listenArming = true
        // CLEARED BY THE REPLY, which is the only answer there is now. As a view
        // this was cleared by the draw -- but a command draws nothing, so a listen
        // that cannot start (no songrec, no sink) would have left the panel dimmed
        // to zero with nothing coming to undo it. Either the `listening` event
        // arrived first and listenMode holds the dim from here, or it did not and
        // the panel comes straight back.
        root.call("listen-start", {}, function () { root.listenArming = false })
    }

    // THE VIEWER ARRIVES THE WAY THE PANEL DOES. A cover and an artist's
    // impression are the two things in spoot that appear as a whole object over
    // everything else, which is what the panel is -- and they were fading in and
    // out on a plain 140ms curve while the panel next to them popped. Two
    // gestures for the same act, and the smaller one looked like a placeholder.
    //
    // Same two values and the same reason for two: `artShowFactor` is the fade
    // and stops at 1, `artRiseFactor` is the geometry and overshoots. Same
    // tokens, so tuning the gesture tunes it everywhere.
    property real artShowFactor: 0
    property real artRiseFactor: 0
    readonly property real artScale: 0.94 + 0.06 * root.artRiseFactor
    // THE PICTURE THE CARD IS DRAWING, as opposed to the one it has been asked
    // for. Latched exactly like artIcon and artPad above, and for the sharper
    // version of the same reason: closing is now an animation, and artPath is
    // cleared the instant the close begins -- so the card spent the whole of its
    // exit shrinking around an empty Image. It keeps the picture until the close
    // has landed.
    property string artShown: ""
    ParallelAnimation {
        id: artOpenAnim
        NumberAnimation {
            target: root; property: "artShowFactor"
            to: 1; duration: 120; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: root; property: "artRiseFactor"
            to: 1; duration: zenon.popIn
            easing.type: Easing.OutBack; easing.overshoot: zenon.popBack
        }
    }
    ParallelAnimation {
        id: artCloseAnim
        NumberAnimation {
            target: root; property: "artRiseFactor"
            to: 0; duration: zenon.popOut
            easing.type: Easing.InBack; easing.overshoot: zenon.popBackOut
        }
        SequentialAnimation {
            PauseAnimation { duration: 90 }
            NumberAnimation {
                target: root; property: "artShowFactor"
                to: 0; duration: 100; easing.type: Easing.InOutSine
            }
        }
        // Only now is there nothing left to show.
        onFinished: root.artShown = ""
    }
    // WHAT IS FLOATING, as one value. The viewer is named by its picture; the
    // listener is named by being the listener, since it no longer has one. Both
    // use the same pop, so both have to move the same trigger -- keyed on artPath
    // alone, the pill never animated in at all.
    readonly property string overlayKey: root.listenMode ? "listen" : root.artPath
    onOverlayKeyChanged: {
        if (root.overlayKey.length) {
            // A card already up that is handed a different picture has not
            // opened again -- replaying the pop for that would be the viewer
            // jumping while you look at it.
            var up = root.artShown.length > 0
            root.artShown = root.overlayKey
            if (!up) {
                artCloseAnim.stop()
                // From the bottom of the curve every time; see showPanel.
                root.artShowFactor = 0
                root.artRiseFactor = 0
                artOpenAnim.restart()
            }
        } else if (root.artShown.length) {
            artOpenAnim.stop()
            artCloseAnim.restart()
        }
    }

    // WHAT A CLICK AWAY CLOSES, in the order things are stacked in front of you.
    // Returns whether it closed anything.
    //
    // ONE FUNCTION, TWO CALLERS, and that is the whole of "I still cannot click
    // out of albumart". `outside` spans the output and had this logic, but it is
    // declared BEFORE the panel and so sits underneath it -- and the rows have
    // MouseAreas of their own. A click on the list showing behind a viewer was
    // taken by a delegate and never reached `outside` at all, so the branch that
    // would have closed the picture could not run. The rows call this too now.
    function dismissTop() {
        if (root.listenMode) { root.closeOverlay(); return true }
        // Albumart, an artist's impression, a details sheet: the thing in front.
        if (root.viewerUp) { root.closeOverlay(); return true }
        if (root.promptFor.length) { root.cancelPrompt(); return true }
        if (root.ctxUp) { root.goBack(); return true }
        return false
    }
    function dismiss() {
        // Read BEFORE anything moves, and off the dim itself rather than off
        // listenMode: the keymap closes the overlay first, so by the time this
        // runs the mode is already gone and only the value it left says the
        // panel is currently dark. No frame is drawn between the two, so this
        // catches it at 0 and puts it straight back. See listenExit.
        root.listenExit = root.listenDim < 1
        // HIDE ONLY. Going home first sent `main`, which resets the session
        // stack to empty -- so every Escape quietly destroyed the very thing a
        // warm start restores from, and re-summoning always landed on Main.
        // Leaving the view alone means the next reveal shows exactly where you
        // were, and the stack on disk stays deep for a real cold start.
        if (typeof Shell === "undefined") { Qt.quit(); return }
        root.closeContext()
        root.opened = false
        openAnim.stop(); closeAnim.restart()
    }
    // Jump to a step in the trail. `n` is a crumb length, so part 0 ("Main") is
    // n=1. Anything we have stood at is restorable exactly; anything else falls
    // back to home rather than guessing.
    function jumpToCrumb(n) {
        if (n === root.crumb.length) return         // already there
        var pos = root.trailMap[n]
        // ONE HOP CAN SPEND TWO CRUMB PARTS -- "Bad Bunny > Top Tracks" is a
        // single step of the trail written as two words of it -- so there are
        // crumb lengths you can SEE and never stood at. trailMap only records
        // depths that were actually drawn, so those parts answered `undefined`
        // and this returned having done nothing at all: clicking most of the
        // trail did nothing, and which parts worked depended on how the steps
        // behind you happened to be named.
        //
        // The nearest depth at or before the part you clicked is where that part
        // lives. Walking to it is what the click means either way -- a qualified
        // step's two parts are one place.
        if (pos === undefined) {
            var best
            for (var k in root.trailMap) {
                var kn = parseInt(k)
                if (kn <= n && (best === undefined || kn > best)) best = kn
            }
            if (best !== undefined) pos = root.trailMap[best]
        }
        // A cursor, not a destination -- so this behaves exactly like holding
        // Alt+left (or Alt+right) that many times, trail and all.
        if (pos === undefined || pos > root.hops.length) { if (n <= 1) root.goHome(); return }
        // A CLICK AHEAD MUST NOT WALK YOU BACK. The fallback above resolves to the
        // nearest depth at or BEFORE the part you clicked, which is right for a
        // step behind you and can land behind you for a step ahead -- so a click
        // on the ghosted part would have moved the cursor the wrong way. Rather
        // than guess at a depth nobody stood at, this does nothing: the part is
        // there to be walked to, and Alt+right still walks it one step at a time.
        if (n > root.crumb.length && pos <= root.trailPos) return
        // FORWARD IS A JUMP TOO. The guard used to refuse anything at or beyond
        // the current depth, which was right while the only way here was clicking
        // a step BEHIND you -- the trail menu lists the whole path, the ghosted
        // part ahead included, and walking forward into it is as valid a move as
        // walking back.
        var back = pos < root.trailPos
        root.rememberPos(); root.closeContext()
        root.trailPos = pos; root.refresh(back ? -1 : 1)
    }
    // THE TRAIL MENU'S ANSWER. It lists the whole path -- which spans roots, and
    // so exists only as this hop list -- and hands back which step was picked
    // rather than trying to walk there itself. Its own hop comes off first:
    // looking at where you have been is not somewhere you went.
    function jumpTrail(i) {
        // EVERYTHING FROM THE TRAIL MENU'S OWN ROOT ONWARD comes off -- the hop
        // that opened it and the step that picked a row in it. Neither is a
        // place: looking at where you have been is not going anywhere, and the
        // step is only how the answer got out.
        //
        // Walked back to the last root rather than popping one hop: activate()
        // pushes the step BEFORE this event arrives, so by now there are two.
        // And read off the hop list rather than root.entryKey, which is a chain
        // of bindings that has not settled -- an event reaches the UI ahead of
        // the response that would settle them.
        for (var k = root.hops.length - 1; k >= 0; k--) {
            var h = root.hops[k]
            if (!h || !h.cmd) continue
            if (h.key === "trail-jump") {
                root.hops = root.hops.slice(0, k)
                root.trailPos = Math.min(root.trailPos, root.hops.length)
                root.fullCrumb = []; root.fullRoots = []
                root.forgetAhead(root.hops.length)
            }
            break
        }
        root.jumpToCrumb(i + 1)
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
        root.closeContext()
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
        root.rememberPos(); root.closeContext()
        root.trailPos = root.skipCtx(root.trailPos - 1, -1); root.refresh(-1)
    }
    function trailForward() {
        if (root.trailPos >= root.hops.length) return
        root.rememberPos(); root.closeContext()
        root.trailPos = root.skipCtx(root.trailPos + 1, 1); root.refresh()
    }
    // Typed characters go to whichever list is in front. The card's filter is
    // its own string so that closing it leaves the list behind exactly as wide
    // as it was -- narrowing a menu of verbs is not narrowing the shelf under it.
    function setFilter(f) {
        if (root.ctxUp) { root.ctxFilter = f; root.applyCtxFilter(); return }
        root.filter = f
        root.applyFilter()
    }
    // ...and the one every caller reads to ask "is anything typed here".
    readonly property string liveFilter: root.ctxUp ? root.ctxFilter : root.filter
    function activateCurrent(alt) {
        if (root.focusModel.count && root.focusItem) {
            root.activate(root.focusItem.currentIndex, alt === true); return
        }
        // NO ROWS IS NOT NOTHING TO DO. The search box lists past queries, and on
        // a cache that has none it has no rows at all -- so requiring one under
        // the cursor made Return do nothing there, and the only way to get a
        // first history entry is to search. Search was unusable until it had
        // already been used.
        //
        // Composing is exactly the state where what you typed is the answer
        // rather than a filter over rows, so it is also exactly the state where
        // there needing to BE a row is a misreading. See root.composing.
        // liveFilter, not root.filter: the search box is a CARD now, so what you
        // type lands in ctxFilter and root.filter is empty -- this read it and a
        // brand-new query with nothing in the history to match did nothing at all,
        // which is the same "search is unusable until it has been used" the note
        // above describes, arriving by a different door.
        if (root.composing && root.liveFilter.length) root.activate(-1, alt === true)
    }
    // dx moves within a row, dy between rows. A list is one column wide, so dy
    // is the only axis that means anything there -- which is also how rofi
    // behaves in a list versus a grid.
    function move(dx, dy) {
        var view = root.focusItem
        if (!view || root.focusModel.count === 0) return
        root.lastManualMove = Date.now()
        // Yours to steer: instant. See RowList.glideMs.
        if (view.glideMs !== undefined) view.glideMs = 0
        var cols = Math.max(1, root.focusCols)
        var n = root.focusModel.count
        var i = view.currentIndex + dx + dy * cols
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
        view.currentIndex = Math.max(0, Math.min(n - 1, i))
    }
    // A PAGE, not three rows. `lines` is what the theme says fits on screen, and
    // move() multiplies by the column count itself, so this is one screenful in
    // a list and one in a grid without either being spelled out here.
    function page(dir) {
        root.move(0, dir * Math.max(1, root.focusG.lines))
    }
    function moveTo(i) {
        root.lastManualMove = Date.now()
        var view = root.focusItem
        if (!view) return
        if (view.glideMs !== undefined) view.glideMs = 0
        view.currentIndex = (i < 0 ? root.focusModel.count - 1 : i)
    }
    function control(action, by) {
        var a = {action: action}
        if (by !== undefined) a.by = by
        // The reply carries fresh playback state, so the bar and the markers
        // update from the action itself rather than on the next poll.
        root.call("control", a, function (p) {
            root.playback = p || ({}) ; root.syncPos(p)
            // ...AND VOLUME SAYS WHAT IT DID. Every other control is visible in
            // the strip the moment it lands -- the glyph flips, the fill moves --
            // and volume is the one with nothing on screen to show for it. A
            // wheel gesture with no feedback is a gesture you cannot tell worked.
            if (action === "volume" && p && p.volume !== undefined)
                root.notify("Volume " + p.volume + "%")
        })
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
    // WHERE THE PLAYING THING IS IN THIS LIST, if it is here at all.
    //
    // Either id, exactly as TileGrid's marker matches either: a grid's rows are
    // ALBUMS, so the tile that is playing is the one HOLDING the track, and
    // matching on the track id alone could only ever find a single. That is why
    // Alt+c in an album grid never noticed it was already looking at the right
    // menu, fell through to the re-entry branch below, and appended the very
    // segment it was standing on -- the duplicate.
    function playingRowIndex() {
        var id = root.playback.id || ""
        var alb = root.playback.albumId || ""
        if (!id.length && !alb.length) return -1
        for (var i = 0; i < rows.count; i++) {
            var rid = rows.get(i).id
            if (id.length && rid === id) return i
        }
        if (!alb.length || root.layout !== "grid") return -1
        for (var j = 0; j < rows.count; j++) {
            if (rows.get(j).id === alb) return j
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
        // A LIST, NOT A TRACK. This used to require the recorded origin to still
        // be the playing track, so the moment autoplay moved on -- or you pressed
        // next -- the answer became "nowhere to jump to", while the list it came
        // out of was sitting right there on the trail. The next track is playing
        // from the same place; where you came from does not change because the
        // song did. originId is still recorded, and is still what a cold start
        // restores, but it no longer has to match for the jump to be possible.
        if (root.originPos > 0 || root.originHops.length) {
            root.rememberPos()
            root.seekPlaying = true
            if (root.originOnTrail()) {
                // ALREADY STANDING THERE. Re-entering costs a duplicate segment
                // and the only thing that was actually wanted was the cursor,
                // which cursorToPlaying could not place because the row is not
                // here yet -- so ask for the menu again rather than for a second
                // copy of it.
                if (root.originPos === root.trailPos) { root.refresh(0); return }
                // Still on this trail: a walk, exactly as Alt+left or Alt+right
                // would be, and nothing behind or ahead of you is disturbed.
                var back = root.originPos < root.trailEnd()
                root.trailPos = root.originPos
                root.refresh(back ? -1 : 1)
                return
            }
            // GONE FROM THE TRAIL -- branched away from since. THE LAST STEP,
            // and only that. This used to replay the whole segment that led there
            // -- the root hop and every step inside it -- so jumping back to a
            // track played out of an album three levels into an artist rebuilt
            // the artist, then their albums, then the album, as a fresh journey
            // nobody asked to walk again.
            //
            // The engine records the one scope entry the list IS (see
            // Util.play_origin_save) and can reopen it standing on nothing, which
            // is something a hop list cannot express: an album is not a named
            // view you can name in a hop. So this asks for that entry by name and
            // gets a single root back.
            root.pushHop({cmd: "view", key: "origin"})
            root.refresh()
            return
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
        // A TWO-FACED CARD CROSSES TO ITS OTHER FACE, and that is not a step.
        // The trail menu is the only one: Tab there means "show me the menus I
        // closed instead of the steps I am on".
        //
        // It used to be answered as a path STEP, which is a thing the engine
        // replays -- so crossing wrote itself into the very trail the menu exists
        // to show, `sticky` then reverted it (that is what sticky is for), and the
        // card ended up drawing one face while the path described the other.
        // Anything picked after that came out of the wrong list. That is the whole
        // of "stack and trail are completely broken when I press tab".
        //
        // The face is an argument on the card's own hop instead. That hop lives on
        // ctxHops, beside the trail and never on it, so the trail menu costs no
        // step, no crumb and no replay -- which is also what keeps it out of the
        // trail it is listing.
        if (root.ctxUp && root.ctxMode.length) {
            root.ctxHops = [{cmd: "view", key: "trail-jump",
                             mode: root.ctxMode === "history" ? "trail" : "history"}]
            root.refresh(0)
            return true
        }
        // A CARD, not a place. Opened with openCard it never touches the trail at
        // all -- openView put it on and left applyContext to adopt it back off,
        // which worked and meant the trail briefly held the menu that lists it.
        if (!root.canTab || !root.focusItem || !root.focusModel.count)
            return root.openCard("trail-jump")
        // THE LIST WITH THE KEYBOARD, not the body. `canTab` follows a card the
        // way Delete does -- applyContext sets it from the card's own draw -- so
        // with one up this read the row highlighted in the menu UNDERNEATH and
        // sent that. focusModel/focusItem are the card's while a card is up and
        // the body's otherwise, which is the same pair activate() and
        // deleteEntry() already use.
        root.rememberPos()
        var hop = {step: root.rowStep(root.focusModel,
                                      root.focusItem.currentIndex, {tab: true})}
        if (root.ctxUp) root.ctxHops = root.ctxHops.concat([hop])
        else root.pushHop(hop)
        root.refresh()
        return true
    }
    // QUEUE THE ROW UNDER THE POINTER, and stay exactly where you are.
    //
    // Sent as a path step like Delete's, and for the same reason: the engine is a
    // replayer and only a replay can say what the third row of this list actually
    // IS. The step acts and answers nil, so the menu redraws unchanged and
    // Util.serve_keep leaves the step off the trail -- which is what stops it
    // being queued again on every later draw.
    function queueRow(i) {
        var m = root.focusModel
        if (!m || i < 0 || i >= m.count) return
        root.rememberPos()
        root.pushHop({step: root.rowStep(m, i, {queue: true})})
        root.refresh()
    }
    function deleteEntry() {
        if (!root.canDelete || !root.focusItem || !root.focusModel.count) {
            root.notify("Nothing to delete here")
            return
        }
        root.rememberPos()
        root.pushHop({step: root.rowStep(root.focusModel,
                                        root.focusItem.currentIndex, {del: true})})
        root.refresh()
    }
    function goBack() {
        // A CARD CLOSES WITHOUT ASKING ANYONE. Its hops were never on the trail,
        // so dropping the last of them is the whole of it -- and when that was the
        // last one, the list underneath is still drawn, still scrolled where it
        // was and still correct, so there is nothing to fetch. Reopening the
        // parent was the tax the old shape paid: the step had to come off the
        // trail, and taking a step off the trail means a round trip.
        if (root.ctxHops.length) {
            root.ctxHops = root.ctxHops.slice(0, root.ctxHops.length - 1)
            // Except one card over another, where the card underneath has to be
            // drawn again -- there is only ever one set of card rows.
            if (root.ctxHops.length) root.refresh(-1)
            else root.closeContext()
            return
        }
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
            root.forgetAhead(root.trailPos)
            return
        }
        if (root.trailPos > 0) {
            // May remove a ROOT hop, which lands you on the tip of the segment
            // before it -- the trail reads as one walk, so it unwinds as one.
            // ...and it takes the step that opened a card with it, rather than
            // stopping on one: backing out of the album a track's menu sent you
            // to returns you to the list, not to the menu.
            root.hops = root.hops.slice(0, root.skipCtx(root.trailPos - 1, -1))
            root.forgetAhead(root.hops.length)
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
        // ONLY IN THE LYRICS VIEW. This writes straight into body.item.currentIndex,
        // and body.item is whichever view happens to be loaded -- so a cue landing
        // a moment after you left drove the TRACK LIST's cursor to whatever line
        // number the song had reached. Backing out of a song's lyrics dropped you
        // thirty rows down the list you came from, and the same mechanism ran the
        // other way: a paused track's cues could walk a list you were reading.
        //
        // The cues are cleared on every draw (see applyIdentity), but the fetch
        // that fills them is asynchronous and the interpolator ticks every 16ms,
        // so "cleared on leaving" was never a guarantee. The scope is: it is the
        // engine's word for which view this is.
        if (root.scope !== "lyrics") return
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
        // ONCE A SECOND, AND FIVE TIMES A SECOND OVER THE CHANGEOVER.
        //
        // This is the pop at the start of a track. A track ending is something
        // only the poll can see, so between the last note and the next answer the
        // interpolator goes on advancing a position that has run past the old
        // duration -- the bar sits pinned at 100% for up to a whole second and
        // then teleports back to nothing when the truth arrives. That is the jump,
        // and it lands a second or so INTO the new track rather than at its start,
        // which is exactly how it reads.
        //
        // Nothing here can know sooner, so it asks oftener, and only where it
        // matters: inside the last four seconds of a track the answer is worth
        // five times as much and costs nothing extra to get -- Util.serve_playback
        // reads the local player over D-Bus and touches the network on no path
        // this takes. The gap collapses from ~1000ms to ~200ms, which reads as the
        // bar simply starting again.
        interval: (root.playback.duration > 0
                   && root.playback.duration - root.positionMs < 4000) ? 200 : 1000
        running: true; repeat: true; triggeredOnStart: true
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
    // THE INTERPOLATOR. Nothing is asked of the engine here at all -- the fill
    // and the clock advance from the last known position and the wall clock,
    // which is what makes them smooth over a 1Hz truth.
    //
    // ONCE PER FRAME, not every 16ms. A Timer is an event-loop timer: it has no
    // idea when the scene is about to be drawn, so at 16ms against a 60Hz output
    // it beats slowly in and out of phase with the frame clock -- two updates
    // land in one frame, then none in the next, and the fill advances in an
    // uneven stagger that reads as jitter however small each step is.
    // FrameAnimation fires exactly once per frame, immediately before it is
    // rendered, so every frame carries exactly one step and they are all the
    // same size. It also stops on its own while the window is hidden, where a
    // Timer went on recomputing a position nobody could see -- and the first
    // frame after a reveal reads the wall clock, so it comes back current.
    FrameAnimation {
        running: root.playback.playing === true
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
            playingId: root.liveId
            playingAlbumId: root.liveAlbumId
            lastId: root.lastId
            lastAlbumId: root.lastAlbumId
            paused: root.playback.playing !== true
            columns: root.columns
            // Marked wherever the rows were narrowed -- root.narrows is the one
            // predicate both halves read, so a row can never be kept by a match
            // that is then not shown.
            filter: root.narrows ? root.filter : ""
            focus: false
            // THE BODY ACTS ONLY WHEN THE BODY HAS THE KEYBOARD. activate() reads
            // root.focusModel, which follows a card the moment one opens -- so a
            // double click on the list still showing behind one would be answered
            // against the card's verbs. See root.focusItem.
            onPicked: function (i, alt) { if (!root.ctxUp) root.activate(i, alt) }
            // A CLICK ON THE LIST BEHIND A CARD CLOSES THE CARD. `outside` already
            // says exactly this -- everything but the card is "away" -- but the
            // rows' own MouseArea is on top of it and swallowed the press, so the
            // one part of the panel you were most likely to click at was the one
            // part that did nothing. It moved a cursor you could not even see.
            onRowClicked: root.dismissTop()
            onRowQueued: function (i) { if (!root.ctxUp) root.queueRow(i) }
            // HOLD THE FOLLOW WHILE A CLICK IS BEING MADE. Synced lyrics scroll
            // themselves to the sung line, so the row you pressed had moved on by
            // the time the second press of a double click landed -- and the seek
            // went to whatever line had slid under the pointer. Same grace the
            // keyboard already earns by moving the cursor. See syncLyrics.
            onRowPressed: root.lastManualMove = Date.now()
            // A CLICK AWAY IS NOT A CLICK ON. With a card, a prompt or a viewer in
            // front, the rows behind are what you click to DISMISS it -- and the
            // cursor was moving to whichever row you happened to dismiss it over,
            // so you came back to a list looking at somewhere you never chose.
            inert: root.anythingUp
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
            playingId: root.liveId
            playingAltId: root.liveAltId
            lastId: root.lastId
            paused: root.playback.playing !== true
            // Per-theme, with ZENON's defaults where a theme says nothing.
            centered: root.menuG.center === true
            rowSize: root.menuG.rowSize || zenon.fontSize
            rowWeight: root.menuG.rowWeight || zenon.fontWeight
            // See TileGrid above: one predicate for narrowing and for marking.
            filter: root.narrows ? root.filter : ""
            focus: false
            // See gridView: the body answers only while the body is focused.
            onPicked: function (i, alt) { if (!root.ctxUp) root.activate(i, alt) }
            // See gridView: a click behind a card closes it, the third button queues.
            onRowClicked: root.dismissTop()
            onRowQueued: function (i) { if (!root.ctxUp) root.queueRow(i) }
            // See gridView: a press holds the lyrics follow off while you click.
            onRowPressed: root.lastManualMove = Date.now()
            // See gridView: a click that dismisses something must not also pick.
            inert: root.anythingUp
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
        // BOTH CODES FOR EACH THUMB BUTTON. Which one a mouse sends is the
        // mouse's business, not the app's: most send BTN_SIDE/BTN_EXTRA, which
        // Qt calls Back/Forward, and some send BTN_BACK/BTN_FORWARD, which it
        // calls ExtraButton3/4. Accepting one pair works on one mouse.
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                         | Qt.BackButton | Qt.ForwardButton
                         | Qt.ExtraButton3 | Qt.ExtraButton4
        onClicked: function (m) {
            // THE THUMB BUTTONS WALK THE TRAIL, from anywhere on the output --
            // which is why they are answered here and not on a row. The rows'
            // own MouseAreas deliberately do not accept these, so a press over a
            // list falls straight through to this one.
            //
            // BACK IS BACKSPACE, not Alt+left: an overlay or a card is the thing
            // in front of you, so it is what "back" leaves first, and only with
            // nothing in the way does the press reach the trail. Forward has
            // nothing to close, so it is trailForward and nothing else.
            if (m.button === Qt.BackButton || m.button === Qt.ExtraButton3) {
                if (root.viewerUp) root.closeOverlay()
                else if (root.promptFor.length) root.cancelPrompt()
                else root.goBack()
                return
            }
            if (m.button === Qt.ForwardButton || m.button === Qt.ExtraButton4) {
                root.trailForward(); return
            }
            // A CARD IS ITS OWN EDGE. With a context menu up, everything outside
            // the card is "away" -- the list showing around it included -- and one
            // click there closes the card rather than the app, which is what a
            // context menu does everywhere else. Checked first, because the panel
            // test below would let a click on the list fall straight through.
            // With the panel hidden there is no shape to be outside OF, so any
            // click is a click away from the listener -- which is a cancel.
            // A LISTENER OR A VIEWER IS ITS OWN EDGE: everything outside it is
            // "away", including the panel, so there is no geometry to test. The
            // two below ARE shapes you can be inside of, which is why they stay
            // here rather than joining dismissTop.
            if (root.listenMode || root.viewerUp) { root.dismissTop(); return }
            // A FIELD IS ITS OWN EDGE TOO, and clicking away from one abandons
            // it rather than the app -- the same thing Escape does. Checked
            // before the panel test below, which would otherwise read a click on
            // the blurred list as a click on the panel and leave the field up.
            if (root.promptFor.length) {
                var q = outside.mapToItem(promptCard, m.x, m.y)
                if (q.x < 0 || q.y < 0 || q.x > promptCard.width || q.y > promptCard.height)
                    root.cancelPrompt()
                return
            }
            if (root.ctxUp) {
                var c = outside.mapToItem(ctxCard, m.x, m.y)
                if (c.x < 0 || c.y < 0 || c.x > ctxCard.width || c.y > ctxCard.height)
                    root.goBack()
                return
            }
            var p = outside.mapToItem(panel, m.x, m.y)
            if (p.x < 0 || p.y < 0 || p.x > panel.width || p.y > panel.height)
                root.dismiss()
        }
    }

    // THE PANEL'S OWN, and the same one the cards cast -- same component, same
    // tokens, no exception anywhere. It was taken out entirely once, on the
    // grounds that spoot's surface is the whole output so the shadow falls on a
    // desktop the app cannot see: true, and not the point. It is what tells you
    // the panel is a thing lying ON the desktop rather than a hole cut in it.
    //
    // AND NOT GATED ON THE LAYOUT. It was, briefly, on the theory that a wall of
    // covers is its own hard edge -- which meant Main, the first thing anyone
    // sees, was the one view with no shadow at all. Whatever a grid needs, it is
    // not the window it sits in looking different from every other window.
    //
    // A sibling, declared ahead of the panel so it is behind it, and told the
    // two things the panel does that it has to do too. See Shadow.qml.
    Shadow {
        theme: zenon
        target: panel
        scaleFactor: root.panelScale
        fade: root.showFactor * root.listenDim
    }

    Item {
        id: panel
        // A structured sheet sizes the panel to ITSELF; every other view takes
        // the width its theme declares. Clamped to the screen so a pathological
        // value cannot push it off.
        // THE IMAGE VIEWER NO LONGER TOUCHES IT. It used to widen and re-center
        // the panel so the panel could be the picture's frame -- which is the
        // black box that showed behind every cover. The viewer draws its own
        // card on the surface now (see the art viewer, below the panel), and the
        // panel just sits there being the menu.
        width: root.g.width
        height: root.menuHeight
        // IT RESIZES SMOOTHLY between menus of different heights. It used to
        // snap, at the instant the held draw was applied -- which is invisible
        // going to a TALLER menu, because the panel grows into space that was
        // empty anyway, and obvious going to a shorter one, where everything
        // below the body jumps up while the body is still fading in over it.
        //
        // Matched to the incoming half of the transition, so the panel finishes
        // arriving at the same moment its contents do.
        //
        // NOT ON THE FIRST ONE. A cold start has no rows, so this height starts at
        // nothing and the first draw is a resize like any other -- 160ms of the
        // panel growing from a sliver. The panel is anchored to the bottom edge, so
        // growing means the TOP edge travelling upward: the open read as a slide
        // rather than as the pop it is, and holding openAnim back for the first
        // draw could not help, because the slide was underneath the pop rather than
        // before it. There is nothing to ease FROM on the first menu.
        Behavior on height {
            enabled: root.firstDrawn
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
        // WHERE IT SITS. Docked south for a menu -- that is ZENON's whole layout,
        // a panel rising off the bottom edge -- and centered on the output for the
        // image viewer, which is a thing you look AT rather than a thing you
        // reach for. Both are plain anchors now; this used to be a call into the
        // host asking the compositor to re-anchor the SURFACE, which took long
        // enough that the exit animation played before it landed.
        // ...and it is docked south, always. The image viewer used to move it to
        // the middle of the output and back; it has its own card now and the
        // panel stays where every view lives.
        // PLACED, NOT ANCHORED. Nine positions means switching which anchor is
        // live as the setting changes, and clearing an anchor by binding it to
        // undefined does not reliably let go: moving to the left edge left the
        // old centre anchor in place beside the new left one, and an item
        // anchored two ways horizontally stretches -- the panel came up spanning
        // the whole output at any position but the default.
        //
        // x and y cannot do that. The width binding above stays the only thing
        // that decides how wide this is, which is the property that was lost.
        //
        // The lift applies only to an edge the panel is actually against: one
        // centered on an axis has no edge to clear there, and lifting it anyway
        // would read as being slightly off-center.
        x: root.anchorH === "left"  ? zenon.panelLift
         : root.anchorH === "right" ? parent.width - width - zenon.panelLift
         : Math.round((parent.width - width) / 2)
        y: root.anchorV === "top"    ? zenon.panelLift
         : root.anchorV === "bottom" ? parent.height - height - zenon.panelLift
         : Math.round((parent.height - height) / 2)
        // Anchored south and lifted clear of it, but the growth happens about the
        // panel's own center -- see panelScale. Bottom-center was right while it
        // was welded to the edge; a floating card that grew from its own bottom
        // would look like it was being pushed up by something underneath.
        transform: [
            Scale {
                origin.x: panel.width / 2
                origin.y: panel.height / 2
                xScale: root.panelScale
                yScale: root.panelScale
            }
        ]
        // NOTHING BEHIND THE LISTENER. The card is a small thing working away on
        // its own; the menu it happened to be summoned over is not part of what it
        // is doing, and leaving it there is the "stuff behind it". The panel is
        // still THERE -- it comes straight back when the listen ends, with its
        // rows, its scroll and its cursor untouched -- it is simply not drawn.
        // NO Behavior HERE. showFactor is already an animated value, and a
        // Behavior on the property it feeds re-animates every frame of it towards
        // the frame after -- each step chasing the last over 160ms, so an 80ms
        // fade arrived as a long soft smear and the pop underneath it read as
        // stuttering. The listener dim is the only part that needs easing of its
        // own, and it has it, on a value of its own.
        opacity: root.showFactor * root.listenDim
        // WHO IS AT THE FOOT OF THE PANEL, and therefore wears its bottom
        // corners. The column is a stack of things that each collapse to nothing
        // when they have nothing to say, so which of them is last is a QUESTION
        // rather than a constant -- and every one of them used to answer it for
        // itself or not at all. The now-playing strip answered it (see
        // the old now-playing strip's `corner`); the notice bar and the body did
        // not, so with no track playing the last thing in the column drew square
        // into two rounded corners. That is the backdrop cutting the corner off,
        // and the highlight bar squaring the one on the right: one omission, two
        // complaints.
        //
        // Two candidates now rather than three -- the strip moved to the top of
        // the panel and the title row it replaced was never at the foot.
        //
        // Inset by the border, which all of these sit inside of.
        readonly property int footCorner: zenon.radius - zenon.borderWidth
        // HOW FAR BACK THE LIST IS PUSHED, as one number.
        //
        // Two things float over it and neither is more entitled to the treatment
        // than the other: a card of verbs, and a sheet of details or keybinds. The
        // card had it and the sheet did not, so Track Details, Album Details and
        // the keybind list floated over a perfectly sharp menu whose rows read
        // straight through their own translucent ground.
        //
        // Read off their opacities rather than off the state that drives them, so
        // this follows whatever is arriving or leaving -- and a sheet opened FROM a
        // card (Track Details is a verb in one) keeps the treatment through the
        // handover instead of flickering between the two.
        //
        readonly property real veil: Math.max(ctxLayer.opacity, sheetCard.opacity)
        readonly property bool noticeAtFoot: noticeBar.height > 0
        readonly property bool bodyAtFoot: noticeBar.height <= 0
        // The shadow is OUTSIDE this item, above -- a child of the panel would
        // be simpler, but see Shadow.qml for why all three casters are siblings.
        // --- the panel (ZENON `window`) -----------------------------------------
        Rectangle {
            anchors.fill: parent
            color: zenon.ground
            radius: zenon.radius
            border.width: zenon.borderWidth
            border.color: zenon.borderCol
            // All four corners. A strip of ground used to square the bottom pair
            // off again, because the panel was flush against the screen edge and
            // a rounded corner there would have shown the desktop through a notch
            // in its own frame. It floats now, so the corner is just a corner.
        }

        Column {
            anchors.fill: parent
            // IT USED TO BE FADED OUT WHILE A SHEET WAS UP, and that was not
            // cosmetic: the panel shrank to the sheet's height, and a Column does
            // not clip, so its children went on laying themselves out past the new
            // bottom edge -- the last rows of the list, and the now-playing bar,
            // drawn below the sheet where nothing covered them.
            //
            // The panel does not shrink for a sheet any more (see sheetCard), so
            // there is nothing to lay out past and nothing to hide. The menu stays
            // exactly where it was, with the sheet floating over it.
            // Inside the border, not on it. ZENON draws a 1px frame with rounded top
            // corners; content laid flush to the window edge painted over it, which
            // showed as the album cover clipping the frame on the left.
            anchors.margins: zenon.borderWidth

            // AN INPUT BAR STOOD HERE, first in the column, drawn only by the
            // search view. It is a FLOATING FIELD now -- see promptCard, which was
            // already exactly this for New Playlist and Rename and had no business
            // being two things.
            //
            // Its removal is also the "solid corners behind the rounded corners in
            // search". This bar was a transparent Item with no ground of its own,
            // so the panel's rounded corner showed THROUGH it -- and the message
            // bar below was told to drop its own rounding on the grounds that
            // something was above it. The result was a rounded corner in the
            // panel's ground with the message bar's lighter grey squared off
            // immediately beneath it: two corners, one of them a box. With nothing
            // above it, the message bar is the top of the panel and rounds like it.
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
                // IS THERE A TRACK TO SHOW. What the title row's `hasMesg` used
                // to answer, asked of the thing that replaced it: the now-playing
                // line collapses with nothing loaded, exactly as the strip at the
                // foot of the panel used to.
                //
                // NOT WHILE LISTENING, for the reason the old strip gave: the card
                // floating over the panel is the only thing spoot is doing at that
                // moment, and a line naming whatever happens to be playing
                // underneath answers a question nobody asked.
                readonly property bool hasNow:
                    !!(root.playback && root.playback.name) && !root.listenMode
                height: msgCol.height
                // HOW FAR THE TRACK HAS RUN, and where the wash stops being solid.
                // Kept as a FRACTION rather than a width: a gradient stop is a
                // float and is rasterised continuously, so the edge lands between
                // pixels and slides. A clipped Item sized to `width * progress` is
                // a scissor rectangle -- integers -- and on a 1000px bar under a
                // six-minute track it sat still for a third of a second and then
                // jumped a whole pixel. That was the stutter.
                readonly property real head: Math.max(0, Math.min(1, root.progress))
                // How far the leading edge is softened over. In pixels, converted
                // once: a fixed fraction would be a hard edge on a narrow bar and
                // a wide smear on a wide one.
                readonly property real feather:
                    width > 0 ? Math.min(head, 34 / width) : 0
                readonly property real headStart: head - feather
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
                    // NO GROUND OF ITS OWN. The panel's ground is already black at
                    // the opacity setting and this is drawn over it, so a black
                    // here compounds the two alphas and the top of the window goes
                    // solid while the rest stays see-through. See Theme.progressWash.
                    color: "transparent"
                    // AND THE PANEL'S TOP CORNERS, the way the now bar wears its
                    // bottom pair. This bar is the topmost thing in every menu but
                    // search, and square it painted its own colour into the corner
                    // arcs -- subtle, because it is a near-black on a black ground,
                    // and visible once you know it is there. In search the input
                    // bar is above it and the corners are the panel's own, so the
                    // rounding is dropped rather than applied halfway down.
                    // ALWAYS THE PANEL'S TOP CORNERS. This used to drop them
                    // whenever the search view's input bar was above it, along
                    // with a top rule to separate the two -- and there is nothing
                    // above it any more: the field floats. See the note where that
                    // bar stood.
                    topLeftRadius: zenon.radius - zenon.borderWidth
                    topRightRadius: zenon.radius - zenon.borderWidth
                    Rectangle {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 1
                        color: zenon.separator
                    }
                }
                // THE PROGRESS BAR, and it is now the GROUND OF THIS BAR rather
                // than a strip at the foot of the panel.
                //
                // One gradient, full width, solid to the playhead and feathered
                // out over 34px after it -- so there is no edge to see, which is
                // what made the old fill look unfinished when it was clipped to a
                // hard vertical cut. It used to be three layers (a wash, a
                // breathing bloom around the head, and a 2px green rule along the
                // bottom); the rule is gone with the strip that carried it, and a
                // bloom on the bar that holds the trail would be a light pulsing
                // behind text you are trying to read.
                //
                // The same corners the ground turns, or this paints a square top
                // over the panel's own curve.
                Rectangle {
                    anchors.fill: parent
                    visible: message.head > 0
                    topLeftRadius: zenon.radius - zenon.borderWidth
                    topRightRadius: zenon.radius - zenon.borderWidth
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: zenon.progressWash }
                        GradientStop { position: message.headStart
                                       color: zenon.progressWash }
                        GradientStop { position: message.head
                                       color: zenon.fade(zenon.progressWash, 0) }
                        GradientStop { position: 1.0
                                       color: zenon.fade(zenon.progressWash, 0) }
                    }
                }
                // THE WHEEL OVER THE BAR SEEKS. It is the widest target in the
                // window and is already a picture of the position, so moving the
                // position is the gesture it was asking for. Declared before the
                // content so presses fall through to the trail steps and the
                // transport glyphs, which are controls of their own.
                //
                // Five seconds a notch rather than the keyboard's ten: a wheel is
                // spun, so the small step is the one that can still be aimed.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    onWheel: function (e) {
                        var d = e.angleDelta.y !== 0 ? e.angleDelta.y : e.angleDelta.x
                        if (d === 0) return
                        root.control("seek", d > 0 ? 5 : -5)
                        e.accepted = true
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
                    topPadding: (message.hasNow || crumbRow.visible) ? zenon.messagePadV : 0
                    bottomPadding: topPadding
                    spacing: 0

                // WHAT IS PLAYING, AT THE TOP OF THE PANEL.
                //
                // THE TITLE ROW STOOD HERE and is gone. It named the menu you were
                // already looking at -- "Liked Tracks", over a list of liked
                // tracks, above a trail whose last step said it a third time --
                // and it cost a row of chrome on every menu to do it. The trail
                // below says where you are, and says it navigably; the floating
                // cards keep their own titles, because a card really is about
                // something you cannot otherwise see.
                //
                // AND THE NOW-PLAYING STRIP CAME UP HERE from the foot of the
                // panel to take the row. It is the one line that is never about
                // the menu, so it is the one line worth a permanent place -- and
                // up here it sits on the progress wash behind it, which is what
                // lets the bar itself be the progress bar.
                Item {
                    id: nowRow
                    width: parent.width
                    // Collapsed rather than hidden, so the panel closes the gap
                    // instead of leaving a band of nothing.
                    height: message.hasNow ? zenon.nowBarHeight : 0
                    visible: height > 0
                    clip: true
                    Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                    NowContent {
                        anchors.fill: parent
                        theme: zenon
                        fg: zenon.playing
                        // The transport glyph is a control beside the title now,
                        // not the first character of it -- see NowContent's modes
                        // row -- so this is the name and the artists and nothing
                        // else.
                        track: {
                            var p = root.playback
                            if (!p || !p.name) return ""
                            return p.name + (p.artists ? zenon.sep + p.artists : "")
                        }
                        icons: root.playback.icons || ""
                        elapsed: root.clock(root.positionMs)
                        total: root.clock(root.playback.duration || 0)
                        shuffle: root.playback.shuffle === true
                        playing: root.playback.playing === true
                        repeatMode: root.playback.repeat_ || "off"
                        onControlRequested: function (a) { root.control(a) }
                        // The playing track's verbs -- the same card Shift+Return
                        // reaches from any row of it, and the same one Main's
                        // Playback tile opens.
                        onTitleClicked: root.openCard("track-actions")
                    }
                }

                // THE TRAIL. rofi could only put this in the same one-line mesg as
                // everything else; here it is its own line, dim, with the arrows
                // darker than the names so the names read first -- which is exactly
                // what Util.crumb_arrow does in the rofi build.
                // THE TRAIL, as chrome rather than a menu. rofi could only draw it
                // as a line of text and needed a separate window to navigate it;
                // here every step is a control -- click one and you are there.
                //
                // ONE LINE, ALWAYS. It used to wrap, and a daisy chain of four or
                // five roots is three rows of chrome above a menu that might only
                // have four -- the bar grew taller than the thing it labels. It
                // scrolls sideways instead: the panel keeps one row's height
                // whatever the path is, and the path is walked rather than stacked.
                Item {
                    id: crumbBar
                    x: zenon.messagePadH
                    width: msgCol.width - zenon.messagePadH * 2
                    // A single part is the name of the menu already on screen --
                    // nothing a trail could tell you. No trail, no bar.
                    visible: (root.crumb || []).length > 1 || root.crumbAhead.length > 0
                    height: visible ? crumbRow.implicitHeight : 0

                    // HOW FAR THE LINE HAS BEEN WALKED, and how far it can be.
                    //
                    // A Flickable STOOD HERE and had to go. Not because it scrolled
                    // wrong -- it scrolled fine -- but because the fade could not be
                    // built over it: a ShaderEffectSource pointed at a Flickable
                    // captures nothing useful and its `hideSource` does not hide the
                    // contentItem the rows actually live in, so the effect drew an
                    // empty texture while the original went on drawing underneath.
                    // Measured it directly: a `brightness: -1` on the effect changed
                    // not one pixel. A plain Item captures the way every other
                    // masked thing in spoot does.
                    //
                    // What that costs is drag-to-scroll, which nothing asked for.
                    // The wheel is the gesture, and it is one property either way.
                    readonly property real maxScroll: Math.max(0, crumbRow.width - width)
                    property real scrollX: 0
                    onMaxScrollChanged: scrollX = Math.min(scrollX, maxScroll)

                    // ...AND IT ENDS WHERE YOU ARE. The last part of the chain is
                    // the menu on screen, which is the one part you always need to
                    // be able to read -- so a trail too long for the bar is parked
                    // at its END and walked backwards, not parked at "Main" with
                    // the answer off the right-hand side.
                    //
                    // Deferred, because the width it measures against is only right
                    // once the text has laid out, and this runs from the change that
                    // causes that layout.
                    function toEnd() { crumbBar.scrollX = crumbBar.maxScroll }
                    onWidthChanged: Qt.callLater(crumbBar.toEnd)
                    // A NEW TRAIL IS PARKED AT ITS END, like the first one. Keyed on
                    // the trail ITSELF -- the parts, and whatever lies ahead of the
                    // cursor -- because that is what "somewhere new" means. It was
                    // keyed on the rendered LINE first, and the line changes on
                    // hover: the step under the pointer brightens, so moving the
                    // mouse across the trail threw it back to the end under your own
                    // cursor.
                    Connections {
                        target: root
                        function onCrumbChanged() { Qt.callLater(crumbBar.toEnd) }
                        function onCrumbAheadChanged() { Qt.callLater(crumbBar.toEnd) }
                    }
                    // A CHUNK PER NOTCH, not a step and not a pixel. A third of the
                    // bar is far enough to be worth the gesture and short enough to
                    // keep your place -- the same reasoning as TileGrid's whole-row
                    // notch.
                    //
                    // A function rather than a handler, because the thing that
                    // CATCHES the wheel is the whole message bar (see msgWheel): the
                    // trail is one line of it, and aiming at that line to scroll it
                    // is a smaller target than the bar it lives in.
                    function wheel(e) {
                        if (crumbBar.maxScroll <= 0) return false
                        // EITHER AXIS. A plain wheel reports on y; a tilt wheel and
                        // some mice report sideways scrolling on x, and this is a
                        // sideways list -- so whichever one moved, moves it.
                        var d = e.angleDelta.x !== 0 ? -e.angleDelta.x : e.angleDelta.y
                        var by = (d > 0 ? -1 : 1) * Math.round(crumbBar.width / 3)
                        crumbScroll.to = Math.max(0, Math.min(crumbBar.maxScroll,
                                                              crumbBar.scrollX + by))
                        crumbScroll.restart()
                        return true
                    }
                    NumberAnimation {
                        id: crumbScroll
                        target: crumbBar; property: "scrollX"
                        duration: 160; easing.type: Easing.OutCubic
                    }

                    // HOW MUCH IS OFF EACH EDGE, as a fade that arrives with the
                    // overflow rather than being switched on by it. Ramped over the
                    // first 48px so scrolling the last word into view takes the fade
                    // off with it, instead of the end of the line snapping from soft
                    // to hard on one pixel of travel.
                    readonly property real overL: Math.min(1, crumbBar.scrollX / 48)
                    readonly property real overR: Math.min(1,
                        (crumbBar.maxScroll - crumbBar.scrollX) / 48)
                    // How wide the dissolve is, as a fraction of the bar. Wide
                    // enough to read as the line dissolving rather than as a cut
                    // with a soft edge on it -- about nine characters at the default
                    // width, which is a word and a half.
                    readonly property real fadeW: 0.12

                    // THE LINE, captured rather than drawn. hideSource keeps this
                    // out of the scene; the MultiEffect below puts it back with the
                    // mask applied.
                    Item {
                        id: crumbTrack
                        anchors.fill: parent
                        Text {
                            id: crumbRow
                            // AS WIDE AS THE CHAIN, and no wider -- the item sizes
                            // itself from the text and is then PLACED.
                            //
                            // It was written the other way first -- `width:
                            // Math.max(implicitWidth, bar.width)` with AlignHCenter
                            // -- and that is a binding that reads what it writes:
                            // constraining a Text makes it report the constrained
                            // size as its implicit one, so the expression settled at
                            // the bar's width and the line could not scroll at all.
                            //
                            // Centred while it fits and walked once it does not,
                            // which is the same expression: maxScroll is zero until
                            // the line is wider than the bar.
                            x: crumbBar.maxScroll > 0
                               ? -crumbBar.scrollX
                               : Math.round((crumbBar.width - width) / 2)
                            wrapMode: Text.NoWrap
                            textFormat: Text.RichText
                            text: root.crumbHtml
                            font { family: zenon.fontFamily; pointSize: zenon.fontSize; bold: true }
                        }
                    }
                    ShaderEffectSource {
                        id: crumbShot
                        anchors.fill: parent
                        sourceItem: crumbTrack
                        hideSource: true
                        live: true
                        visible: false
                    }
                    // MASKED RATHER THAN OVERLAID. A gradient in the bar's own
                    // colour painted on top would only be right at full opacity --
                    // below it the panel's ground is translucent, and a second copy
                    // of it over the text would make the ends of the bar more solid
                    // than the middle. The mask takes the line's own alpha down
                    // instead, so it dissolves into whatever is actually behind the
                    // panel.
                    MultiEffect {
                        anchors.fill: parent
                        source: crumbShot
                        maskEnabled: true
                        maskSource: crumbMaskShot
                        // THE THRESHOLD CANNOT BE ZERO, which is the whole reason
                        // this took three attempts to make visible. MultiEffect
                        // resolves the mask as
                        //     smoothstep(min*(1+spread) - spread, min*(1+spread), a)
                        // so with min = 0 the ramp runs from -spread to 0 -- every
                        // alpha at or above zero lands at full strength and the
                        // gradient does nothing at all. Measured it: the line was
                        // pixel-for-pixel identical with the mask on and off.
                        //
                        // At min = 0.5 with spread 1 the same expression is
                        // smoothstep(0, 1, a): the whole alpha range, as a curve.
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                        autoPaddingEnabled: false
                    }
                    // THE MASK: opaque across the middle, transparent at whichever
                    // end has something beyond it. Kept out of the scene by
                    // hideSource and NOT by `visible: false`, which would stop it
                    // being rendered at all and hand the effect an empty texture.
                    Rectangle {
                        id: crumbMask
                        width: crumbBar.width
                        height: Math.max(1, crumbBar.height)
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0
                                           color: Qt.rgba(1, 1, 1, 1 - crumbBar.overL) }
                            GradientStop { position: crumbBar.fadeW; color: "white" }
                            GradientStop { position: 1 - crumbBar.fadeW; color: "white" }
                            GradientStop { position: 1.0
                                           color: Qt.rgba(1, 1, 1, 1 - crumbBar.overR) }
                        }
                    }
                    ShaderEffectSource {
                        id: crumbMaskShot
                        sourceItem: crumbMask
                        width: crumbBar.width
                        height: Math.max(1, crumbBar.height)
                        hideSource: true
                        live: true
                        visible: false
                    }

                    // HIT-TESTING, on top of the picture. The line is a texture now,
                    // so nothing inside it can be hovered or clicked -- which costs
                    // nothing, because a crumb step was never hit-tested by the item
                    // under the pointer: linkAt asks the text engine which step is
                    // at a coordinate, and a coordinate is a coordinate wherever the
                    // mouse area lives. It only has to be told where the line sits.
                    MouseArea {
                        id: crumbMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: root.crumbHover >= 0 ? Qt.PointingHandCursor
                                                          : Qt.ArrowCursor
                        function stepAt(x, y) {
                            var l = crumbRow.linkAt(x - crumbRow.x, y)
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

                // SCROLL ANYWHERE IN THE BAR. The trail is one line of the message
                // bar, and aiming at that line to scroll it is a smaller target
                // than the bar it lives in -- so the whole bar catches the wheel
                // and hands it to the trail.
                //
                // ON TOP of the column, not under it: the crumb's own MouseArea
                // accepts wheel events whether or not it does anything with them,
                // so anything underneath would never see one over the very line it
                // is meant to scroll. `Qt.NoButton` with hover off is what keeps
                // this to the wheel alone -- presses and pointer moves fall
                // straight through to that hit-testing underneath, which is what
                // makes a step clickable.
                MouseArea {
                    id: msgWheel
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    onWheel: function (e) { e.accepted = crumbBar.wheel(e) }
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
            // CUT TO THE PANEL'S BOTTOM CORNERS when this is the foot of the
            // column -- which it is whenever nothing is playing and there is no
            // notice, since both of those collapse to nothing. Two things in here
            // reach that edge and neither is a Rectangle, so neither can round a
            // corner for itself: the backdrop is an Image and drew a hard square
            // into the bottom-left arc, and the rows are a view whose highlight bar
            // runs the full width and squared off the bottom-right one. Both
            // painted over the border while they were at it.
            //
            // ...AND BLURRED, while something floats over it.
            //
            // ONE LAYER DOES BOTH, and it has to. The blur used to be a separate
            // item drawing a BLURRED COPY over the rows -- a ShaderEffectSource of
            // bodyRow, then a MultiEffect over that -- and a ShaderEffectSource
            // does not come back right when the item it samples, or anything
            // inside it, is LAYERED. Measured three ways with a card open over a
            // masked list: the mask on bodyRow drew the cover at several times its
            // size; pinning the capture rect fixed the size and killed the blur;
            // moving the masks down onto the cover and the list killed it again.
            //
            // As a layer EFFECT there is nothing to sample. The rows are rendered
            // once into a texture and the same MultiEffect blurs it and cuts the
            // corners off it -- so the two cannot fight, and the blur now covers
            // the scroll mark and the loading glow as well, which are part of the
            // list and were sharp beside a blurred one.
            //
            // Only while there is something to do: a layer is an offscreen texture
            // and neither half is free. With a now-playing strip below and no card
            // in front, this is a plain unlayered Item exactly as it always was.
            layer.enabled: panel.bodyAtFoot || panel.veil > 0
            layer.effect: MultiEffect {
                maskEnabled: panel.bodyAtFoot
                maskSource: bodyFoot.texture
                blurEnabled: panel.veil > 0
                // Animated rather than switched, so the list settles back rather
                // than snapping sharp the instant a card starts leaving.
                blur: panel.veil
                blurMax: 40
                autoPaddingEnabled: false
            }

            Row {
                id: bodyRow
                // Its own height, centered in whatever bodyArea has become. Filling
                // the parent would hand the extra room to the list, which is the
                // one thing that must not change size.
                width: parent.width
                height: root.bodyHeight
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0
                // The menu transition. The chrome around it deliberately holds
                // still: only what CHANGED between the two menus moves.
                transformOrigin: Item.Center
                scale: root.bodyZoom
                opacity: root.bodyFade

                // NOT MASKED HERE, however much this looks like the place for it.
                // The two things inside carry it one each -- see contextCover and
                // the body Loader. Masking the Row itself is the obvious way to cut
                // the panel's bottom corners and it cannot work: the card blur
                // takes a ShaderEffectSource of this very Row, and a
                // ShaderEffectSource of a LAYERED item does not come back right.
                // Measured, with a card open over a masked list: the cover drawn at
                // several times its size, and then -- once the capture rect was
                // pinned to fix that -- no blur at all. The children carry the
                // mask instead, so nothing the blur samples is layered.

                // Only a list gets a cover beside it: a grid already shows the
                // artwork of everything in it, and an action menu is the one view
                // whose subject is otherwise invisible.
                Item {
                    id: contextCover

                    // DOUBLE CLICK OPENS IT PROPERLY. The backdrop is a picture
                    // of something -- the album you are in, the artist whose page
                    // this is, the track that is playing -- shown at the height
                    // of a menu. Asking for it full size is the obvious thing to
                    // want from it and there was no way to ask.
                    //
                    // SINGLE CLICKS FALL THROUGH. One click on the cover is a
                    // click away from whatever is in front, and dismissing is
                    // what it has always meant; propagateComposedEvents with the
                    // click refused is what lets this take the second press
                    // without swallowing the first.
                    MouseArea {
                        anchors.fill: parent
                        propagateComposedEvents: true
                        onClicked: function (m) { m.accepted = false }
                        onDoubleClicked: root.openCard("art-here")
                    }
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
                        // ...and never behind the listener. That card floats over
                        // the menu with only a scrim between them, and a square
                        // crop of the playing track's cover peering out from
                        // behind it is the "clipped albumart" -- a picture of
                        // something entirely unrelated to what spoot is doing.
                        // The rows stay, dimmed, so you can still see you have
                        // not gone anywhere.
                        && !root.listenMode
                        // NO CARD TAKES IT DOWN. A card floats OVER this list;
                        // the list has not stopped being about what it was about,
                        // and stripping its picture while a ruler or a set of
                        // counts is up made the whole panel change shape for
                        // something that changed nothing. What a card can say is
                        // that IT has no picture, which is `no_cover` and is
                        // answered where cards resolve their own art.
                        && root.themeName !== "trail" && root.themeName !== "search"
                        && root.scope !== "system" && root.scope !== "lyrics"
                    width: wanted ? root.bodyHeight : 0
                    height: root.bodyHeight
                    visible: opacity > 0
                    // IT ARRIVES RATHER THAN APPEARING. The two images below
                    // already cross-fade one cover into the next; this is the
                    // other case -- a cover appearing where there was none, which
                    // is every track played from a list that had no backdrop, and
                    // now also every cold cover the poll has just warmed. Without
                    // it the picture was simply there on the next frame.
                    //
                    // Opacity only. The WIDTH stays instant on purpose (see
                    // below): easing that drags the whole list sideways, which is
                    // motion the rows did not ask for.
                    opacity: wanted ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
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
                        // THE CROSS-FADE, which never once happened.
                        //
                        // The intent was always right: the underlay holds the
                        // cover you can see, the top one loads the next behind it
                        // at zero opacity and fades up, and only then does the
                        // underlay adopt it. What the code did was hand the
                        // underlay the new source THE MOMENT the top was ready --
                        // the same instant its opacity flipped to 1 -- so the top
                        // spent 260ms fading up over an image identical to itself
                        // and the picture changed instantly underneath. A fade
                        // was running; there was simply nothing left to fade.
                        //
                        // Three pieces now, in order: blanked when the source
                        // changes so the loading frame cannot hide the old cover,
                        // animated up once the new one is decoded, and handed
                        // down to the underlay only when the animation FINISHES.
                        opacity: 0
                        // A COVER ALREADY IN THE PIXMAP CACHE NEVER CHANGES
                        // STATUS. The fade was started from onStatusChanged
                        // alone, which is a CHANGE signal: a source whose image
                        // is already decoded goes Ready -> Ready, emits nothing,
                        // and the top image sat at zero opacity over an underlay
                        // still holding the previous cover. That is the backdrop
                        // that will not update, and it needs a cover to have been
                        // seen before -- which is why it happens after spoot has
                        // been left closed through a few tracks and not on the
                        // first one.
                        //
                        // callLater, not a test in onSourceChanged: that signal
                        // is emitted BEFORE the new source is loaded, so the
                        // status read there still describes the old picture. One
                        // turn of the event loop later it describes this one.
                        function settle() {
                            if (coverTop.status === Image.Ready && coverTop.opacity === 0)
                                coverFade.restart()
                        }
                        onSourceChanged: {
                            coverFade.stop()
                            coverTop.opacity = 0
                            Qt.callLater(coverTop.settle)
                        }
                        onStatusChanged: if (status === Image.Ready) coverFade.restart()
                        NumberAnimation {
                            id: coverFade
                            target: coverTop
                            property: "opacity"
                            from: 0; to: 1
                            duration: 420
                            easing.type: Easing.InOutSine
                            onFinished: coverUnder.source = coverTop.source
                        }
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
            // HOW FAR DOWN, while you are moving. Handed the list rather than
            // living inside it: a Flickable's children ride the content, so an
            // indicator in there would scroll away with the very rows it is
            // describing. See ScrollMark.
            //
            // AND OUTSIDE THE ROW, which is the whole of "a scrollbar appears way
            // outside spoot". A Row POSITIONS its children: declared in there this
            // was laid out after the list, its `x: body.x` binding overwritten by
            // the positioner, so the mark -- a full body's width of it -- was
            // parked one whole list to the right of the panel, out on the desktop.
            // bodyArea is a plain Item and positions nothing, so the binding holds.
            // THE SHAPE THE WHOLE BODY IS CUT TO, when it is the last thing in
            // the column and its bottom edge is the panel's own. See bodyArea.
            //
            // In bodyArea and NOT in the Row: a Row POSITIONS its children, so a
            // mask declared in there would be laid out beside the list and push it
            // off the panel -- the same trap the ScrollMark below documents.
            // bodyArea is a plain Item and positions nothing.
            CornerMask {
                id: bodyFoot
                width: bodyArea.width
                height: bodyArea.height
                bottomLeft:  panel.footCorner
                bottomRight: panel.footCorner
            }

            ScrollMark {
                theme: zenon
                view: body.item
                x: bodyRow.x + body.x; y: bodyRow.y + body.y
                width: body.width; height: body.height
                // ...and it fades with the rows it is about. Outside the Row it
                // no longer inherits the transition, and a model swap moves
                // contentY, which the mark reads as scrolling.
                fade: root.bodyFade
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
                        // Centered just above the top edge, so the light reaches
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

            // --- THE CONTEXT MENU -------------------------------------------------
            // An action menu drawn ON the list it is about instead of in place of
            // it. Last in bodyArea, so it is over everything in it -- and INSIDE
            // bodyArea rather than over the whole panel, so the breadcrumb above and
            // the now-playing strip below stay readable. The card is about a row,
            // not about the app.
            // --- THE BLUR UNDER A FLOATING CARD -----------------------------------
            // THE MENU BEHIND, BLURRED. A scrim alone dims the list but leaves
            // every row of it sharp and competing for the eye; blurring says
            // "this is still here, and it is not what you are reading" without
            // hiding what the card is about.
            //
            // Done in the scene, not by the compositor. spoot is ONE
            // wlr-layer-shell surface, so there is no second window for Hyprland
            // to blur behind -- the thing to blur is part of the same surface as
            // the thing blurring it.
            //
            // IT STAYS HERE WHILE THE CARD HAS LEFT. The card floats over the
            // whole panel now (see ctxLayer), and this is about the LIST -- so it
            // stays beside the list, a sibling of the row it is a picture of, and
            // needs no geometry of its own. It used to spell bodyRow's box out by
            // hand because it lived one level up and `anchors.fill` is silently
            // refused across that gap.
            // ...and darkened over the blur, because a blurred dark list is still
            // a dark list and the card needs somewhere to sit. Lighter than a full
            // scrim: this only has to push one back, not hide it.
            //
            // INSIDE bodyArea, so the layer above cuts it to the panel's corners
            // along with everything else. Being blurred with them costs nothing --
            // a blurred flat colour is the same flat colour.
            Rectangle {
                id: ctxScrim
                anchors.fill: bodyRow
                color: Qt.rgba(0, 0, 0, 0.45)
                opacity: panel.veil
                visible: opacity > 0
            }
            }

            // --- notification -----------------------------------------------------
            // Above the now-playing strip when there is a track, at the very foot of
            // the panel when there is not -- it is the last thing in the column
            // either way. So this needs no rule about where to sit; the column
            // already has one -- and with the now-playing strip gone from the foot
            // it is simply the last thing in it.
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
                // ...AND THE PANEL'S BOTTOM CORNERS when nothing is playing, for
                // the reason the body wears them when there is no notice: whatever
                // is last in this column is the bottom of the panel. See
                // panel.footCorner.
                bottomLeftRadius:  panel.noticeAtFoot ? panel.footCorner : 0
                bottomRightRadius: panel.noticeAtFoot ? panel.footCorner : 0
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

            // A NOW-PLAYING STRIP STOOD HERE, at the foot of the panel, and it
            // has moved to the TOP -- see nowRow, which took the row the title
            // used to have. Nothing replaces it down here: the column ends with
            // the notice bar, and whatever is last in it wears the panel's bottom
            // corners (see panel.footCorner).
        }
        // (the sheet card is declared after the floating cards, below)


        // --- THE FLOATING CARDS ---------------------------------------------------
        // A menu of verbs, or a field asking for a name, drawn ON what it is about
        // rather than in place of it. Last child of the panel, so it is over
        // everything the panel draws.
        //
        // IT USED TO LIVE INSIDE THE BODY, beside the list, and that is what made a
        // card stretch a short menu: the body had to grow to hold it (see the note
        // where ctxExtra stood), so opening a twelve-row card over a three-row menu
        // grew the panel nine rows and left those three floating in the middle of
        // it. Out here the card owes the panel nothing -- the panel keeps exactly
        // the shape it had, and the card overhangs it the way the art viewer and
        // the listener always have.
        //
        // STILL OVER SPOOT, THOUGH. Centred on the PANEL rather than on the output:
        // the viewer is a picture you are studying and takes the middle of the
        // screen, but a card is about the menu underneath it and belongs where that
        // menu is. See root.cardX / root.cardY.
        Item {
            id: ctxLayer
            anchors.fill: parent
            // TWO THINGS FLOAT OVER THE MENU: a menu of verbs, and a field asking
            // for a name. They want exactly the same treatment -- the list behind
            // blurred and pushed back, a card with the panel's own ground, a shadow
            // under it -- so they share this layer rather than the prompt growing a
            // second one that would have to be kept in agreement with it.
            opacity: (root.ctxUp || root.fieldUp) ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            // NOT CLIPPED, and this is the whole point of moving out here: a card
            // taller than the panel hangs off it rather than being cut to it.
            clip: false
            // NOTHING GETS PAST A LAYER THAT IS IN FRONT.
            //
            // This layer caught no input at all: a click on a card's shadow, on the
            // blurred list around it, on the picture itself, went straight through
            // to whatever row happened to be underneath. What stopped that being a
            // PICK was RowList.inert -- a display property doing the work of a hit
            // test, and the only thing between a stray click and the wrong track.
            //
            // Declared FIRST so it is at the bottom of this layer: the card, the
            // buttons and the rows inside it are all above and take their own
            // clicks. What reaches here is by definition a click on nothing, which
            // is a dismissal -- the same one `outside` performs, through the same
            // function. `inert` stays, as belt-and-braces rather than the mechanism.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                onClicked: root.dismissTop()
                onWheel: function (e) { e.accepted = true }
            }
                // The card's own, and this is the one no compositor could ever
                // draw: the thing it has to sit on is inside the same surface.
                // Twenty lines of grown-shape-capture-blur stood here and are
                // now in Shadow.qml, which the panel and the art viewer share --
                // see there for why a shadow is a bigger shape rather than a
                // wide blur.
                Shadow {
                    theme: zenon
                    target: ctxCard
                    // The card pops, so its shadow pops with it. Read straight
                    // off the card because it grows with `scale` rather than a
                    // transform of its own.
                    scaleFactor: ctxCard.scale
                }
                // A FIELD, FLOATING. It used to be a line in the message bar --
                // "New Playlist  ›  what you have typed so far" -- which is the
                // bar standing in for a widget that was not there: no shape, no
                // caret, and it read as a caption about the menu rather than as
                // something waiting for you. It is the same card the verbs get,
                // because it is the same kind of interruption.
                Shadow {
                    theme: zenon
                    target: promptCard
                    scaleFactor: promptCard.scale
                }
                Rectangle {
                    id: promptCard
                    visible: root.fieldUp
                    x: root.cardX(width)
                    y: root.cardY(height)
                    // As wide as what is being typed, within reason: wide enough
                    // to look like a field on an empty one, and never wider than
                    // the panel it floats over.
                    width: Math.max(420, Math.min(parent.width - zenon.rowPadH * 4,
                                                  promptQuery.implicitWidth
                                                  + zenon.rowPadH * 3))
                    // Bar, field, and the same padding above and below it. Built
                    // from the bar's own height rather than the label's, so the two
                    // cannot disagree about how tall it is.
                    height: promptTitleBar.height + promptQuery.implicitHeight
                            + zenon.messagePadV * 4 + zenon.borderWidth
                    radius: zenon.radius
                    color: zenon.ground
                    border.width: zenon.borderWidth
                    border.color: zenon.borderCol
                    // The panel's gesture at the size of a card, exactly as
                    // ctxCard takes it.
                    scale: root.fieldUp ? 1 : 0.955
                    Behavior on scale {
                        NumberAnimation { duration: zenon.popCard
                                          easing.type: Easing.OutBack
                                          easing.overshoot: zenon.popBack }
                    }
                    // WHAT IS BEING ASKED, on a bar of its own -- the same title
                    // bar the action menus and the art viewer wear, so a field and
                    // a menu are recognisably the same kind of thing.
                    Rectangle {
                        id: promptTitleBar
                        anchors { left: parent.left;  leftMargin:  zenon.borderWidth
                                  right: parent.right; rightMargin: zenon.borderWidth
                                  top: parent.top;    topMargin:   zenon.borderWidth }
                        height: promptLabel.implicitHeight + zenon.messagePadV * 4
                                - zenon.borderWidth
                        color: zenon.messageBg
                        topLeftRadius:  zenon.radius - zenon.borderWidth
                        topRightRadius: zenon.radius - zenon.borderWidth
                    }
                    Text {
                        id: promptLabel
                        anchors { verticalCenter: promptTitleBar.verticalCenter
                                  left: parent.left; right: parent.right
                                  leftMargin: zenon.rowPadH; rightMargin: zenon.rowPadH }
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        text: root.fieldLabel
                        color: zenon.playing
                        font { family: zenon.fontFamily; pointSize: zenon.fontSize; bold: true }
                    }
                    // ...AND WHAT YOU HAVE TYPED. The same field the search card
                    // wears in its header -- see QueryField, which is why there is
                    // one caret and one placeholder rule in the app rather than
                    // two. Centred here: a prompt asks a short question and is read
                    // as a label with its answer under it.
                    QueryField {
                        id: promptQuery
                        anchors { left: parent.left; right: parent.right
                                  top: promptTitleBar.bottom
                                  topMargin: zenon.messagePadV * 2 }
                        theme: zenon
                        text: root.filter
                        centered: true
                        blinking: promptCard.visible
                    }
                }
                Rectangle {
                    id: ctxCard
                    visible: root.ctxUp
                    // CENTRED ON SPOOT, and free of it. Shifting the card
                    // off-center to clear the cover was tried and is worse: a
                    // context menu belongs in the middle of what it is over, and
                    // the blur behind it already separates the two. What it is no
                    // longer centred *in* is the body -- see root.cardY.
                    x: root.cardX(width)
                    y: root.cardY(height)
                    width: root.ctxCardWidth
                    height: root.ctxCardHeight
                    radius: zenon.radius
                    color: zenon.ground
                    border.width: zenon.borderWidth
                    border.color: zenon.borderCol
                    // The panel's own gesture at the scale of a card, and now
                    // literally so: same curve, same overshoot, shorter because it
                    // is a smaller thing. It used to be an OutCubic that merely
                    // resembled the panel's -- true when the panel grew out of the
                    // screen edge, and quietly false the day the panel started to
                    // pop.
                    scale: root.ctxUp ? 1 : 0.955
                    Behavior on scale {
                        NumberAnimation { duration: zenon.popCard
                                          easing.type: Easing.OutBack
                                          easing.overshoot: zenon.popBack }
                    }

                    // WHAT THE MENU IS ABOUT, and what you have typed into it. The
                    // panel's message bar cannot say either: it is still describing
                    // the menu underneath. So the card carries its own, in the same
                    // two shapes -- the caption, or the query and its match count.
                    // THE TITLE RIDES A BAR OF ITS OWN, the way the art viewer's
                    // does -- and the way every caption in spoot does, which is on
                    // the message ground rather than on whatever is behind it. A
                    // card's caption was the one that did not: it sat straight on
                    // the card, so the card began with a line of text and there was
                    // nothing separating what the menu IS from what it OFFERS.
                    //
                    // Inset by the border and turning a little tighter than the
                    // card, for the reason artTitleBar is: a bar carrying the
                    // card's own radius leaves a sliver of ground in each corner.
                    Rectangle {
                        id: ctxTitleBar
                        anchors { left: parent.left;  leftMargin:  zenon.borderWidth
                                  right: parent.right; rightMargin: zenon.borderWidth
                                  top: parent.top;    topMargin:   zenon.borderWidth }
                        height: root.ctxHeaderH - zenon.borderWidth
                        // BLACK UNDER A FIELD, the message ground under a caption.
                        // A caption is a label ABOUT the card and sits on the same
                        // grey every caption in spoot sits on; a field is somewhere
                        // to type, and a box you type into is dark. Transparent
                        // rather than a black of its own, for the reason the top
                        // bar is: the card's ground is already black at whatever
                        // the opacity setting says, and a second black over it
                        // compounds the two alphas.
                        color: root.ctxField ? "transparent" : zenon.messageBg
                        topLeftRadius:  zenon.radius - zenon.borderWidth
                        topRightRadius: zenon.radius - zenon.borderWidth
                    }
                    // SOMEWHERE TO TYPE, where a card usually says what it is
                    // about. The search box: its history is the card's rows, so
                    // the field belongs in the same card rather than floating over
                    // it -- see Util.serve_draw's `field`.
                    QueryField {
                        id: ctxQuery
                        visible: root.ctxField
                        anchors { left: parent.left; right: parent.right
                                  verticalCenter: ctxTitleBar.verticalCenter }
                        theme: zenon
                        // liveFilter, not root.filter: typing into a card goes to
                        // ctxFilter (see setFilter), so the field bound to the
                        // panel's own filter showed nothing at all while you typed.
                        text: root.liveFilter
                        glyph: zenon.glyphSearch
                        placeholder: "Search Spotify"
                        blinking: root.ctxUp
                    }
                    // CENTRED IN THE BAR, not laid out from the card's top edge.
                    // Anchoring it to the top with the same padding the bar's
                    // height was built from put the text's BOTTOM on the bar's
                    // bottom -- the whole caption sat one border-width low, which
                    // reads as sunken because it is.
                    Column {
                        id: ctxCaption
                        visible: !root.ctxField
                        anchors { verticalCenter: ctxTitleBar.verticalCenter
                                  left: parent.left; right: parent.right
                                  leftMargin: zenon.rowPadH; rightMargin: zenon.rowPadH }
                        Repeater {
                            model: root.ctxMesgLines
                            delegate: Text {
                                width: ctxCaption.width
                                height: zenon.rowHeight
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                                text: modelData
                                // THE FIRST LINE IS THE TITLE; the rest are notes
                                // about it -- the same split the message bar under
                                // a menu makes, for the same reason: a footnote
                                // about a key sits behind the heading rather than
                                // competing with it. The engine sends those lines
                                // already styled, so this stops overriding them.
                                textFormat: index === 0 ? Text.PlainText : Text.StyledText
                                color: index === 0 ? zenon.playing : zenon.dim
                                font { family: zenon.fontFamily
                                       pointSize: zenon.fontSize
                                       bold: index === 0 }
                            }
                        }
                    }
                    // THE CARD'S BACKDROP. A square of the subject's artwork
                    // against the verbs, exactly as a list wears one -- and only
                    // when the row the card was opened from has artwork of its
                    // own. See Util.serve_card_art, which answers nothing rather
                    // than reaching for a substitute.
                    //
                    // THE SHAPE OF THE CORNER IT SITS IN. See CornerMask.
                    CornerMask {
                        id: ctxCoverFoot
                        width: ctxCover.width
                        height: ctxCover.height
                        bottomLeft: zenon.radius - zenon.borderWidth
                    }
                    // A COMMENT HERE CLAIMED THIS NEVER REACHED THE CARD'S
                    // CORNERS, "inset by the same margins the list keeps, so it
                    // needs no mask of its own". It is inset on the LEFT and at the
                    // TOP -- where the title bar covers the corners anyway -- and
                    // not at the bottom: the cover is as tall as the list beside
                    // it, and the list runs to the foot of the card. So it drew a
                    // hard square into the bottom-left arc and over the border with
                    // it, which is the backdrop overstepping a floating card.
                    //
                    // Masked only while it actually IS at the foot, measured rather
                    // than assumed -- a rounded corner in the middle of a card
                    // would be a worse artefact than the one being fixed, and a
                    // layer is an offscreen texture nobody should pay for when
                    // there is nothing to cut.
                    Image {
                        id: ctxCover
                        x: zenon.borderWidth
                        y: ctxTitleBar.height + zenon.borderWidth
                        width: Math.max(0, root.ctxCoverW - zenon.borderWidth)
                        height: ctxList.height
                        visible: root.ctxCoverW > 0
                        readonly property bool atFoot: visible && Math.abs(
                            (y + height) - (ctxCard.height - zenon.borderWidth)) <= 1
                        layer.enabled: ctxCover.atFoot
                        layer.effect: MultiEffect {
                            maskEnabled: true
                            maskSource: ctxCoverFoot.texture
                        }
                        source: root.cardArt.length ? zenon.fileUrl(root.cardArt) : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        // Fades in rather than appearing: the card is already on
                        // screen when this lands, and a picture that snaps into a
                        // menu you are reading is the thing the whole deferred-art
                        // path exists to avoid.
                        opacity: status === Image.Ready ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 180 } }
                    }
                    RowList {
                        id: ctxList
                        // BESIDE THE COVER, when there is one. Placed rather than
                        // anchored to it, because the cover is a sibling that is
                        // zero wide most of the time and an anchor chain through a
                        // collapsed item is a shape nobody can read.
                        x: root.ctxCoverW
                        y: ctxTitleBar.height + zenon.borderWidth
                        width: parent.width - root.ctxCoverW
                        height: parent.height - y - zenon.borderWidth
                        theme: zenon
                        model: ctxRows
                        // ONE COLUMN unless the menu asked for more. Every action
                        // menu the engine marks `context` is a list of verbs and
                        // takes the default; the window-position picker is the one
                        // that is a shape rather than a list, and says so with
                        // `cols`.
                        columns: root.ctxCols
                        rowHeight: root.ctxRowH
                        // ...AND WHAT A ROW IS. Words for every card but one; see
                        // root.ctxCells.
                        cellKind: root.ctxCells
                        // The value the setting is ON, as opposed to the row the
                        // cursor is on. -1 for every card that is not a picker.
                        activeIndex: root.ctxActive
                        copiedSrc: root.copiedSrc
                        flashSrc: root.ctxFlashSrc
                        flashSeq: root.ctxFlashSeq
                        playingId: root.liveId
                        playingAltId: root.liveAltId
                        paused: root.playback.playing !== true
                        // Straight from the theme the menu named, exactly as the body
                        // reads its own. Both themes an action menu can draw with --
                        // "action" and "sub" -- already say center: true, so the rows
                        // center without a second rule being written for cards.
                        centered: root.ctxG.center === true
                        rowSize: root.ctxG.rowSize || zenon.fontSize
                        rowWeight: root.ctxG.rowWeight || zenon.fontWeight
                        filter: root.ctxFilter
                        // See the body Loader: a focused view eats every key press
                        // and the keymap never runs.
                        focus: false
                        // ...and the card answers only while the card is up, which
                        // is the mirror of the body's own guard.
                        onPicked: function (i, alt) { if (root.ctxUp) root.activate(i, alt) }
                        // Nothing to close and nothing to queue: a card's rows are
                        // verbs, and the card IS the thing in front.
                        onRowQueued: function (i) { if (root.ctxUp) root.activate(i, false) }
                    }
                    // The card gets one too -- the trail menu and a long playlist
                    // picker both overflow -- placed over the list the same way.
                    ScrollMark {
                        theme: zenon
                        view: ctxList
                        x: ctxList.x; y: ctxList.y
                        width: ctxList.width; height: ctxList.height
                    }
                }
        }


        // --- the keybind reference, and the detail sheets ------------------------
        // A CARD, like every other overlay. It used to BE the panel: the panel
        // took the sheet's width and height, the column of bars inside was faded
        // out so it would not lay itself out past the new bottom edge, and the
        // body borrowed the sheet's line count -- three separate compensations for
        // one overlay pretending to be a window.
        //
        // None of that is needed by a thing that floats. The menu stays exactly
        // where it was, the sheet sits over it with its own ground and its own
        // shadow, and the panel never learns a sheet was opened.
        //
        // DECLARED AFTER ctxLayer, so it is over the action menu that opened it:
        // Track Details is a verb in a card, and the card is still standing when
        // the sheet arrives (the view answers with an event and no menu, so the
        // card is left where it was).
        Shadow {
            theme: zenon
            target: sheetCard
            fade: sheetCard.opacity
        }
        Rectangle {
            id: sheetCard
            // AS BIG AS WHAT IS IN IT, within the screen. A structured sheet
            // measures its own two columns (see PairSheet.naturalWidth); a plain
            // one has nothing to measure, so it takes the menu's width.
            width: root.sheetRows.length
                   ? Math.min(keySheet.naturalWidth + zenon.sheetPad * 2,
                              root.width - zenon.sheetPad * 4)
                   : root.g.width
            height: Math.min((root.sheetRows.length ? keySheet.contentHeight
                                                    : sheetText.implicitHeight)
                             + zenon.sheetPad * 2 + sheetTitleBar.height,
                             root.height - zenon.sheetPad * 4)
            x: root.cardX(width)
            y: root.cardY(height)
            radius: zenon.radius
            // The panel's own ground, not a near-black of its own. It used to be
            // 96% black because it was competing with a grid of covers showing
            // through from behind it -- there is nothing behind it now but the
            // card's own opaque ground.
            color: zenon.ground
            border.width: zenon.borderWidth
            border.color: zenon.borderCol
            visible: opacity > 0
            opacity: (root.sheet.length || root.sheetRows.length) ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            // The same pop the other cards use, so every floating thing in spoot
            // arrives the same way.
            scale: (root.sheet.length || root.sheetRows.length) ? 1 : 0.955
            Behavior on scale {
                NumberAnimation { duration: zenon.popCard
                                  easing.type: Easing.OutBack
                                  easing.overshoot: zenon.popBack }
            }

            // THE TITLE, on the same bar every other floating thing wears.
            Rectangle {
                id: sheetTitleBar
                anchors { left: parent.left;  leftMargin:  zenon.borderWidth
                          right: parent.right; rightMargin: zenon.borderWidth
                          top: parent.top;    topMargin:   zenon.borderWidth }
                height: sheetCap.implicitHeight + zenon.messagePadV * 4
                        - zenon.borderWidth
                color: zenon.messageBg
                topLeftRadius:  zenon.radius - zenon.borderWidth
                topRightRadius: zenon.radius - zenon.borderWidth
                Text {
                    id: sheetCap
                    anchors.centerIn: parent
                    width: parent.width - zenon.messagePadH * 2
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: root.sheetTitle
                    color: zenon.playing
                    font { family: zenon.fontFamily; pointSize: zenon.fontSize; bold: true }
                }
            }
            Flickable {
                anchors { top: sheetTitleBar.bottom; left: parent.left
                          right: parent.right; bottom: parent.bottom }
                // The same padding the card was sized with, so the measured fit
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
                    // THE KEYS WEAR CAPS, and only the keys. A detail sheet's left
                    // column is a field NAME -- "Album", "Released" -- and a
                    // rounded grey pill around a word like that reads as a button
                    // you can press. A key is a key, and a key looks like one.
                    capsuleKeys: root.sheetKind === "keybinds"
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
    }

    // --- the listener ---------------------------------------------------------
    //
    // WHAT SPOOT IS DOING, as a sentence with a light going round it.
    //
    // It used to be the image viewer wearing a different hat: a 300px speaker
    // glyph with a caption under it, because in the rofi build a window with a
    // picture was the only way to look like something was happening. Every number
    // in that card then had two answers -- one for a picture, one for this -- and
    // the wrong one arrived mid-fade often enough to need a latch. This is its own
    // item, so it has one answer for everything and the viewer does too.
    //
    // It follows the PANEL, unlike the viewer: the viewer is a picture you study
    // and takes the middle of the output, but this is spoot working, and it
    // belongs where spoot is.
    Item {
        id: listenLayer
        anchors.fill: parent
        // WHICH OF THE TWO IS UP, read off the LATCH rather than off listenMode.
        // Both float on the same artShowFactor, so without this the viewer's card
        // opened alongside the pill -- an empty black box with no picture in it,
        // because artPath is empty while the listener is up. The latch is what
        // survives the close: listenMode flips the instant the theme clears, which
        // is while the pill is still fading out.
        visible: opacity > 0 && root.artShown === "listen"
        opacity: root.artShowFactor * root.showFactor

        Shadow {
            theme: zenon
            target: listenPill
            cornerRadius: listenPill.radius
            scaleFactor: root.artScale
        }

        Rectangle {
            id: listenPill
            // TWICE THE LINE IT CARRIES. Everything else follows: the corner is
            // half the height, which is what makes it a capsule rather than a
            // rounded box, and the ends are padded by that same half-height so
            // they are as generous as the top and bottom.
            height: Math.round(listenCap.implicitHeight * 2)
            readonly property int padH: Math.round(height / 2)
            width: Math.round(listenCap.implicitWidth) + padH * 2
            radius: height / 2
            // THE PANEL'S OWN GROUND, which carries the opacity setting -- so the
            // pill is exactly as solid as the window, whatever that is set to.
            color: zenon.ground
            x: Math.round((parent.width - width) / 2)
            // Lifted off whichever edge spoot opens against, the way the listener
            // always has been: floating rather than docked.
            y: root.anchorV === "middle"
                    ? Math.round((parent.height - height) / 2)
             : root.anchorV === "top" ? zenon.listenLift
             : parent.height - height - zenon.listenLift
            // The panel's gesture at the size of a pill -- same curve, same
            // overshoot, out of its own centre.
            transform: Scale {
                origin.x: listenPill.width / 2
                origin.y: listenPill.height / 2
                xScale: root.artScale
                yScale: root.artScale
            }

            // THE LIGHT GOING ROUND THE EDGE, drawn as a gradient that is covered
            // everywhere except the edge.
            //
            // No mask and no shader: a rounded rectangle painted with the
            // gradient, and a second rounded rectangle inset by the line's width
            // painted with the ground on top of it. What is left showing is a
            // band exactly `listenEdge` wide that follows the capsule's own
            // curve -- which is the one way to get a gradient border in Qt Quick
            // without either of those.
            Rectangle {
                id: listenEdge
                anchors.fill: parent
                radius: parent.radius
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    // THE SWEEP, clamped so the stops stay in order however far
                    // the animation runs past either end. It runs past on
                    // purpose: starting at -0.25 and finishing at 1.25 is what
                    // gives the light somewhere to come from and somewhere to go,
                    // instead of appearing at the left edge and vanishing at the
                    // right.
                    GradientStop { position: 0.0; color: zenon.fade(zenon.listenGlow, 0.20) }
                    GradientStop { position: Math.max(0.001, Math.min(0.997, listenEdge.sweep - 0.16))
                                   color: zenon.fade(zenon.listenGlow, 0.20) }
                    GradientStop { position: Math.max(0.002, Math.min(0.998, listenEdge.sweep))
                                   color: zenon.listenGlow }
                    GradientStop { position: Math.max(0.003, Math.min(0.999, listenEdge.sweep + 0.16))
                                   color: zenon.fade(zenon.listenGlow, 0.20) }
                    GradientStop { position: 1.0; color: zenon.fade(zenon.listenGlow, 0.20) }
                }
                property real sweep: 0
                NumberAnimation on sweep {
                    running: root.listenMode
                    loops: Animation.Infinite
                    from: -0.25; to: 1.25
                    duration: zenon.listenSweepMs
                    easing.type: Easing.InOutSine
                }
            }
            // ...and the inside, which is what turns the gradient into a line.
            Rectangle {
                anchors.fill: parent
                anchors.margins: zenon.listenEdge
                radius: parent.radius - zenon.listenEdge
                color: zenon.ground
            }

            Text {
                id: listenCap
                anchors.centerIn: parent
                text: root.artMesg
                // GREEN AND BREATHING, because it is not a label -- it is spoot
                // saying it is still working, on the same beat as the light.
                color: zenon.playing
                font.family: zenon.fontFamily
                font.pointSize: zenon.listenCapSize
                font.bold: true
                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    running: root.listenMode
                    NumberAnimation { from: 0.55; to: 1.0; duration: 900
                                      easing.type: Easing.InOutSine }
                    NumberAnimation { from: 1.0; to: 0.55; duration: 900
                                      easing.type: Easing.InOutSine }
                }
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
        // ON THE SURFACE, not inside the panel. The comment above has said "a
        // card over the menu" since it was written, and the code did not do it:
        // the PANEL was resized and re-centered to become the card's frame, so
        // its ground painted a second black box behind every picture and its
        // bottom-squaring strip -- which exists because ZENON rounds only the
        // top pair of corners on a menu docked south -- drew square corners
        // under the card's round ones. One cause, both complaints.
        //
        // Out here the panel is left entirely alone: it keeps its shape, keeps
        // its place, and is simply dimmed behind the picture, which is what the
        // scrim below was always for.
        anchors.fill: parent
        // ...AND ONLY WHEN IT HAS A PICTURE. The listener shares artShowFactor
        // with this, so without the test the viewer's card opened alongside the
        // pill -- a black box with nothing in it. Off the latch rather than off
        // artPath, so it survives its own fade out.
        visible: opacity > 0 && root.artShown.length > 0 && root.artShown !== "listen"
        // Fades with the app as well as with itself, which it used to get for
        // free by being the panel's child.
        //
        // No Behavior: the fade IS the animation now (see artShowFactor), and a
        // Behavior on the property it feeds re-animates every frame of it
        // towards the frame after -- the same smear the panel's own opacity
        // carries a note about.
        opacity: root.artShowFactor * root.showFactor
        // See ctxLayer's catcher, and for the same reason: a picture drawn over
        // the menu must not let a click reach the rows under it. Declared before
        // the card so the card's own contents stay clickable above it.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            onClicked: root.dismissTop()
            onWheel: function (e) { e.accepted = true }
        }

        // The menu is still there, just behind. Dark enough that the picture
        // is what you are looking at, light enough that you can see you have
        // not gone anywhere.
        //
        // A SCRIM STOOD HERE, dimming the whole output behind the card. It went
        // for the listener first -- a small thing working away in a corner has no
        // business blacking out the machine -- and then for the image viewer too,
        // for the same reason: spoot is a panel on your desktop, not something
        // that takes the desktop over while you look at a cover. Each card carries
        // its own ground and its own frame, which is enough to sit on.

        // A CARD FLOATS, SO IT CASTS. The viewer and the listener are the last
        // two things on the surface that did not, and both of them are drawn over
        // a menu that is inside this same scene -- so unlike the panel's, this
        // shadow falls on something spoot actually drew. Shared with the panel
        // and the context card; see Shadow.qml.
        Shadow {
            theme: zenon
            target: artCard
            scaleFactor: root.artScale
        }

        Rectangle {
            id: artCard
            // A PICTURE IS LOOKED AT; A LISTENER IS WAITED ON. The image viewer
            // takes the middle of the output, where a thing you are studying
            // belongs. The listener is a small card you glance at while it works,
            // so it sits over the bottom edge where every other view lives --
            // lifted clear of it, floating rather than docked.
            // THE LISTENER FOLLOWS THE PANEL; THE VIEWER DOES NOT. A picture is
            // looked at, so it takes the middle of the output wherever the menu
            // happens to live. The listener is the app working, and belongs where
            // the app is -- with the panel moved to the top, a card still hovering
            // over the bottom edge reads as a different program's window.
            //
            // PLACED, NOT ANCHORED, for the reason the panel is (see its x and y):
            // clearing an anchor by binding it to `undefined` does not reliably
            // let go. This card switched between verticalCenter and bottom every
            // time it changed from viewer to listener, and an item anchored two
            // ways on one axis STRETCHES -- which is the listener growing to span
            // the output. One expression per axis cannot do that.
            // THE MIDDLE OF THE OUTPUT. A picture is a thing you are studying, so
            // it takes the centre wherever the menu happens to live.
            //
            // It used to branch here for the listener, which followed the panel to
            // whichever edge spoot opens against -- and every branch below did the
            // same. The listener is its own item now (see listenPill), so this card
            // is the viewer and nothing else, and each of those branches is simply
            // the answer it always gave for a picture.
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            // The panel's gesture, at the size of a card. Out of its own centre,
            // which is the only point on it that is not going anywhere.
            transform: [
                Scale {
                    origin.x: artCard.width / 2
                    origin.y: artCard.height / 2
                    xScale: root.artScale
                    yScale: root.artScale
                }
            ]
            // ROOM AROUND THE PICTURE, so the corners can actually be round. This
            // carried a 300px image in a 310px box: the image's own square corners
            // sat exactly where the card's rounded ones are, and `clip` is a
            // bounding-box clip, so what you got was a square. A listener is a
            // glyph rather than artwork and can afford the margin.
            readonly property int pad: root.artPad
            // Restored after a cleanup regex ate them: both lines carry a `+`,
            // and the pattern removing some throwaway logging above was greedy
            // enough to take every continuation line that had one. The card has
            // been sized 0x0 ever since, which is why neither the image viewer
            // nor the listener drew anything at all.
            // WIDE ENOUGH FOR WHAT IT SAYS. The picture decides for the viewer --
            // a cover is the thing you came to look at -- but the listener's
            // picture is a 200px glyph and its CAPTION is the content: one of a
            // dozen lines, a different one each time, and every one of them
            // longer than 200px. They were being elided to "spoot is consulting
            // t…", which is the joke cut off before the punchline.
            width: artImage.width + pad * 2
            // The bar sits flush on the picture, so there is no gap between them
            // to account for -- pad, bar, picture, pad.
            height: pad * 2 + artTitleBar.height + artImage.height
            // BOTH ARE CARDS, and a card in spoot has a ground and round corners.
            // The viewer used to have neither: transparent, square, and a title
            // bar at 40% alpha with NOTHING BEHIND IT -- so the bar you can read
            // everywhere else, where it sits on the panel's ground, was a sheet
            // of glass over the desktop here. The picture hides the ground
            // wherever it covers it; what the ground is actually for is the bar
            // and the 2px rule around it.
            color: zenon.cardGround
            radius: zenon.radius
            border.width: 0
            border.color: zenon.borderCol
            clip: true

            // THE FRAME AND THE TITLE BAR, declared before everything they sit
            // behind. Viewer only: the listener already has a card of its own,
            // and a second rule inside it would be a box in a box.
            Rectangle {
                id: artFrame
                anchors.fill: parent
                color: "transparent"
                border.width: zenon.artBorder
                border.color: zenon.borderCol
                // THE RULE TURNS THE SAME CORNER THE CARD DOES. A square border
                // over a rounded card draws its corner OUTSIDE the rounding --
                // four hard right angles sitting just past the curve, which is
                // the sharp edge showing behind every rounded one. It fills the
                // card exactly, so it takes the card's radius exactly.
                radius: parent.radius
            }
            Rectangle {
                id: artTitleBar
                anchors {
                    left: parent.left;  leftMargin:  zenon.artBorder
                    right: parent.right; rightMargin: zenon.artBorder
                    top: parent.top;    topMargin:   zenon.artBorder
                }
                // Its own height, never the card's -- the card is measured FROM
                // this, and reading it back would be a loop.
                height: artCap.implicitHeight + zenon.messagePadV * 2
                color: zenon.messageBg
                // Inside the rule, so it turns a little tighter than the card
                // does -- a bar that carried the card's own 10px would leave a
                // sliver of ground showing in each top corner.
                topLeftRadius:  zenon.radius - zenon.artBorder
                topRightRadius: zenon.radius - zenon.artBorder
            }

            // THREE EXPANDING RINGS STOOD HERE, chasing each other outward on a
            // stagger to say "receiving" during the thirty-second wait. They said
            // it over the top of the thing that was already saying it -- the line
            // underneath, which changes every time and is the part with any
            // personality -- and they said it loudest: a ring sweeping past the
            // words is what the eye follows, so the one-liner was furniture
            // behind an animation. The glyph still breathes and the caption still
            // pulses on the same beat; that is enough for a card that is asking
            // you to wait.

            // THE CAPTION SITS ABOVE THE PICTURE, as it did in rofi: art.rasi
            // and imp.rasi both order their mainbox [message, listview].
            //
            // ...and UNDER it while listening, where it belongs: above a cover the
            // words name the thing, under a spinner they are its status.
            Text {
                id: artCap
                anchors {
                    // A TITLE, in the middle of the bar that carries it.
                    verticalCenter: artTitleBar.verticalCenter
                    horizontalCenter: parent.horizontalCenter
                }
                width: parent.width - zenon.messagePadH
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: root.artMesg
                color: zenon.foreground
                font.family: zenon.fontFamily
                font.pointSize: zenon.fontSize
                font.bold: true
            }
            // THE PICTURE FOLLOWS THE CARD'S CORNERS. `clip` is a bounding-box
            // clip and cannot round anything, and a 2px rule is far too thin to
            // hide a square corner inside a 10px round one -- the picture's
            // corners came through the frame and the card read as square. Its
            // top two are under the title bar; only the bottom two are exposed,
            // so only those are cut.
            //
            // Through CornerMask, which is the rounded-rectangle-into-a-texture
            // pair written once. This was a third hand-rolled copy of it.
            CornerMask {
                id: artMask
                width: artImage.width
                height: artImage.height
                bottomLeft:  zenon.radius - zenon.artBorder
                bottomRight: zenon.radius - zenon.artBorder
            }
            Image {
                id: artImage
                // ...and the picture moves with it: first while listening, second
                // everywhere else.
                anchors {
                    // Flush under the title bar, which is what makes the two read
                    // as one framed object rather than a caption floating above a
                    // picture.
                    top: artTitleBar.bottom
                    horizontalCenter: parent.horizontalCenter
                }
                // EXACTLY the size the theme names -- art.rasi 1000,
                // imp.rasi 640, listen.rasi 300 -- as a square, both sides.
                // Not fitted to the window: the WINDOW is what gives way,
                // widening to hold the picture and its frame (see root.width).
                width: root.artIcon
                height: width
                // ...AND NOTHING AT ALL WHEN THE LATCH SAYS "listen". `artShown`
                // is shared with the pill, which latches the word rather than a
                // path -- so this Image was handed `file://listen` on every
                // listen and said so in the log. `visible: false` does not stop a
                // source binding from being evaluated; only the binding can.
                // The LATCHED path, never root.artPath: the card has to keep
                // something to shrink around while the close plays. See
                // root.artShown.
                source: root.artShown === "listen" ? ""
                                                   : zenon.fileUrl(root.artShown)
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
                // VIEWER ONLY. The listener's picture is a glyph with room
                // around it on all four sides, so the card's corners are already
                // clear of it and a mask would be a texture drawn for nothing.
                layer.enabled: true
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: artMask.texture
                }
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

    // ASKING HOW IT IS GOING. The engine no longer sits in a loop waiting for
    // songrec -- it starts it, and answers "still listening" until there is
    // something to say (see Util.listen_poll). This is the asking, and it only
    // runs while the card is actually up.
    //
    // That loop is what used to lock spoot out entirely: thirty seconds during
    // which no request was read, the loading glow breathed forever because the
    // draw it was waiting on could not arrive, and killing the process left
    // songrec holding the audio monitor.
    Timer {
        id: listenPoll
        interval: 400
        repeat: true
        running: root.listenMode
        onTriggered: root.call("listen-poll", {}, function (r) {
            if (!r || r.state === "listening") return
            // Whatever it says, the card is done.
            root.closeOverlay()
            if (r.state === "match") {
                // THE IDENTIFIED TRACK, as its own action menu -- a card over
                // whatever you were on, costing no trail step, which is what
                // "jump to it" can mean now that an action menu is an overlay.
                root.openCard("listen-result")
            }
            else if (r.state === "notfound") {
                root.notify("Not on Spotify \u2014 " + (r.label || ""))
            }
            else if (r.state === "none") root.notify("No match")
        })
    }

    // --- keys ----------------------------------------------------------------
    Keymap { app: root }
}
