// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// One glyph you can press. The dock's transport is seven of these and the
// now-playing strip's shuffle, repeat and play/pause are three more -- they must
// not each carry their own idea of how big a button is or what hovering one
// looks like.
//
// OFF IS FADED, NOT GREY: a dim state reads as the same control unlit, not as a
// different colour that happens to mean something. That rule was the strip's
// first and the dock took it; this is where it lives now.
//
// SQUARE, ALWAYS. `big` changes the glyph's size and nothing else -- it used to
// widen the item too, so the play button had six more pixels of padding than the
// two beside it and the transport group sat visibly off-centre.
import QtQuick

Item {
    id: key
    property var theme
    property string glyph: ""
    property bool lit: true
    property bool big: false
    signal tapped()

    // One number for both axes, so the padding around every glyph is the same
    // however wide the glyph itself draws.
    property int side: 26
    width: side
    height: side
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

    // A PLATE, AND IT IS A ROUNDED SQUARE. This was a radial gradient in a circle,
    // and a circle is the one shape that cannot be aligned to a row of glyphs
    // whose ink is not itself round: a play triangle sits right of its own centre
    // and a shuffle glyph is wider than it is tall, so the ring around each one
    // landed somewhere different and the three read as a row of misaligned
    // bubbles. A rounded square is the SAME shape at every key, fills the item
    // exactly, and shares its corner with every other floating thing in spoot.
    //
    // (The other half of that misalignment was the glyph, not the plate -- see
    // `ink` below.)
    //
    // DARKER ON THE WAY DOWN. Hover lifts a faint wash of the control's own
    // colour; a press takes the plate to black instead of brightening it further,
    // which is the one direction that reads as a button being depressed on a
    // ground this dark. Both are the plate, so the glyph on top never moves.
    Rectangle {
        anchors.fill: parent
        radius: Math.round(key.side * 0.3)
        color: hover.pressed ? Qt.rgba(0, 0, 0, 0.40)
                             : key.theme.fade(key.glowCol, 0.16)
        opacity: (hover.containsMouse || hover.pressed) ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 90 } }
    }
    // What colour this control is. Almost always the theme's green; repeat-one
    // keeps its peach, because that is a different mode rather than a brighter
    // version of the same one.
    property color glowCol: key.theme.playing
    // THE INK, NOT THE STRING AROUND IT. theme.glyphPlay and glyphPause carry a
    // trailing space, because in a LIST they prefix a row's text and the gap is
    // part of the marker -- so a key built from one laid out a box a space wider
    // than the glyph and then centred THAT, putting the triangle visibly left of
    // the plate it sits on. Every caller had to remember to trim, and neither
    // did; trimmed here, no caller has to.
    readonly property string ink: key.glyph.trim()
    Text {
        // FILL AND ALIGN, not centerIn. centerIn centres the text's own layout
        // box, which is as tall as the font's line height whatever the glyph
        // does with it; filling the key and aligning inside it measures against
        // the plate, which is the thing the eye is comparing the glyph to.
        anchors.fill: parent
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: key.ink
        color: key.glowCol
        // Lit, unlit, and a third step for the one under the pointer: the same
        // green turned up, not a different colour.
        opacity: hover.containsMouse ? 1 : (key.lit ? 1 : key.theme.glyphDim)
        Behavior on opacity { NumberAnimation { duration: 140 } }
        Behavior on color { ColorAnimation { duration: 140 } }
        font.family: key.theme.fontFamily
        font.bold: true
        font.pointSize: key.theme.fontSize + (key.big ? 2 : 0)
    }
    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: key.tapped()
    }
    // A KEY WITH NOTHING ON IT IS NOT A KEY. `visible` is the caller's to set
    // (the dock hides the heart with nothing playing, and a Row then skips it
    // outright rather than leaving a hole) -- this is the narrower case of a
    // glyph that resolved to nothing at all, where the plate would still light
    // under the pointer with no mark to explain it.
    enabled: key.ink.length > 0
}
