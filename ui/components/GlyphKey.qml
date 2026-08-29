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

    // IT GLOWS RATHER THAN FILLS. A solid plate under the glyph is a button on a
    // bar that has no other buttons on it; the light is the same green the glyph
    // is already drawn in, spread behind it -- so hovering brightens the control
    // rather than putting a box round it.
    Rectangle {
        anchors.centerIn: parent
        width: key.side; height: key.side
        radius: width / 2
        gradient: Gradient {
            GradientStop { position: 0.0; color: key.theme.fade(key.glowCol, 0.30) }
            GradientStop { position: 0.6; color: key.theme.fade(key.glowCol, 0.10) }
            GradientStop { position: 1.0; color: key.theme.fade(key.glowCol, 0.0) }
        }
        opacity: hover.containsMouse ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    }
    // What colour this control is. Almost always the theme's green; repeat-one
    // keeps its peach, because that is a different mode rather than a brighter
    // version of the same one.
    property color glowCol: key.theme.playing
    Text {
        anchors.centerIn: parent
        text: key.glyph
        color: key.glowCol
        // Lit, unlit, and a third step for the one under the pointer: the same
        // green turned up, not a different colour.
        opacity: hover.containsMouse ? 1 : (key.lit ? 1 : 0.3)
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
}
