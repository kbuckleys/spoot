// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// A two-column sheet of label/value pairs, laid out rather than padded.
//
// One renderer for every sheet in the app: the keybind reference and the
// Track/Album/Podcast/Episode detail sheets are all the same shape -- a short
// right-aligned label and a value beside it -- and they were all built as
// space-padded strings because rofi could only be handed text.
//
// rofi took one blob of text, so the engine used to hand it a string with the
// key column faked by counting spaces to column 15. Nothing lined up unless the
// font was monospaced, nothing could wrap, and the window height was a guess --
// which is why the last binding was cut off the bottom.
//
// Here the key column measures itself against the widest key, the description
// column takes the rest, and the sheet is exactly as tall as its rows.
import QtQuick

Column {
    id: sheet
    property var theme
    property var rows: []
    // The label colour belongs to the sheet KIND: the keybind reference marks
    // its keys, a detail sheet marks its field names, and ZENON gives those two
    // different colours.
    property color labelColor: theme.keyCap
    // Details carry values that can run long (a Spotify URL); a keybind
    // description never does.
    property bool wrapValues: false
    spacing: 2

    // --- AUTOFIT ------------------------------------------------------------
    //
    // The sheet measures itself and the window takes its size, instead of the
    // window being a number in a theme file and the text living with whatever it
    // got. rofi could not do this: it is handed a size up front, which is why
    // meta.rasi says 800px whether the sheet holds three fields or twelve.
    //
    // Everything below is measured with the SAME TextMetrics the delegates draw
    // with, so the numbers cannot disagree with the layout.

    // The gutter between the label column and the value column. Wide on purpose:
    // this is a definition list, and 14px read as two columns jammed together
    // rather than as a label and the thing it labels.
    readonly property int colGap: 48
    // A ceiling for the value column, past which a long value wraps rather than
    // pushing the window wider than the screen. A Spotify URL is the case that
    // needs it, and this cap has now been too tight for it twice: 640 wrapped an
    // album URL, and 900 still wrapped a track one, which is 53 characters and
    // lands just past it at this size.
    //
    // The number is deliberately generous rather than fitted to that URL. This
    // is not the thing that should be deciding how wide a sheet gets -- the
    // panel's own clamp is, and it now has two reasons to bite before this does:
    // the screen, and the user's maximum width. A cap that only catches the
    // pathological case is a cap that stops surprising people.
    property int maxValueWidth: 1400

    readonly property int valueWidth: {
        var w = 0
        for (var i = 0; i < rows.length; i++) {
            metrics.text = rows[i].desc || ""
            w = Math.max(w, metrics.width)
        }
        return Math.ceil(Math.min(w, maxValueWidth))
    }

    // What the window should be: both columns and the gap between them.
    readonly property int naturalWidth: keyWidth + colGap + valueWidth

    // Exact, wrapped rows included. Column.implicitHeight only counts delegates
    // the Repeater has actually built, so binding a window size to it produced a
    // sheet tall enough for eleven of twenty rows; TextMetrics knows the line
    // height for this font before a single delegate exists.
    readonly property int contentHeight: {
        var lineH = Math.ceil(metrics.height)
        var h = 0
        for (var i = 0; i < rows.length; i++) {
            var n = 1
            if (wrapValues && valueWidth > 0) {
                metrics.text = rows[i].desc || ""
                n = Math.max(1, Math.ceil(metrics.width / valueWidth))
            }
            h += n * lineH + spacing
        }
        return h
    }

    // The key column is as wide as the widest key, so both columns are flush
    // without anyone counting characters.
    //
    // TWO measuring sticks, not one. Both this and valueWidth assign to their
    // TextMetrics before reading it, so sharing a single instance made each
    // binding invalidate the other -- whichever ran last left its text behind,
    // and the key column came out as wide as the longest DESCRIPTION. That is
    // the 250px of dead space the sheet opened with.
    property int keyWidth: {
        var w = 0
        for (var i = 0; i < rows.length; i++) {
            var k = rows[i].key
            if (!k) continue
            keyMetrics.text = k
            w = Math.max(w, keyMetrics.width)
        }
        return Math.ceil(w)
    }
    TextMetrics {
        id: keyMetrics
        font.family: sheet.theme.fontFamily
        font.pointSize: sheet.theme.sheetFontSize
        font.weight: sheet.theme.sheetFontWeight
    }
    TextMetrics {
        id: metrics          // values, and the line height every row shares
        font.family: sheet.theme.fontFamily
        font.pointSize: sheet.theme.sheetFontSize
        font.weight: sheet.theme.sheetFontWeight
    }

    Repeater {
        model: sheet.rows
        delegate: Row {
            spacing: sheet.colGap
            Text {
                width: sheet.keyWidth
                horizontalAlignment: Text.AlignRight
                text: modelData.key || ""
                // ZENON's key colour, straight from the sheet this replaces.
                color: sheet.labelColor
                font.family: sheet.theme.fontFamily
                font.pointSize: sheet.theme.sheetFontSize
                font.weight: sheet.theme.sheetFontWeight
            }
            Text {
                text: modelData.desc || ""
                // Bounded so a long value wraps inside the sheet instead of
                // running off the edge of the window.
                width: sheet.wrapValues ? Math.min(implicitWidth, sheet.valueWidth)
                                        : implicitWidth
                wrapMode: sheet.wrapValues ? Text.WrapAnywhere : Text.NoWrap
                // A row with no label is a note about the one above it, so it
                // reads dimmer and sits in the value column with it.
                color: modelData.key ? sheet.theme.foreground : sheet.theme.dim
                font.family: sheet.theme.fontFamily
                font.pointSize: sheet.theme.sheetFontSize
                font.weight: sheet.theme.sheetFontWeight
            }
        }
    }
}
