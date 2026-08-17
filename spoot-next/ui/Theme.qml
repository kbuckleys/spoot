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
    readonly property color ground:      "#CC000000"   // background: rgba(0,0,0,0.8)
    readonly property color foreground:  "#DFDFDD"
    readonly property color selectedBg:  Qt.rgba(69/255, 80/255, 92/255, 0.3)
    readonly property color messageBg:   Qt.rgba(40/255, 47/255, 54/255, 0.4)
    readonly property color borderCol:   Qt.rgba(155/255, 191/255, 191/255, 0.2)
    readonly property color separator:   Qt.rgba(69/255, 80/255, 92/255, 0.3)
    readonly property color blue:        "#9BBFBF"
    readonly property color red:         "#e78284"
    readonly property color urgent:      "#e78284"

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
    // The key colour from the keybind sheet's own markup, and the field-name
    // colour from Util.detail_sheet's.
    readonly property color keyCap:      "#eebebe"
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
    readonly property int    sheetPad: 20
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
    readonly property string glyphShuffleOn:   "\u{F074}"
    readonly property string glyphShuffleOff:  "\u{F049D}"
    // No statusOff colour: an unlit control is the same green turned down, not
    // a grey that happens to mean the same thing. See NowContent.

    // --- window (ZENON `window`, main.rasi `window`) -------------------------
    readonly property int  radius:      10      // border-radius: 10px 10px 0 0
    readonly property int  borderWidth: 1
    readonly property int  mainWidth:   1000    // main.rasi width: 1000px

    // --- message bar (ZENON `message`) --------------------------------------
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
    // textbox-prompt-colon padding: 6px 10px 6px 20px -- the glyph sits well in
    // from the edge, close to what you type.
    readonly property int promptPadL: 20
    readonly property int promptPadR: 10
    // entry padding: 6px on every side.
    readonly property int entryPad: 6

    // --- rows (ZENON `element`) ---------------------------------------------
    readonly property int rowPadV: 2
    readonly property int rowPadH: 20
    // A text row's total height, and how many a list shows before it scrolls --
    // the panel keeps one height whichever view is on it.
    readonly property int rowHeight: 26
    readonly property int listRows: 12

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
        "album":     {width: 1000, columns: 1, lines: 13, icon: 364},
        "action":    {width: 1000, columns: 1, lines: 13, icon: 364, center: true},
        // CENTRED. These are menus of choices rather than shelves of content:
        // a handful of verbs or settings, read as a group. A shelf of hundreds
        // of tracks stays left-aligned, because a ragged left edge is what makes
        // a long list unscannable.
        "sub":       {width: 700,  columns: 1, lines: 11, center: true},
        "search":    {width: 700,  columns: 1, lines: 6,  center: true},
        "searchall": {width: 1000, columns: 1, lines: 14},
        "trail":     {width: 900,  columns: 1, lines: 14, center: true},
        // Lyrics are READ, not scanned, so they are the one list that centres its
        // rows and sets its own type. Both come from lyrics.rasi -- `element-text
        // { horizontal-align: 0.5 }` and a 14pt face, neither of which survived
        // transcription. Only the weight is a departure: Medium there, SemiBold
        // here.
        "lyrics":    {width: 1000, columns: 1, lines: 14,
                      center: true, rowSize: 14, rowWeight: Font.DemiBold},
        "pods":      {width: 1000, columns: 1, lines: 13},
        "meta":      {width: 800,  columns: 1, lines: 13},
        "binds":     {width: 680,  columns: 1, lines: 13},
        "message":   {width: 700,  columns: 1, lines: 13},
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
    function geom(name) {
        var g = name ? viewGeom[name] : null
        return g ? g : mainGeom
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
    readonly property color tileSelected: "#6a707f"

    // The caption strip under a tile, and the cell that results. Derived ONCE:
    // the panel sizes itself from this and the grid lays out from it, and when
    // the two carried their own copies of the arithmetic a tile height could be
    // changed in one place and silently disagree in the other.
    readonly property int tileCaption: 20
    readonly property int cellHeight: tileIcon + tileSpacing + tileCaption + tilePadding * 2

    // Qt wants a URL; the engine deals in filesystem paths. One conversion, so
    // no caller has to remember the scheme -- and an empty path stays empty
    // rather than becoming a broken "file://".
    // The now-playing strip and the progress rule beneath it. Present in every
    // menu, so their height is part of the panel's, not something a view opts in
    // to.
    // 24 for the line itself plus 4 above and below, so the track sits clear of
    // both the separator above it and the window edge below.
    readonly property int nowBarHeight: 32
    // Thick enough to read as a control rather than a hairline, and tall enough
    // to seat the elapsed/total times beside it.
    readonly property int progressHeight: 6
    readonly property int progressRowHeight: 18

    function fileUrl(path) { return (path && path.length) ? "file://" + path : "" }
    // One of the palette's colours at a given alpha. QML has Qt.lighter and
    // Qt.darker and nothing for this, so every gradient stop was spelling out
    // Qt.rgba(c.r, c.g, c.b, a) in full.
    function fade(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
}
