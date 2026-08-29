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
    property bool playing: false
    property string repeatMode: "off"
    // THE TITLE IS A CONTROL, like the one in the message bar above it. Reported
    // rather than acted on: this file draws a line, it does not know what a track
    // action menu is.
    signal titleClicked()
    // A transport control on the strip was pressed. Reported, not acted on: this
    // file draws a line.
    signal controlRequested(string action)

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
        anchors { right: title.left; rightMargin: 14
                  verticalCenter: parent.verticalCenter }
        spacing: 0
        // THREE CONTROLS, NOT THREE LABELS. Shuffle and repeat were readouts you
        // could only change from a menu, and the play glyph was a character
        // inside the title string -- so the one bar that is permanently on screen
        // and permanently about playback could not be used to drive it. They are
        // the same GlyphKey the dock's transport is built from, so hovering one
        // looks the same in both places.
        GlyphKey {
            theme: content.theme
            glyph: content.repeatMode === "track" ? content.theme.glyphRepeatTrack
                 : content.repeatMode === "context" ? content.theme.glyphRepeatAll
                 : content.theme.glyphRepeatOff
            // Repeat-one keeps its peach: that one is not a brighter version of
            // the same state, it is a different mode.
            glowCol: content.repeatMode === "track" ? content.theme.notice : content.fg
            lit: content.repeatMode !== "off"
            onTapped: content.controlRequested("repeat")
        }
        GlyphKey {
            theme: content.theme
            glyph: content.shuffle ? content.theme.glyphShuffleOn
                                   : content.theme.glyphShuffleOff
            glowCol: content.fg
            lit: content.shuffle
            onTapped: content.controlRequested("shuffle")
        }
        // ...AND THE TRANSPORT GLYPH, which used to be the first character of the
        // title string -- so it moved with the track name, could not be pressed,
        // and elided away on a long one.
        GlyphKey {
            theme: content.theme
            glyph: content.playing ? content.theme.glyphPause : content.theme.glyphPlay
            glowCol: content.fg
            onTapped: content.controlRequested("playpause")
        }
    }
    Text {
        id: elapsedClock
        anchors { left: parent.left; leftMargin: content.theme.messagePadH
                  verticalCenter: parent.verticalCenter }
        text: content.elapsed
        color: content.fg
        font.family: content.theme.fontFamily
        font.pointSize: content.theme.fontSize - 3
        font.bold: true
    }
    Text {
        id: totalClock
        anchors { right: parent.right; rightMargin: content.theme.messagePadH
                  verticalCenter: parent.verticalCenter }
        text: content.total
        color: content.fg
        font.family: content.theme.fontFamily
        font.pointSize: content.theme.fontSize - 3
        font.bold: true
    }
    // Title and its status marks as ONE centered line. A single Text rather than
    // a Row of two: the marks belong to the title, so they travel with it and
    // stay put as the fill sweeps past underneath.
    Text {
        id: title
        anchors { horizontalCenter: parent.horizontalCenter
                  verticalCenter: parent.verticalCenter }
        // BOUNDED BY WHAT IS ACTUALLY BESIDE IT, not by a guess. This was six
        // pad-widths of margin, which had nothing to do with the things it was
        // supposed to clear: the transport modes hang off this title's left
        // edge, so a long track name pushed them leftwards until they sat on top
        // of the elapsed clock.
        //
        // The title is centered, so what it may occupy is twice the smaller of
        // the two half-widths -- the left one has to hold the clock AND the modes
        // group, the right one only the total. `sideRoom` is that, and the title
        // elides into it.
        readonly property real sideRoom: Math.min(
            content.width / 2 - (elapsedClock.width + modes.width
                                 + content.theme.messagePadH + 10 + 8),
            content.width / 2 - (totalClock.width + content.theme.messagePadH + 8))
        width: Math.min(implicitWidth, Math.max(60, sideRoom * 2))
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

        // ON THE TITLE ALONE, not on the strip. The clocks either side of it are
        // about time and the strip itself is about to grow a wheel gesture of its
        // own; the name of the track is the part that is ABOUT the track.
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: content.titleClicked()
        }
    }
    // A COPY MARK STOOD HERE, beside the playing track. Its only trigger was
    // Alt+g copying that track's link, and Alt+g now opens a pasted one instead
    // -- so it could never appear again. Copying from an action menu still gets
    // its receipt, on the row you picked: see RowList's copiedSrc, which says
    // WHICH thing was copied rather than assuming it was whatever is playing.
}
