// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// SOMEWHERE TO TYPE: what you have written so far, a caret against its end, and
// a placeholder behind it while it is empty.
//
// Its own file because spoot asks for text in two places and they are the same
// widget: the search box, which lives in the header of the search card, and the
// prompts the engine raises for a name (New Playlist, Rename). They differ in
// three ways and no more -- a glyph, a placeholder, and whether the line is
// centred -- so those are properties rather than a second copy.
//
// The caret is a SIBLING of the text and the placeholder a sibling of the caret.
// The placeholder was written inside the caret once, and a child inherits its
// parent's opacity: it blinked along with the cursor, which is the one thing on
// a field that must not move.
import QtQuick

Item {
    id: field
    property var theme
    // What has been typed. Empty is the state the placeholder is for.
    property string text: ""
    // Shown while `text` is empty, in the border's colour -- the dimmest thing a
    // card draws, so it reads as the box describing itself rather than as text
    // somebody left there.
    property string placeholder: ""
    // The mark on the field. Absent for a prompt, which says what it wants on a
    // title bar instead.
    property string glyph: ""
    // Centred for a prompt asking a short question, left-aligned for a search
    // box: text that starts in the middle and grows outwards in both directions
    // is not somewhere you type -- the words move while you are still writing.
    property bool centered: false
    // Only while the field is actually up, or an invisible card goes on
    // animating.
    property bool blinking: true

    readonly property int caretW: 2
    implicitHeight: entry.implicitHeight

    Text {
        id: mark
        visible: field.glyph.length > 0
        x: field.theme.rowPadH
        anchors.verticalCenter: entry.verticalCenter
        text: field.glyph
        color: field.theme.playing
        font { family: field.theme.fontFamily; pointSize: field.theme.promptSize
               weight: Font.DemiBold }
    }
    Text {
        id: entry
        y: 0
        x: field.centered
           ? Math.round((field.width - width) / 2) - field.caretW
           : (field.glyph.length > 0
              ? mark.x + mark.width + field.theme.promptPadR
              : field.theme.rowPadH)
        width: Math.min(implicitWidth,
                        field.width - field.theme.rowPadH * 2 - field.caretW)
        text: field.text
        // GREEN, like the prompt glyph beside it and the caret after it. What you
        // are typing is the live thing on this line, and spoot's green is what it
        // uses everywhere else to say so.
        color: field.theme.playing
        elide: Text.ElideLeft
        font { family: field.theme.fontFamily; pointSize: field.theme.entrySize
               weight: Font.DemiBold }
    }
    Rectangle {
        id: caret
        anchors { left: entry.right; leftMargin: 2
                  verticalCenter: entry.verticalCenter }
        width: field.caretW
        height: entry.implicitHeight - 2
        color: field.theme.playing
        SequentialAnimation on opacity {
            loops: Animation.Infinite
            running: field.blinking
            NumberAnimation { from: 1; to: 0; duration: 500
                              easing.type: Easing.InOutQuad }
            NumberAnimation { from: 0; to: 1; duration: 500
                              easing.type: Easing.InOutQuad }
        }
    }
    Text {
        visible: field.placeholder.length > 0 && field.text.length === 0
        anchors { left: caret.right; leftMargin: field.theme.promptPadR
                  verticalCenter: caret.verticalCenter }
        text: field.placeholder
        color: field.theme.borderCol
        font { family: field.theme.fontFamily; pointSize: field.theme.entrySize
               weight: Font.DemiBold }
    }
}
