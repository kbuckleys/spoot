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
    // THE LEFT COLUMN AS KEYCAPS. A keybind reference is a table of keys, and a
    // key drawn as bare coloured text is indistinguishable from the description
    // beside it -- you read the sheet twice to work out where one column ends.
    // A grey rounded pill is what every keyboard-shortcut table on the web does,
    // and for the same reason: it says "this is a thing you press".
    //
    // Off for the detail sheets, whose left column is a field NAME -- "Album",
    // "Released" -- and a pill around one of those reads as a button.
    property bool capsuleKeys: false
    // The pill's own padding and corner. Kept here rather than in the theme
    // because they are proportions of this one shape, not tokens anything else
    // shares -- the theme owns the colour.
    readonly property int capPadH: 7
    readonly property int capPadV: 2
    readonly property int capRadius: 4
    spacing: capsuleKeys ? 4 : 2

    // --- AUTOFIT ------------------------------------------------------------
    //
    // The sheet measures itself and the window takes its size, instead of the
    // window being a number in a theme file and the text living with whatever it
    // got. rofi could not do this: it is handed a size up front, which is why
    // meta.rasi says 800px whether the sheet holds three fields or twelve.
    //
    // Everything below is measured with the SAME font the delegates draw with,
    // so the numbers cannot disagree with the layout.

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

    // MEASURED WITH A FUNCTION, NOT BY MOVING A PROPERTY.
    //
    // All three of these used to assign to a TextMetrics and then read its
    // `width` back -- which is a binding that writes what it depends on. Qt calls
    // that a binding loop and says so, hundreds of times, every time a sheet
    // opens; the widths converged only because the last assignment happened to be
    // the one that mattered, and a binding Qt decides to abandon leaves the sheet
    // whatever size it was when the loop was cut.
    //
    // FontMetrics.advanceWidth is the same measurement as a CALL: no property to
    // invalidate, so no loop, and one instance can serve every reader -- which
    // also retires the "two measuring sticks" the loop forced on the key column.
    // Same font as the delegates draw with, so the numbers still cannot disagree
    // with the layout.
    readonly property int valueWidth: {
        var w = 0
        for (var i = 0; i < rows.length; i++) {
            w = Math.max(w, metrics.advanceWidth(rows[i].desc || ""))
        }
        return Math.ceil(Math.min(w, maxValueWidth))
    }

    // What the window should be: both columns and the gap between them. The pill
    // is part of the key column's width -- measured from the same number the
    // delegate draws with, so the two cannot disagree.
    readonly property int naturalWidth: keyWidth + colGap + valueWidth

    // Exact, wrapped rows included. Column.implicitHeight only counts delegates
    // the Repeater has actually built, so binding a window size to it produced a
    // sheet tall enough for eleven of twenty rows; the font metrics know the
    // line height before a single delegate exists.
    readonly property int contentHeight: {
        var lineH = Math.ceil(metrics.height) + (capsuleKeys ? capPadV * 2 : 0)
        var h = 0
        for (var i = 0; i < rows.length; i++) {
            var n = 1
            if (wrapValues && valueWidth > 0) {
                n = Math.max(1, Math.ceil(metrics.advanceWidth(rows[i].desc || "")
                                          / valueWidth))
            }
            h += n * lineH + spacing
        }
        return h
    }

    // The key column is as wide as the widest key, so both columns are flush
    // without anyone counting characters.
    //
    // ONE measuring stick now. Two were needed only while these were TextMetrics
    // instances being written to mid-binding: each assignment invalidated the
    // other's read, so a shared one had the key column come out as wide as the
    // longest DESCRIPTION -- the 250px of dead space the sheet opened with. A
    // function cannot do that to anyone. See valueWidth.
    readonly property int keyWidth: {
        var w = 0
        for (var i = 0; i < rows.length; i++) {
            var k = rows[i].key
            if (!k) continue
            w = Math.max(w, metrics.advanceWidth(k))
        }
        return Math.ceil(w) + (capsuleKeys ? capPadH * 2 : 0)
    }
    FontMetrics {
        id: metrics          // both columns, and the line height every row shares
        font.family: sheet.theme.fontFamily
        font.pointSize: sheet.theme.sheetFontSize
        font.weight: sheet.theme.sheetFontWeight
    }

    Repeater {
        model: sheet.rows
        delegate: Row {
            id: pair
            spacing: sheet.colGap
            // The whole row is as tall as the pill, so the description sits on the
            // keycap's centre line rather than on the text's.
            readonly property int lineH: Math.ceil(keyText.implicitHeight)
                                       + (sheet.capsuleKeys ? sheet.capPadV * 2 : 0)
            // THE KEY COLUMN, right-aligned. An Item of the full column width with
            // the cap anchored to its right edge: the cap hugs its own text, and
            // the column still ends flush for every row -- which is what makes the
            // descriptions line up.
            Item {
                width: sheet.keyWidth
                height: pair.lineH
                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: keyText.implicitWidth + sheet.capPadH * 2
                    height: keyText.implicitHeight + sheet.capPadV * 2
                    radius: sheet.capRadius
                    visible: sheet.capsuleKeys && (modelData.key || "").length > 0
                    color: sheet.theme.keyCapBg
                    border.width: 1
                    border.color: sheet.theme.keyCapEdge
                }
                Text {
                    id: keyText
                    anchors.right: parent.right
                    anchors.rightMargin: sheet.capsuleKeys ? sheet.capPadH : 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.key || ""
                    // ZENON's key colour, straight from the sheet this replaces.
                    color: sheet.labelColor
                    font.family: sheet.theme.fontFamily
                    font.pointSize: sheet.theme.sheetFontSize
                    font.weight: sheet.theme.sheetFontWeight
                }
            }
            Text {
                text: modelData.desc || ""
                height: pair.lineH
                verticalAlignment: Text.AlignVCenter
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
