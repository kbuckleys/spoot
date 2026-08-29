// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// ZENON, transcribed.
//
// Every value here is lifted from style/ZENON.rasi and the per-view files that
// import it, so a colour that looks wrong is a transcription bug with an exact
// answer in the original -- not a judgement call. rofi's cascade of
// normal/urgent/active x normal/selected/alternate collapses to the handful of
// states anything actually used.
import QtQuick

QtObject {
    // --- palette (ZENON.rasi `*`) -------------------------------------------
    // WHAT THE USER SET, or nothing yet. The engine sends a `settings` event
    // before the first draw and again on every change; main.qml binds it here.
    // Every read goes through cfgVal so a value that has not arrived -- or a
    // spoot whose ui.json predates the setting -- falls back to the constant
    // that used to be written in its place.
    property var cfg: ({})
    function cfgVal(key, fallback) {
        var v = cfg ? cfg[key] : undefined
        return v === undefined ? fallback : v
    }

    // 0.8 was the constant; it is now the default, and the two have to agree --
    // see Util.UI_SETTINGS. Deleting ui.json is the test.
    readonly property color ground: Qt.rgba(0, 0, 0, cfgVal("opacity", 80) / 100)
    // A CARD THAT FLOATS FREE OF THE PANEL IS OPAQUE. `ground` is see-through on
    // purpose -- the panel is a HUD and your desktop is meant to show through it
    // -- and that reads because everything ON the panel shares the one ground.
    // A card out over the desktop has nothing behind it that spoot drew, so the
    // same alpha turns its title bar into a window onto whatever happens to be
    // under it: the art viewer's caption was legible terminal text. Same colour,
    // no alpha.
    readonly property color cardGround: Qt.rgba(0, 0, 0, 1)
    readonly property color foreground:  "#DFDFDD"
    readonly property color selectedBg:  Qt.rgba(69/255, 80/255, 92/255, 0.3)
    readonly property color messageBg:   Qt.rgba(40/255, 47/255, 54/255, 0.4)
    readonly property color borderCol:   Qt.rgba(155/255, 191/255, 191/255, 0.2)
    readonly property color separator:   Qt.rgba(69/255, 80/255, 92/255, 0.3)
    // ZENON's `blue`, `red` and `urgent` were transcribed here and painted
    // nothing -- and two of the three were the same value under two names, which
    // is how a palette starts disagreeing with itself. The colours the app
    // actually wears are above and below this line; the originals are in
    // ZENON.rasi, which is where a value nothing reads belongs.

    // Not in ZENON but used throughout spoot.lua's markup, so they belong to the
    // same system: the dim grey rows wear, the green a playing row wears, and
    // the crumb arrow's near-invisible grey.
    readonly property color dim:         "#6c7086"
    readonly property color playing:     "#b6e0a4"
    // The played portion of the now-playing strip. Dark enough that the same
    // green text reads over it as over the unplayed grey -- so the fill marks
    // progress without the line changing colour underneath you.
    readonly property color progressFill: "#101b0e"
    readonly property color crumbArrow:  "#454a55"
    // Between ROOTS rather than between steps: a trail you jumped away from and
    // a trail you jumped into are joined by this, not by an arrow. Glyph and
    // colour both straight out of the rofi build's Util.trail_label.
    readonly property string crumbRootSep: "\u{F17B7}"
    readonly property color crumbRoot:   "#a3a9bd"
    // The key colour, and the field-name colour from Util.detail_sheet's markup.
    //
    // THE KEYS ARE GREEN. They were the rofi sheet's own pale red, which was the
    // one place in spoot that colour appeared -- and a key is a thing you press,
    // which is the same family as a row that is playing and a value that is set.
    // ZENON has one accent and this is it.
    readonly property color keyCap:      playing
    // ...AND THE CAP THE KEY SITS IN. A grey pill with a slightly lighter edge,
    // the same shape a keyboard shortcut wears in a GitHub table -- light enough
    // to read as a raised key against ZENON's ground, dark enough that a column
    // of twenty of them is not the loudest thing on the sheet. Only the keybind
    // reference draws these; see PairSheet.capsuleKeys.
    readonly property color keyCapBg:    "#2a2e36"
    readonly property color keyCapEdge:  "#3a3f49"
    readonly property color fieldName:   "#9bbfbf"
    // message.rasi's peach -- ZENON's own colour for a standalone remark, as
    // opposed to a caption or a row. It was the BACKGROUND there because rofi
    // could only make a remark by opening a window for it, and a whole window
    // needed to look like an interruption. Here the notice is a bar inside the
    // panel you are already looking at, so the peach is the text and the ground
    // stays ZENON's.
    readonly property color notice:      "#fab387"

    // --- typography ---------------------------------------------------------
    readonly property string fontFamily: "JetBrainsMono Nerd Font Propo"
    readonly property int    fontSize:   12
    // MEDIUM, not Normal. ZENON.rasi's base is "JetBrainsMono Nerd Font Propo
    // Medium 12" and every list row inherits it -- only thumbs.rasi overrides
    // element-text, at SemiBold 11, which the tiles below already have. Rows
    // were being drawn a weight lighter than the whole design asks for, which
    // does not read as "lighter", it reads as smaller.
    readonly property int    fontWeight: Font.Medium
    readonly property int    tileFontSize: 11
    // The detail sheets (meta, binds, pods) run a point larger than a menu row:
    // they are read, not scanned. MEDIUM, not DemiBold -- all three of those
    // files say "JetBrainsMono Nerd Font Propo Medium 13" and we were rendering
    // them a weight heavy.
    readonly property int    sheetFontSize: 13
    readonly property int    sheetFontWeight: Font.Medium
    // Breathing room between a sheet's content and its frame, on every side. Was
    // 10, which read as text pressed against the edges of a box rather than as a
    // page with a margin.
    // The gap between a sheet's content and the panel edge. 20 read as text
    // pressed against the frame once the sheets grew past a handful of rows.
    readonly property int    sheetPad: 32
    // spoot.lua's SEP, the glyph it puts between a title and its subtitle in
    // every message bar. Defined once here so the now-playing strip separates
    // its fields with the same mark the rest of the app does, rather than a
    // middot that looks like a different program wrote it.
    readonly property string sep: " \u{F01D8} "
    // spoot.lua's Util.transport_glyph, verbatim: play and pause, not lookalikes.
    readonly property string glyphPlay:  "\uF04B "
    readonly property string glyphPause: "\uF04C "
    // Alt+g's receipt, shown beside the track for a second. See NowContent.
    readonly property string glyphCopied: "\u{F018F}"
    // display_album's mark for a one-track album, verbatim, for the same reason
    // the transport glyphs above are here: the tile has to find it in the caption
    // to know where the transport marker goes. It is the engine that DRAWS it --
    // this is only how the grid recognises it. See TileGrid.
    readonly property string glyphSingle: "\u{F069F}"
    // SHUFFLE AND REPEAT, verbatim from the engine's status_mesg -- the same
    // glyphs and the same three colours, so the pair reads as the state it read
    // as in rofi. Alt+s and Alt+r toggled these with nothing on screen changing:
    // rofi drew them in Main's message bar, and that bar is built as a FUNCTION,
    // which serve_draw only ever takes as a string. Here they live in the
    // now-playing strip instead, which is better than where they were -- the
    // state is true everywhere, not only on Main.
    readonly property string glyphRepeatTrack: "\u{F0458}"
    readonly property string glyphRepeatAll:   "\u{F0456}"
    readonly property string glyphRepeatOff:   "\u{F0457}"
    // The two the dock needs and the strip never did: the now-playing bar shows
    // WHAT is playing, the dock is where you drive it.
    readonly property string glyphPrev:  "\uF048"
    readonly property string glyphNext:  "\uF051"
    readonly property string glyphSpoot: "\u{F1BC}"
    // The liked heart, filled and hollow. The filled one is the same codepoint
    // Util.status_icons puts on a saved row -- one value for the whole app, so a
    // row and the dock cannot end up drawing different hearts.
    readonly property string glyphLiked:  "\u{f05d}"
    readonly property string glyphUnliked: "\u{f08a}"
    readonly property string glyphShuffleOn:   "\u{F074}"
    readonly property string glyphShuffleOff:  "\u{F049D}"
    // No statusOff colour: an unlit control is the same green turned down, not
    // a grey that happens to mean the same thing. See NowContent.

    // --- window (ZENON `window`, main.rasi `window`) -------------------------
    readonly property int  radius:      10
    readonly property int  borderWidth: 1
    // OFF THE EDGE. The panel used to sit ON the bottom of the screen with its
    // lower corners squared, which is what a surface anchored to an edge looks
    // like. Lifted clear of it, all four corners are its own and the drop shadow
    // has somewhere to fall -- so this and the rounding below are one change,
    // not two: square corners floating in the middle of nothing would read as a
    // mistake.
    readonly property int  panelLift:   28
    // THE GESTURE, in one place. Everything that arrives as a floating thing --
    // the panel, and the context card over it -- expands out of its own center,
    // past its size by a hair, and settles. Two elements hand-tuned to "the same
    // move" is how the card ended up carrying a comment claiming to copy a panel
    // curve it no longer matched, so the curve is a token and only the duration
    // is per-element: a card is smaller and reads quicker at the same speed.
    readonly property int  popIn:       210
    readonly property int  popOut:      190
    readonly property int  popCard:     150
    readonly property real popBack:     1.35    // overshoot arriving
    readonly property real popBackOut:  0.8     // wind-up leaving
    // THE DROP SHADOW, spoot's own. Compositor shadows are a per-user Hyprland
    // setting and apply to a whole surface anyway -- spoot is one surface, so a
    // compositor could never put a shadow under the cards that float INSIDE it.
    // Drawn in the scene instead, which also means it looks the same on every
    // setup rather than on whichever ones happen to have shadows switched on.
    //
    // Four things read these, through one Shadow.qml: the panel, the context
    // card, the art viewer and the listener -- and they all read the SAME ones,
    // so the window and the card that floats over it are lit alike. The panel is
    // the odd one out only in where its shadow lands: its surface is the whole
    // output, so the shadow falls on a desktop spoot cannot see. It is drawn
    // anyway, because without it the panel reads as a hole in the screen rather
    // than a thing lying on it.
    //
    // spread is how far the blur reaches past the edge, drop is how far the light
    // is above the object. Both small: this is a panel lifted off a desktop, not
    // a card thrown across a room.
    // A DROP SHADOW IS THREE SEPARATE THINGS, and folding them into one number
    // is why asking for a bigger one made it fainter: a blur REDISTRIBUTES what
    // it is given, so widening it alone spreads the same ink thinner until there
    // is nothing left to see. Measured: at a 28px blur the shadow peaked at 43/255
    // just outside the panel; at 64px, 8.
    //
    //   grow  -- how far the shape is inflated BEFORE blurring. This is what
    //            makes a shadow big and PRESENT rather than merely soft, and it
    //            is the piece that was missing. CSS calls it spread.
    //   blur  -- the softness of the edge. MultiEffect's useful ceiling is 64.
    //   drop  -- how far below the object it sits, because the light is above.
    // Softer and further out: the blur is now wide RELATIVE to the grow, which is
    // what makes a shadow read as gentle rather than as a dark edge -- a big grow
    // with a small blur is just a bigger hard shape. 64 is MultiEffect's useful
    // ceiling for blurMax, so the softness comes from spending less on grow.
    //
    // SOFTER AGAIN. Blur was already at its ceiling, so the only way left to
    // gentle it is to give the blur less to work with: 20px of grow put a band of
    // near-solid ink right against the panel that no amount of blur could reach
    // into, and that band is what reads as a hard edge. Halving the grow and
    // taking a third off the alpha leaves the same reach -- grow + blur is still
    // most of 74px -- with nothing opaque in it.
    readonly property int  shadowGrow:  10
    readonly property int  shadowBlur:  64
    readonly property int  shadowDrop:  14
    // ONE GATE FOR EVERY SHADOW. The panel's and the context card's both
    // multiply by this, so turning them off is this going to zero rather than a
    // flag threaded through two effect stacks. The layers are also made
    // invisible where they are drawn, so nothing blurs a texture nobody sees.
    readonly property bool shadows:     cfgVal("shadows", true)
    readonly property real shadowAlpha: shadows ? 0.34 : 0
    // What the capture has to be padded by for none of it to be clipped: the blur
    // cannot paint outside the texture it is given, and a clipped blur comes out
    // as a hard rectangle -- which is exactly how this first went wrong.
    readonly property int  shadowPad:   shadowGrow + shadowBlur + shadowDrop

    // --- message bar (ZENON `message`) --------------------------------------
    // The rule around a picture in the viewer, and the room the card leaves for
    // it -- one number, so the frame can never be wider than the space it has.
    readonly property int  artBorder:  2
    readonly property int messagePadV: 5
    readonly property int messagePadH: 30

    // --- input bar (ZENON `inputbar`, search.rasi) ---------------------------
    //
    // The ONE menu that has one. Seven themes list `inputbar` among their
    // mainbox children and every one of them but search.rasi then says
    // `enabled: false` -- so the theme name is the whole condition for drawing
    // it, and no view name has to appear in layout code.
    //
    // search.rasi gives it the Spotify glyph as `textbox-prompt-colon { str }`
    // and two fonts a size apart from the rest of ZENON: the prompt at 14, the
    // entry at 13, both SemiBold, both in the playing green.
    readonly property string glyphSearch: "\u{F1BC}"
    readonly property int promptSize: 14
    readonly property int entrySize:  13
    // The image viewer's caption. art.rasi and imp.rasi say Bold 12 like every
    // other message bar; listen.rasi alone says Bold 13, and it was being drawn
    // at 12 with the rest.
    readonly property int listenCapSize: 13
    // THE PILL. Its height is twice the line it carries, which is the whole of
    // its proportion -- everything else follows from that: the corner is half the
    // height (a pill is a capsule), and the horizontal padding is the same
    // half-height again so the ends are as generous as the top and bottom.
    readonly property int listenEdge: 2          // the traced line's width
    readonly property color listenGlow: playing  // ...and its colour, ZENON's green
    readonly property int listenSweepMs: 1600    // one lap of the light
    // How far the listening card floats above the bottom edge. It is not docked
    // like a menu -- it is a small thing working away while you wait -- so it sits
    // clear of the edge rather than growing out of it.
    readonly property int listenLift: 90
    // FIXED, and deliberately not derived from anything. The listener is the same
    // small card whatever it is drawn over and whichever output it lands on --
    // it used to take its size from the theme table through root.g, which falls
    // back to the MENU's geometry the moment the overlay theme clears, and from
    // the surface, which is recreated per monitor. Between them the card changed
    // shape on the way out and again on the way to a differently-shaped screen.
    // `listenIcon` STOOD HERE at 200 -- the size of the speaker glyph the listener
    // used to draw. There is no glyph any more (see listenPill), and the asset is
    // gone from engine/assets with it.
    // textbox-prompt-colon padding: 6px 10px 6px 20px -- the glyph sits well in
    // from the edge, close to what you type.
    readonly property int promptPadL: 20
    readonly property int promptPadR: 10
    // entry padding: 6px on every side.
    readonly property int entryPad: 6

    // --- rows (ZENON `element`) ---------------------------------------------
    // `rowPadV` stood beside this and was read by nothing: a row's height is
    // stated outright below rather than built up from padding.
    readonly property int rowPadH: 20
    // A text row's total height. `listRows` was here too, saying 12, while every
    // list in the app takes its row count from viewGeom (14) or from the user's
    // listLines setting -- two answers to one question, one of them wrong and
    // read by nobody. `mainWidth: 1000` went for the same reason: mainGeom and
    // baseWidth already say it, and three copies of a number is two chances to
    // change it in the wrong place.
    readonly property int rowHeight: 26

    // --- PER-VIEW GEOMETRY, transcribed from style/*.rasi ---------------------
    //
    // Keyed by the theme name the ENGINE reports, which is the same theme rofi
    // would have been handed -- so there is one mapping from view to geometry in
    // the whole system, and it is the original one. Adding a view here means
    // adding a row, never touching layout code.
    //
    //   width   px, from each file's `window { width: }`
    //   columns from `listview { columns: }` -- the default list really is TWO
    //   lines   from `listview { lines: }`, the visible row count
    //   icon    from `element-icon { size: }`, where the view shows one
    readonly property var viewGeom: ({
        // ONE COLUMN. rofi's listview is a grid whose default flow is vertical,
        // and ZENON's plain list really is two columns wide -- which fills DOWN,
        // so reading it means going to the bottom of the left column and back up
        // to the top of the right, and finding something you half-remember means
        // reading it twice. It was right for a menu of a dozen verbs and wrong
        // for every shelf in the app.
        "menu":      {width: 1000, columns: 1, lines: 14},
        "thumbs":    {width: 1000, columns: 5, lines: 3,  icon: 150},
        "album":     {width: 1000, columns: 1, lines: 14, icon: 364},
        "action":    {width: 1000, columns: 1, lines: 14, icon: 364, center: true},
        // CENTRED. These are menus of choices rather than shelves of content:
        // a handful of verbs or settings, read as a group. A shelf of hundreds
        // of tracks stays left-aligned, because a ragged left edge is what makes
        // a long list unscannable.
        "sub":       {width: 700,  columns: 1, lines: 11, center: true},
        "search":    {width: 700,  columns: 1, lines: 6,  center: true},
        "searchall": {width: 1000, columns: 1, lines: 14},
        "trail":     {width: 900,  columns: 1, lines: 14, center: true},
        // Lyrics are READ, not scanned, so they are the one list that centers its
        // rows and sets its own type. Both come from lyrics.rasi -- `element-text
        // { horizontal-align: 0.5 }` and a 14pt face, neither of which survived
        // transcription. Only the weight is a departure: Medium there, SemiBold
        // here.
        "lyrics":    {width: 1000, columns: 1, lines: 14,
                      center: true, rowSize: 14, rowWeight: Font.DemiBold},
        "pods":      {width: 1100, columns: 1, lines: 14},
        "meta":      {width: 900,  columns: 1, lines: 14},
        "binds":     {width: 680,  columns: 1, lines: 14},
        "message":   {width: 700,  columns: 1, lines: 14},
        "art":       {width: 1000, columns: 1, lines: 1,  icon: 1000},
        "imp":       {width: 640,  columns: 1, lines: 1,  icon: 640},
        "listen":    {width: 304,  columns: 1, lines: 1,  icon: 300}
    })
    // main.rasi is the root grid and has no theme name of its own -- it is what
    // rofi is given directly -- so it is the fallback.
    readonly property var mainGeom: ({width: 1000, columns: 5, lines: 3, icon: 150})
    // A per-shelf column override lived here, forcing Liked and Top Tracks to one
    // column against their theme's two. Every list is one column now, so the
    // exception and the rule agree and geom() answers on its own.
    // THE ONE PLACE THE USER'S NUMBERS ARE APPLIED. Everything that lays
    // anything out reads geom() -- root.g and root.menuG both come through here
    // -- so the overrides are applied once, on the way out, and no view needs to
    // know a setting exists.
    //
    // Which override applies is decided by what the entry IS, not by its name: a
    // grid takes the grid counts, a list takes the row count, and the one-line
    // overlay themes (art, imp, listen) take neither -- handing a picture card
    // fourteen rows would size it as a menu. Width is capped for all of them,
    // including a details sheet, which is the ceiling that lets a long URL have
    // the room it needs on a wide screen.
    // THE WIDTH SETTING GIVES ROOM, it does not only take it away. Capping every
    // theme at the setting made it a one-way valve: the full-size views are
    // 1000px, so asking for 1300 changed nothing at all, while ten columns went
    // on dividing the same 1000 and drew 83px covers. Raising the width is
    // exactly what someone does to stop that happening.
    //
    // So a view that wants the full width takes the setting, and the deliberately
    // narrow ones -- a picker at 700, the keybinds sheet at 680 -- keep their own
    // width and are only capped by it. `base` is the width the full-size views
    // share, which is what makes "full-size" a fact about the entry rather than
    // a list of names kept somewhere else.
    readonly property int baseWidth: 1000
    function widthFor(w) {
        var want = cfgVal("maxWidth", baseWidth)
        return w >= baseWidth ? want : Math.min(w, want)
    }

    function geom(name) {
        var g = (name ? viewGeom[name] : null) || mainGeom
        var out = {width: widthFor(g.width),
                   columns: g.columns, lines: g.lines, icon: g.icon,
                   center: g.center, rowSize: g.rowSize, rowWeight: g.rowWeight}
        if (g.columns > 1) {
            out.columns = cfgVal("gridCols", g.columns)
            out.lines   = cfgVal("gridRows", g.lines)
        } else if (g.lines > 1) {
            out.lines   = cfgVal("listLines", g.lines)
        }
        return out
    }

    // --- the grid (main.rasi, thumbs.rasi) -----------------------------------
    // gridColumns and gridRows lived here and were read by nothing: the count a
    // view actually uses comes from viewGeom, keyed by its theme. Two answers to
    // one question, and the unused one was free to be wrong.
    readonly property int  tileIcon:     150    // element-icon size: 150px
    readonly property int  tileSpacing:  4
    readonly property int  tilePadding:  8
    readonly property int  tileBorder:   2      // element selected border: 2px
    // THE SAME CURVE AS THE WINDOW, deliberately unlike ZENON: main.rasi and
    // thumbs.rasi both round the selected tile at 5px against the window's 10,
    // so the selection was a slightly different shape from the panel holding it.
    // Derived rather than restated, so the two cannot drift apart again.
    readonly property int  tileRadius:   radius
    // THE ARTWORK'S OWN CORNER, which is not the selection's. A cover sat square
    // inside a 10px outline, so the highlight curved around four right angles
    // and the wall of tiles read as sharper than everything else in the app.
    // Small on purpose: a cover is a picture of a printed thing, and rounding it
    // as far as a panel would make it a button.
    readonly property int  tileArtRadius: 4
    readonly property color tileSelected: "#6a707f"

    // The caption strip under a tile, and the cell that results. Derived ONCE:
    // the panel sizes itself from this and the grid lays out from it, and when
    // the two carried their own copies of the arithmetic a tile height could be
    // changed in one place and silently disagree in the other.
    readonly property int tileCaption: 20
    // NO LONGER A CONSTANT, because the column count is a setting. 150px was
    // right while a grid was always five across a 1000px panel; ask for ten
    // columns and each cell has 100px, so a 150px cover overflows its own cell
    // and the wall of them runs off both edges of the window.
    //
    // Still derived ONCE, which is what the note above was about: the panel
    // sizes itself from these and the grid lays out from them, so they are
    // functions here rather than arithmetic copied into both.
    function tileIconFor(cellW) {
        return Math.max(48, Math.min(tileIcon, cellW - tilePadding * 2))
    }
    function cellHeightFor(cellW) {
        return tileIconFor(cellW) + tileSpacing + tileCaption + tilePadding * 2
    }

    // Qt wants a URL; the engine deals in filesystem paths. One conversion, so
    // no caller has to remember the scheme -- and an empty path stays empty
    // rather than becoming a broken "file://".
    // The now-playing strip and the progress rule beneath it. Present in every
    // menu, so their height is part of the panel's, not something a view opts in
    // to.
    // 24 for the line itself plus 4 above and below, so the track sits clear of
    // both the separator above it and the window edge below.
    //
    // `progressHeight` and `progressRowHeight` stood here describing a separate
    // progress strip under the track line. There is no such strip: the played
    // portion is a fill drawn BEHIND the line (see `played`), which is why it
    // takes the bar's own height and neither number was ever read.
    readonly property int nowBarHeight: 40

    function fileUrl(path) { return (path && path.length) ? "file://" + path : "" }
    // One of the palette's colours at a given alpha. QML has Qt.lighter and
    // Qt.darker and nothing for this, so every gradient stop was spelling out
    // Qt.rgba(c.r, c.g, c.b, a) in full.
    function fade(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
}
