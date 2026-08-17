// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// The now-playing line's CONTENT: the elapsed clock, the track, the total. Its
// own file because the strip is composited -- the progress fill is a ground
// painted behind exactly this, so the line's layout has to be independent of
// how far along the track is.
import QtQuick

Item {
    id: content
    property var theme
    property color fg
    property string track: ""
    property string icons: ""
    property string elapsed: ""
    property string total: ""
    // Raised for a moment after Alt+g. See the mark below.
    property bool shuffle: false
    property string repeatMode: "off"

    // Left and right are the clock; the middle is the track. All three stay the
    // same green whatever the fill is doing behind them.
    // SHUFFLE AND REPEAT, beside the transport glyph they belong with. Anchored
    // to the title rather than to the panel, so the three move together as one
    // group of controls instead of the pair sitting off at the far edge.
    //
    // OFF IS FADED, NOT GREY. Same green as everything else on this line, turned
    // down: a dim state should read as the same control unlit, not as a
    // different colour that happens to mean something. Opacity rather than a
    // second colour, so there is one green here and one place to change it.
    Row {
        id: modes
        anchors { right: title.left; rightMargin: 10
                  verticalCenter: parent.verticalCenter }
        spacing: 6
        Text {
            text: content.repeatMode === "track" ? content.theme.glyphRepeatTrack
                : content.repeatMode === "context" ? content.theme.glyphRepeatAll
                : content.theme.glyphRepeatOff
            // Repeat-one keeps its peach: that one is not a brighter version of
            // the same state, it is a different mode.
            color: content.repeatMode === "track" ? content.theme.notice : content.fg
            opacity: content.repeatMode === "off" ? 0.3 : 1
            Behavior on opacity { NumberAnimation { duration: 140 } }
            Behavior on color { ColorAnimation { duration: 140 } }
            font.family: content.theme.fontFamily
            font.pointSize: content.theme.fontSize - 2
            font.bold: true
        }
        Text {
            text: content.shuffle ? content.theme.glyphShuffleOn
                                  : content.theme.glyphShuffleOff
            color: content.fg
            opacity: content.shuffle ? 1 : 0.3
            Behavior on opacity { NumberAnimation { duration: 140 } }
            font.family: content.theme.fontFamily
            font.pointSize: content.theme.fontSize - 2
            font.bold: true
        }
    }
    Text {
        anchors { left: parent.left; leftMargin: content.theme.messagePadH
                  verticalCenter: parent.verticalCenter }
        text: content.elapsed
        color: content.fg
        font.family: content.theme.fontFamily
        font.pointSize: content.theme.fontSize - 3
        font.bold: true
    }
    Text {
        anchors { right: parent.right; rightMargin: content.theme.messagePadH
                  verticalCenter: parent.verticalCenter }
        text: content.total
        color: content.fg
        font.family: content.theme.fontFamily
        font.pointSize: content.theme.fontSize - 3
        font.bold: true
    }
    // Title and its status marks as ONE centred line. A single Text rather than
    // a Row of two: the marks belong to the title, so they travel with it and
    // stay put as the fill sweeps past underneath.
    Text {
        id: title
        anchors { horizontalCenter: parent.horizontalCenter
                  verticalCenter: parent.verticalCenter }
        // Bounded so a long title cannot run under the clock at either end.
        width: Math.min(implicitWidth, content.width - content.theme.messagePadH * 6)
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        // Liked, explicit and lyrics exactly as Util.status_icons built them --
        // never re-derived here.
        text: content.track + (content.icons.length ? "  " + content.icons : "")
        color: content.fg
        font.family: content.theme.fontFamily
        // A step under the message bar it sits opposite: same family, same
        // weight, just enough smaller to read as the second line of the pair.
        font.pointSize: content.theme.fontSize - 1
        font.bold: true
    }
    // A COPY MARK STOOD HERE, beside the playing track. Its only trigger was
    // Alt+g copying that track's link, and Alt+g now opens a pasted one instead
    // -- so it could never appear again. Copying from an action menu still gets
    // its receipt, on the row you picked: see RowList's copiedSrc, which says
    // WHICH thing was copied rather than assuming it was whatever is playing.
}
