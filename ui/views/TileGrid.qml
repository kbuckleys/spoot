// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// A thumbnail grid -- main.rasi's shape, and the one every album/artist/
// playlist/show grid inherits.
//
// The cover loading is where rofi's worst bug goes to die. rofi's icon fetcher
// caches by path with no invalidation, so a cover that landed a moment after the
// menu opened was never looked at again -- which is why spoot.lua paints
// placeholders rather than naming a file that is not on disk yet. QML's Image
// reloads when the source changes and retries on its own, so a late cover simply
// appears. The placeholder logic in the engine is harmless and stays until P4.
import QtQuick
import QtQuick.Effects
import "../Mark.js" as Mark
import "../Scroll.js" as Scroll

GridView {
    id: grid
    property var theme
    property int columns: 5
    // What narrowed this grid, marked in the captions. See RowList -- one
    // implementation, because a caption and a row are the same question.
    property string filter: ""
    // The tile just picked, and a counter that ticks on every pick. Same pair
    // the lists use -- see main.qml's flashRow.
    property int flashSrc: -1
    property int flashSeq: 0
    // What is playing, and which ALBUM it is playing out of. A tile is a
    // container, so the tile that is playing is the one HOLDING the playing
    // track -- matching on the track id alone could only ever light up a single,
    // whose tile happens to be its own track. Drawn from live state, like a list
    // row's marker, so it moves with autoplay and costs no redraw.
    property string playingId: ""
    property string playingAlbumId: ""
    property bool paused: false
    // ...and where you left off, which is not the same thing. See RowList.lastId:
    // on a cold start the poll names a track that is over rather than paused, and
    // the tile holding it used to go green as though it were running.
    property string lastId: ""
    property string lastAlbumId: ""

    clip: true
    cellWidth: Math.floor(width / Math.max(1, columns))
    cellHeight: theme.cellHeightFor(cellWidth)
    // How big a cover may be in the room this many columns leave it. Read by the
    // delegate below; the panel works out the same number from its own width
    // (see root.cellW) through the same two functions.
    readonly property int iconSize: theme.tileIconFor(cellWidth)
    keyNavigationWraps: false
    highlightMoveDuration: 0
    // HOW FAR A SHOVE CARRIES. Qt's defaults are tuned for a phone list you drag
    // with a thumb; a wall of covers you are flicking through with a wheel wants
    // to move further per gesture and settle sooner.
    //
    maximumFlickVelocity: 6000
    flickDeceleration: 2200
    // ...and the spring back off the end. The default rebound is slow enough to
    // read as the grid recovering from something; this is a bounce.
    rebound: Transition {
        NumberAnimation { properties: "x,y"; duration: 90; easing.type: Easing.OutCubic }
    }
    // A COVER WAS PICKED WITH THE MOUSE. See RowList.picked -- same signal, same
    // reason: the grid does not know what opening a tile means.
    signal picked(int index, bool alt)
    // A PLAIN CLICK, reported as well as acted on. The list moves its own
    // cursor -- that part never leaves here -- but a click also MEANS
    // something to the app when a card is up, and the list has no idea a
    // card exists. See main.qml, where this closes it.
    signal rowClicked(int index)
    // ...and the middle button, which queues.
    signal rowQueued(int index)
    // SOMETHING IS IN FRONT OF THESE ROWS. A click then means "dismiss it",
    // and a dismissal must not also move the cursor or pick anything -- the
    // press is aimed AWAY from the list, and it lands on the list only
    // because the list is what happens to be behind. Reported all the same,
    // because closing whatever is in front is the app's business, not this
    // file's.
    property bool inert: false
    // A PRESS LANDED, whatever it turns out to mean. Reported so the app can
    // stop anything that MOVES this list while a click is being made: a
    // double click is two presses, and a list that scrolls between them hands
    // the second one to a different row. See main.qml's lastManualMove.
    signal rowPressed()

    // THE CORNER EVERY COVER TURNS, cut once. An Image has no radius and `clip`
    // is a bounding-box clip, so rounding one means masking it -- and a mask is a
    // texture. Every tile is the same square at the same size, so this is ONE
    // rounded shape captured once and used as the mask for all of them, rather
    // than sixty delegates each rendering their own copy of the same white box.
    //
    // Same capture-and-effect idiom the art viewer's picture uses, and the shape
    // is hidden the same way: rendered into the texture, never into the scene.
    Rectangle {
        id: artMaskShape
        width: grid.iconSize
        height: grid.iconSize
        color: "white"
        radius: grid.theme.tileArtRadius
        visible: false
    }
    ShaderEffectSource {
        id: artMask
        width: grid.iconSize
        height: grid.iconSize
        sourceItem: artMaskShape
        hideSource: true
        live: true
        visible: false
    }

    // THE WHEEL, made to travel. One notch used to be exactly one row of tiles,
    // which is the same distance the keyboard covers with one arrow press -- so
    // crossing a wall of six hundred covers was still a hundred and fifty
    // gestures. The rule is Scroll.js's now, shared with the list so the two
    // shapes cannot drift apart, and it is half a viewport snapped to whole rows.
    //
    // Mouse only. A touchpad sends a continuous stream of small deltas and the
    // Flickable's own handling is already right for that -- taking it over here
    // would turn a smooth two-finger drag into a staircase.
    WheelHandler {
        acceptedDevices: PointerDevice.Mouse
        // See RowList: a handler that cannot act must not eat the notch.
        enabled: grid.contentHeight > grid.height + 1
                 || grid.contentWidth > grid.width + 1
        onWheel: function (e) { Scroll.wheel(grid, e, wheelAnim) }
    }
    NumberAnimation {
        id: wheelAnim
        duration: 110; easing.type: Easing.OutCubic
    }

    // TWO GRADIENT BANDS STOOD HERE, half a cell tall, one against each edge of
    // the viewport: a scrolling grid was supposed to fade its clipped rows into
    // the panel rather than cut them. They were switched on by `atYBeginning`
    // and `atYEnd` -- and the note beside them warned about precisely what they
    // then did: "a permanent shadow there would just be a dark band".
    //
    // Measured on Main, which does not scroll at all: the panel ground under the
    // covers ran from 15 down to 4 across the bottom half of the body. A shadow
    // inside the window, cast by nothing, on the first view anyone sees.
    //
    // Gone rather than fixed. What they were for -- a row sliced mid-tile
    // reading as damage -- is a real thing, and this was not the way: the panel
    // sizes itself to whole rows (see usedRows), so a grid is cut at a row
    // boundary, not through one.

    delegate: Item {
        id: cell
        width: grid.cellWidth
        height: grid.cellHeight
        // The attached property lives on the DELEGATE ROOT and nowhere else --
        // read from a child it is simply a different, always-false instance,
        // which is why no selection was drawn at all.
        readonly property bool current: cell.GridView.isCurrentItem

        // ONE selection style for every grid. main.rasi's border-only highlight
        // used to be Main's alone, with the other grids filling the cell instead
        // -- two ways of saying the same thing, and the wrong one everywhere you
        // actually browse covers. A fill sits ON the artwork; an outline frames
        // it. Lists keep their filled row (RowList): there is no artwork under
        // it to obscure.
        Rectangle {
            id: sel
            anchors.fill: parent
            anchors.margins: 2
            radius: grid.theme.tileRadius
            color: "transparent"
            border.width: cell.current ? grid.theme.tileBorder : 0
            border.color: grid.theme.tileSelected
        }
        // THE PICK, ACKNOWLEDGED -- the grid's half of the list's swoop. A tile
        // has no width for a band to travel across the way a row does, so the
        // outline carries it instead: it fades up to green, thickens, and
        // settles back to the grey it sits at.
        //
        // Green the whole way, with no white in it. The row's swoop runs green
        // into white because it is a band travelling ACROSS something and the
        // white is its leading edge; an outline has no leading edge, so a second
        // colour there is just a second colour.
        //
        // Its own rectangle rather than animating `sel`, whose border is bound
        // to whether the tile is current -- an animation writing to a bound
        // property breaks the binding, and the selection would then be stuck
        // wherever the last flash left it.
        readonly property bool lastPick:
            (grid.lastId.length > 0 && model.id === grid.lastId)
            || (grid.lastAlbumId.length > 0 && model.id === grid.lastAlbumId)
        // THE GLOW, the grid's half of the list's. A tile is artwork, so light
        // UNDER it would be invisible -- the outline carries it here, the same
        // way the pick flash does, breathing rather than sweeping because this is
        // a state and not an event.
        Rectangle {
            anchors.fill: sel
            radius: sel.radius
            color: "transparent"
            visible: cell.lastPick
            border.width: grid.theme.tileBorder
            border.color: grid.theme.fade(grid.theme.playing, 0.55)
            SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: cell.lastPick
                NumberAnimation { from: 0.3; to: 1.0; duration: 1100
                                  easing.type: Easing.InOutSine }
                NumberAnimation { from: 1.0; to: 0.3; duration: 1100
                                  easing.type: Easing.InOutSine }
            }
        }
        Rectangle {
            id: pick
            anchors.fill: sel
            radius: sel.radius
            color: "transparent"
            border.width: 0
            border.color: grid.theme.playing
            opacity: 0
            visible: opacity > 0
            SequentialAnimation {
                id: pickAnim
                ParallelAnimation {
                    NumberAnimation { target: pick; property: "opacity"
                                      from: 0; to: 1; duration: 90 }
                    NumberAnimation { target: pick; property: "border.width"
                                      from: grid.theme.tileBorder
                                      to: grid.theme.tileBorder * 2; duration: 90 }
                }
                ParallelAnimation {
                    NumberAnimation { target: pick; property: "opacity"
                                      to: 0; duration: 350; easing.type: Easing.InCubic }
                    NumberAnimation { target: pick; property: "border.width"
                                      to: grid.theme.tileBorder; duration: 350 }
                }
            }
            Connections {
                target: grid
                function onFlashSeqChanged() {
                    if (grid.flashSrc === model.src) pickAnim.restart()
                }
            }
        }

        Column {
            anchors.centerIn: parent
            spacing: grid.theme.tileSpacing

            Item {
                width: grid.iconSize
                height: grid.iconSize
                anchors.horizontalCenter: parent.horizontalCenter

                // What sits there until the cover lands. A tile is never a hole:
                // the grid is complete and scrollable from the first frame, and
                // art settles into it.
                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(1, 1, 1, 0.04)
                    // The same corner the cover will have, so the tile does not
                    // change shape the moment its artwork lands.
                    radius: grid.theme.tileArtRadius
                    visible: cover.status !== Image.Ready
                }
                Image {
                    id: cover
                    anchors.fill: parent
                    source: theme.fileUrl(model.icon)
                    asynchronous: true
                    cache: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: grid.iconSize
                    sourceSize.height: grid.iconSize
                    // Fades rather than pops. Late art should look intentional,
                    // which is the whole difference between streaming and
                    // stalling.
                    opacity: status === Image.Ready ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                    // Rounded by the shared mask above.
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        maskEnabled: true
                        maskSource: artMask
                    }
                }
            }
            Text {
                width: grid.cellWidth - grid.theme.tilePadding * 2
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                // The marker rides in front of the label rather than as its own
                // item: a tile's caption is centered, and a separate glyph beside
                // it would push the words off center whenever playback started.
                // EITHER id matches: the track's, so a lyrics or episode grid
                // whose rows are the playing thing itself still marks, and the
                // album's, so a grid of albums marks the one the track is coming
                // out of. Same green and same glyph a list row wears -- there is
                // one language for "this is what is playing" and a grid speaks it
                // too.
                readonly property string mark:
                    ((grid.playingId.length > 0 && model.id === grid.playingId)
                     || (grid.playingAlbumId.length > 0
                         && model.id === grid.playingAlbumId))
                    ? (grid.paused ? grid.theme.glyphPause : grid.theme.glyphPlay) : ""
                // Same rule as a list row: markup where the row carries any,
                // plain text where it does not. No tile carries markup today --
                // spoot marks up verbs and values, and a tile is neither -- so
                // this changes nothing now. It is here because the alternative
                // is a grid that silently strips the first label that ever gains
                // some, and silently is how the whole class of these was missed.
                readonly property string raw: model.rich.length ? model.rich : model.label
                readonly property bool rich: model.rich.length > 0
                // WHAT THE ROW IS, THEN WHAT IT IS DOING. A one-track album wears
                // display_album's single glyph, and the engine's comment there
                // asks for that glyph FIRST with the transport marker after it --
                // a fixed leading column, rather than one that shifts sideways the
                // moment playback starts. Prepending the marker put them the wrong
                // way round, which is what marking from QML cost when it moved out
                // of the engine's string.
                //
                // Split on the glyph itself rather than on the markup around it:
                // the character is literally present in both `label` and `rich`,
                // so this does not depend on how the engine chooses to colour it.
                // The space after it is the engine's; cutting past it leaves two
                // fragments whose tags are each balanced.
                readonly property int cut: {
                    // indexOf, not charAt: U+F069F is outside the BMP, so a
                    // string holds it as a surrogate PAIR and charAt(0) hands
                    // back half a character that equals nothing.
                    if (model.label.indexOf(grid.theme.glyphSingle) !== 0) return -1
                    var i = raw.indexOf(grid.theme.glyphSingle)
                    if (i < 0) return -1
                    var sp = raw.indexOf(" ", i)
                    return sp < 0 ? -1 : sp + 1
                }
                readonly property string head: cut < 0 ? "" : raw.substring(0, cut)
                readonly property string body: cut < 0 ? raw : raw.substring(cut)
                // The marker stays outside the marking: it is not part of the
                // caption and must never be a thing the filter can light up. Nor
                // is the single glyph, which is now outside it too.
                text: head + mark + (grid.filter.length
                                     ? Mark.mark(body, rich, grid.filter, grid.theme.notice)
                                     : body)
                textFormat: (rich || grid.filter.length) ? Text.StyledText : Text.PlainText
                color: mark.length ? grid.theme.playing : grid.theme.foreground
                font.family: grid.theme.fontFamily
                font.pointSize: grid.theme.tileFontSize
                font.weight: Font.DemiBold
            }
        }
        MouseArea {
            anchors.fill: parent
            // See RowList's delegate: same three gestures, same reasons, and the
            // BACK button left unaccepted so it reaches `outside`.
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            onPressed: grid.rowPressed()
            onClicked: function (m) {
                if (grid.inert) { grid.rowClicked(index); return }
                grid.currentIndex = index
                if (m.button === Qt.RightButton) { grid.picked(index, true); return }
                // THE THIRD BUTTON QUEUES. It had no meaning at all before --
                // rofi had no third button to bind -- and "play this next" is
                // the verb people reach for most often after play itself.
                if (m.button === Qt.MiddleButton) { grid.rowQueued(index); return }
                grid.rowClicked(index)
            }
            onDoubleClicked: function (m) {
                if (grid.inert) return
                if (m.button === Qt.LeftButton) grid.picked(index, false)
            }
        }
    }
}
