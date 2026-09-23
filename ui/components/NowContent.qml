// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// The now-playing line's CONTENT: the elapsed clock, the track, the total. Its
// own file because the strip is composited -- the progress line is drawn along
// the bar's own top edge behind exactly this, so the line's layout has to be
// independent of how far along the track is.
import QtQuick
import QtQuick.Effects

Item {
    id: content
    property var theme
    property color fg
    property string track: ""
    property string elapsed: ""
    property string total: ""
    // Raised for a moment after Alt+g. See the mark below.
    property bool shuffle: false
    property bool playing: false
    property string repeatMode: "off"
    // THE THREE STATUS MARKS, AS FACTS RATHER THAN AS A FINISHED STRING.
    //
    // These rode on the title as `icons` -- one string the engine composed with
    // Util.status_icons, appended to the track name and drawn as part of it. That
    // is still what a list row and the dock wear, and it is right there: a row is
    // text. It is wrong HERE, for two reasons that turned out to be the same one.
    //
    // A glyph inside the title is not a control, so the heart could not be
    // pressed to save the track and the lyrics mark could not be pressed to read
    // them -- on the one line in spoot that is permanently about the playing
    // track. And a glyph inside the title ELIDES WITH IT: a long name pushed the
    // marks off the end and then ran under them, so the one thing the marks say
    // was said on top of the letters of the name.
    //
    // Split out, each is an item that can be pressed, coloured and measured --
    // and the title is bounded by what they actually occupy rather than by a
    // guess. See Util.serve_playback, which sends all three.
    property bool liked: false
    property bool explicit: false
    // "none" / "plain" / "synced" -- three states, so a word rather than two
    // booleans. The engine names the state and this picks the glyph, the same
    // split `repeatMode` above uses.
    property string lyrics: "none"
    readonly property bool hasTrack: content.track.length > 0

    // THE TITLE IS A CONTROL, like the one in the message bar above it. Reported
    // rather than acted on: this file draws a line, it does not know what a track
    // action menu is.
    signal titleClicked()
    // A transport control on the strip was pressed. Reported, not acted on: this
    // file draws a line.
    signal controlRequested(string action)
    // ...and the lyrics mark, which is not a control: it is a PLACE, so it does
    // not go through controlRequested with the other three.
    signal lyricsRequested()

    // Left and right are the clock; everything between them is one centred group.
    Text {
        id: elapsedClock
        // CLOSER IN THAN THE MESSAGE BAR'S OWN PADDING. messagePadH is the inset
        // for a caption CENTRED in the bar, and these two are pinned to the ends
        // of it -- at 30 they sat well short of the corners with nothing between,
        // which reads as the line being narrower than the bar it is in. rowPadH is
        // what the rows below are inset by, so the clocks line up with the list.
        anchors { left: parent.left; leftMargin: content.theme.rowPadH
                  verticalCenter: parent.verticalCenter }
        text: content.elapsed
        color: content.fg
        font.family: content.theme.fontFamily
        font.pointSize: content.theme.fontSize - 3
        font.bold: true
    }
    Text {
        id: totalClock
        anchors { right: parent.right; rightMargin: content.theme.rowPadH
                  verticalCenter: parent.verticalCenter }
        text: content.total
        color: content.fg
        font.family: content.theme.fontFamily
        font.pointSize: content.theme.fontSize - 3
        font.bold: true
    }

    // ONE CENTRED ROW: the transport, the name, the marks.
    //
    // The three used to be placed against each other by hand -- the modes group
    // anchored to the title's left edge, the title centred with an offset of half
    // the modes' width to put the PAIR back in the middle, and the marks inside
    // the title string. Every one of those is a measurement of something else,
    // and the title's own width was a third expression trying to agree with both.
    // A Row measures itself.
    Row {
        id: centre
        anchors.horizontalCenter: parent.horizontalCenter
        height: parent.height
        spacing: 10

        // THREE CONTROLS, NOT THREE LABELS. Shuffle and repeat were readouts you
        // could only change from a menu, and the play glyph was a character
        // inside the title string -- so the one bar that is permanently on screen
        // and permanently about playback could not be used to drive it. They are
        // the same GlyphKey the dock's transport is built from, so hovering one
        // looks the same in both places.
        //
        // OFF IS FADED, NOT GREY. Same green as everything else on this line,
        // turned down: a dim state should read as the same control unlit, not as
        // a different colour that happens to mean something.
        Row {
            id: modes
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0
            GlyphKey {
                theme: content.theme
                glyph: content.repeatMode === "track" ? content.theme.glyphRepeatTrack
                     : content.repeatMode === "context" ? content.theme.glyphRepeatAll
                     : content.theme.glyphRepeatOff
                // Repeat-one keeps its peach: that one is not a brighter version
                // of the same state, it is a different mode.
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
            // ...AND THE TRANSPORT GLYPH, which used to be the first character of
            // the title string -- so it moved with the track name, could not be
            // pressed, and elided away on a long one.
            GlyphKey {
                theme: content.theme
                glyph: content.playing ? content.theme.glyphPause : content.theme.glyphPlay
                glowCol: content.fg
                onTapped: content.controlRequested("playpause")
            }
        }

        // THE NAME, AND IT DISSOLVES RATHER THAN ELIDING.
        //
        // An ellipsis is a character that says "there was more"; on a line this
        // short it reads as part of the title. The trail above it solved the same
        // problem years earlier and solved it better -- the line fades out at
        // whichever end runs past the bar -- so this is that, with the same
        // capture-mask-redraw shape (see crumbBar in main.qml, which carries the
        // note about why the mask threshold cannot be zero).
        Item {
            id: titleBox
            anchors.verticalCenter: parent.verticalCenter
            height: titleText.implicitHeight

            // WHAT IS ACTUALLY LEFT, measured rather than guessed. The row is
            // centred, so it has to clear the WIDER of the two clocks at both
            // ends -- and what the marks and the transport occupy is known, since
            // both are siblings in this row.
            readonly property real room: Math.max(40,
                content.width
                - 2 * (Math.max(elapsedClock.width, totalClock.width)
                       + content.theme.rowPadH + 12)
                - modes.width - marks.width - centre.spacing * 2)
            width: Math.min(titleText.implicitWidth, room)
            // Is there anything past the edge to dissolve INTO. With the title
            // fitting, the mask is flat white and this costs a texture and
            // nothing else.
            readonly property bool over: titleText.implicitWidth > width + 0.5
            // How wide the dissolve runs, as a fraction of the box: about two and
            // a half characters, so the last word fades rather than the line
            // ending in a soft cut.
            readonly property real fadeW:
                over && width > 0 ? Math.min(0.4, 26 / width) : 0

            // THE LINE, captured rather than drawn. hideSource keeps this out of
            // the scene; the MultiEffect below puts it back with the mask on.
            Item {
                id: titleTrack
                anchors.fill: parent
                Text {
                    id: titleText
                    // NOT CONSTRAINED. Giving a Text a width makes it report the
                    // constrained size as its implicit one, and both `room` and
                    // `over` above read implicitWidth -- so a width here would be
                    // a binding reading what it writes. It overhangs the box and
                    // the capture is what cuts it.
                    wrapMode: Text.NoWrap
                    text: content.track
                    color: content.fg
                    font.family: content.theme.fontFamily
                    // A step under the message bar it sits opposite: same family,
                    // same weight, just enough smaller to read as the second line
                    // of the pair.
                    font.pointSize: content.theme.fontSize - 1
                    font.bold: true
                }
            }
            ShaderEffectSource {
                id: titleShot
                anchors.fill: parent
                sourceItem: titleTrack
                hideSource: true
                live: true
                visible: false
            }
            MultiEffect {
                anchors.fill: parent
                source: titleShot
                maskEnabled: true
                maskSource: titleMaskShot
                // See crumbBar: at min 0 the ramp runs from -spread to 0 and every
                // alpha lands at full strength, so the mask does nothing at all.
                // At min 0.5 with spread 1 it is smoothstep(0, 1, a) -- the whole
                // alpha range, as a curve.
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1.0
                autoPaddingEnabled: false
            }
            // THE MASK: opaque until the last stretch, transparent at the edge --
            // and flat white whenever the name fits, so a short title is not
            // softened for no reason. Kept out of the scene by hideSource and NOT
            // by `visible: false`, which would stop it being rendered at all and
            // hand the effect an empty texture.
            Rectangle {
                id: titleMask
                width: Math.max(1, titleBox.width)
                height: Math.max(1, titleBox.height)
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "white" }
                    GradientStop { position: 1 - titleBox.fadeW; color: "white" }
                    GradientStop { position: 1.0
                                   color: titleBox.over ? Qt.rgba(1, 1, 1, 0) : "white" }
                }
            }
            ShaderEffectSource {
                id: titleMaskShot
                sourceItem: titleMask
                width: Math.max(1, titleBox.width)
                height: Math.max(1, titleBox.height)
                hideSource: true
                live: true
                visible: false
            }
            // ON THE TITLE ALONE, not on the strip. The clocks either side of it
            // are about time and the strip carries a wheel gesture of its own; the
            // name of the track is the part that is ABOUT the track.
            //
            // Over the effect rather than inside the captured item: anything in
            // there is a texture and cannot be hit-tested.
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: content.titleClicked()
            }
        }

        // THE STATUS MARKS. Two of them are controls and one is a fact, which is
        // exactly the difference between them: you can save a track and you can
        // read its lyrics, and there is nothing to be done about it being
        // explicit.
        Row {
            id: marks
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0
            // Smaller than the transport beside them: these are about the track
            // rather than about driving it, and at the same size the line reads as
            // six equal buttons with a name in the middle.
            readonly property int markSide: 22

            // SAVED, AND PRESSABLE. The same verb the dock's heart sends and the
            // same one the action menu's Like row runs -- see Util.serve_control,
            // which takes the toggle's direction from state rather than a label.
            //
            // Dim when it is not saved, exactly as an unlit transport control is:
            // the outline heart at the same opacity every other `lit: false` key
            // on this line wears, so "not saved" reads as the same mark unlit
            // rather than as a different mark.
            GlyphKey {
                theme: content.theme
                side: marks.markSide
                // A Row skips an invisible child outright, so the gap goes with
                // the key rather than being left behind as a hole.
                visible: content.hasTrack
                glyph: content.liked ? content.theme.glyphLiked
                                     : content.theme.glyphUnliked
                glowCol: content.fg
                lit: content.liked
                onTapped: content.controlRequested("like")
            }
            // EXPLICIT IS NOT A BUTTON. Nothing happens when you press it because
            // there is nothing it could do -- so it is drawn rather than keyed.
            Item {
                width: marks.markSide
                height: marks.markSide
                anchors.verticalCenter: parent.verticalCenter
                visible: content.hasTrack && content.explicit
                Text {
                    anchors.fill: parent
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: content.theme.glyphExplicit
                    color: content.fg
                    font.family: content.theme.fontFamily
                    font.bold: true
                    font.pointSize: content.theme.fontSize
                }
            }
            // ...AND THE LYRICS MARK OPENS THEM. It said the track HAD lyrics and
            // gave you no way to reach them: the only route was Alt+y, which is a
            // key you have to already know. Filled for synced and hollow for
            // plain, the same pair Util.status_icons draws in a list.
            GlyphKey {
                theme: content.theme
                side: marks.markSide
                visible: content.hasTrack && content.lyrics !== "none"
                glyph: content.lyrics === "synced" ? content.theme.glyphLyricsSynced
                                                   : content.theme.glyphLyricsPlain
                glowCol: content.fg
                onTapped: content.lyricsRequested()
            }
        }
    }
    // A COPY MARK STOOD HERE, beside the playing track. Its only trigger was
    // Alt+g copying that track's link, and Alt+g now opens a pasted one instead
    // -- so it could never appear again. Copying from an action menu still gets
    // its receipt, on the row you picked: see RowList's copiedSrc, which says
    // WHICH thing was copied rather than assuming it was whatever is playing.
}
