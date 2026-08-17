// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// A text list -- the shape every non-grid view takes.
//
// ZENON `element`: 2px vertical / 20px horizontal padding, and a selected row
// filled with `selected-normal-background` rather than outlined. That fill is
// the one thing the main grid overrides away, which is why grids and lists are
// separate files rather than one with a flag.
import QtQuick
import "../Mark.js" as Mark

// A text list. rofi's listview is a grid whose default flow is VERTICAL -- it
// fills a column top to bottom, then starts the next one -- and the default menu
// theme really does use two columns. A plain ListView could never express that,
// which is why this is a GridView with one row's height per cell.
GridView {
    id: list
    property var theme
    property int columns: 1
    property int rowHeight: 26
    // The line being sung. Marked apart from the cursor: one is where the song
    // is, the other is where you are, and in a lyrics view they are usually not
    // the same row.
    property int activeIndex: -1
    // Per-theme row type. Every list but one takes ZENON's defaults; lyrics
    // centre and set their own size and weight. Keyed by theme in Theme.viewGeom
    // so a view never names itself in here.
    property bool centered: false
    property int rowSize: theme.fontSize
    property int rowWeight: theme.fontWeight
    // The row that just copied a link, by its index in the UNFILTERED list. -1
    // is none. See main.qml's copiedSrc: the mark belongs to the entry you
    // picked, so the list has to be told which entry that was.
    property int copiedSrc: -1
    // The row just picked, and a counter that ticks on every pick. See
    // main.qml's flashRow: the same row picked twice has to fire twice.
    property int flashSrc: -1
    property int flashSeq: 0
    // What is playing, and whether it is paused. The row that matches wears the
    // marker and the green -- drawn HERE, from live state, rather than baked
    // into the row's text by whoever built the menu.
    property string playingId: ""
    property bool paused: false
    // WHAT NARROWED THIS LIST. Every row here matched it, and the characters
    // that did are marked so the list can be scanned rather than re-read. See
    // Mark.js -- the tiles do the same with the same code.
    property string filter: ""
    clip: true
    keyNavigationWraps: false
    // Fills down, then across -- rofi's `listview` default. Left to right would
    // read the rows in the wrong order entirely for a two-column menu.
    flow: GridView.FlowTopToBottom
    cellWidth: Math.floor(width / Math.max(1, columns))
    cellHeight: rowHeight
    // THE HIGHLIGHT IS ITS OWN ITEM, so it can travel. Painted into each
    // delegate before this, it could only blink out of one row and into the
    // next, because there was no single thing there to move.
    //
    // It travels only when something MOVES it -- a synced lyric arriving at the
    // next line, which is a thing happening to the view. A cursor you are
    // driving yourself stays instant: an animated arrow key is just a slow one.
    // See glideMs, which the caller raises for the moves that deserve it.
    property int glideMs: 0
    highlight: Rectangle { color: list.theme.selectedBg }
    highlightMoveDuration: list.glideMs
    // Behind the rows, so text sits on the bar rather than under it. No
    // highlightResizeDuration here: that is ListView's, and every cell in a
    // GridView is the same size anyway.
    highlightFollowsCurrentItem: true

    // FOLLOWING, smoothly. A line becoming the sung one is a continuous thing --
    // the song did not cut to it -- so the list glides rather than jumps.
    //
    // The view is asked where it WOULD land, then put back and animated there:
    // positionViewAtIndex knows about row heights, the header, how near the end
    // of the list it is and every other thing this would otherwise have to
    // work out again and get subtly wrong.
    function followTo(i) {
        if (i < 0 || i >= count) return
        var from = contentY
        positionViewAtIndex(i, GridView.Contain)
        var to = contentY
        if (from === to) return
        contentY = from
        scrollAnim.to = to
        scrollAnim.restart()
    }
    // PUT BACK, not travelled to. followTo above is for a move that is happening;
    // this is for a layout that changed underneath a cursor which never moved --
    // an image card floating over the list widens the panel, and every column
    // boundary with it, so the same contentY lands somewhere else.
    function snap(i) {
        if (i < 0 || i >= count) return
        positionViewAtIndex(i, GridView.Contain)
    }

    NumberAnimation {
        id: scrollAnim
        target: list; property: "contentY"
        duration: list.glideMs > 0 ? list.glideMs : 240
        easing.type: Easing.InOutQuad
    }

    delegate: Rectangle {
        id: cell
        width: list.cellWidth
        height: list.cellHeight
        readonly property bool active: index === list.activeIndex
        // On the delegate ROOT: read from a child it is a different, always-false
        // instance -- the same trap that hid grid selection.
        readonly property bool current: GridView.isCurrentItem
        // The bar is drawn by `highlight` above, once, for whichever row is
        // current -- so the delegate paints no ground of its own.
        color: "transparent"

        readonly property bool playing:
            list.playingId.length > 0 && model.id === list.playingId
        // AFTER THE TRACK NUMBER, not in front of it. A numbered row reads
        // "3. <track>", and the marker belongs to the track rather than to the
        // ordinal -- putting it first shoved every number right by a glyph the
        // moment playback started. The engine wrote it in that position too,
        // back when it wrote it at all.
        //
        // Length of the "NN. " the engine formats, or 0 for a row that has none
        // -- a verb in an action menu, a setting. Markup rows never have one.
        readonly property int numEnd: {
            if (model.rich.length) return 0
            var m = /^\s*\d+\.\s/.exec(model.label)
            return m ? m[0].length : 0
        }
        readonly property bool split: cell.playing && cell.numEnd > 0
        Text {
            id: numText
            anchors { left: parent.left; leftMargin: list.theme.rowPadH
                      verticalCenter: parent.verticalCenter }
            visible: cell.split
            text: cell.split ? model.label.substring(0, cell.numEnd) : ""
            color: list.theme.playing
            font.family: list.theme.fontFamily
            font.pointSize: list.rowSize
            font.weight: list.rowWeight
        }
        // THE TRANSPORT MARKER, drawn rather than written. It moves the instant
        // playback does, because it is bound to playback and to nothing else --
        // no request, no redraw, no rebuilt menu.
        Text {
            id: mark
            anchors { left: cell.split ? numText.right : parent.left
                      leftMargin: cell.split ? 0 : list.theme.rowPadH
                      verticalCenter: parent.verticalCenter }
            visible: cell.playing
            text: list.paused ? list.theme.glyphPause : list.theme.glyphPlay
            color: list.theme.playing
            font.family: list.theme.fontFamily
            font.pointSize: list.rowSize
            font.weight: list.rowWeight
        }
        Text {
            id: label
            anchors {
                left: cell.playing ? mark.right : parent.left
                right: copyMark.left; verticalCenter: parent.verticalCenter
                leftMargin: cell.playing ? 0 : list.theme.rowPadH; rightMargin: 6
            }
            // MARKUP WHERE THERE IS ANY. spoot dims the actions a row cannot
            // offer -- Play and Seek on an unavailable track, Lyrics on one with
            // none -- and greens the value a settings list is currently on. All
            // of that arrived and was thrown away before the row was drawn, so a
            // dead action looked exactly like a live one.
            //
            // StyledText only for the rows that carry it: it is the slower path,
            // and nearly every row is plain.
            //
            // The FILTER marks on top of whichever of those two this row is --
            // including the tail of a numbered row, which is drawn plain beside
            // its own number. Mark.mark escapes plain text on the way in, so the
            // answer is always markup once there is a filter to mark.
            readonly property string raw:
                cell.split ? model.label.substring(cell.numEnd)
                           : (model.rich.length ? model.rich : model.label)
            readonly property bool rich: !cell.split && model.rich.length > 0
            text: list.filter.length
                  ? Mark.mark(raw, rich, list.filter, list.theme.notice)
                  : raw
            textFormat: (rich || list.filter.length) ? Text.StyledText : Text.PlainText
            color: (active || cell.playing) ? list.theme.playing : list.theme.foreground
            Behavior on color { ColorAnimation { duration: 180 } }
            horizontalAlignment: list.centered ? Text.AlignHCenter : Text.AlignLeft
            font.family: list.theme.fontFamily
            font.pointSize: list.rowSize
            font.weight: list.rowWeight
            elide: Text.ElideRight
        }
        // The copy receipt, at the right edge of the entry that earned it. Zero
        // width when it is not showing, so it costs the label nothing the rest of
        // the time -- which is every row but one, for one second.
        Text {
            id: copyMark
            anchors { right: parent.right; rightMargin: list.theme.rowPadH
                      verticalCenter: parent.verticalCenter }
            readonly property bool showing: list.copiedSrc >= 0 && model.src === list.copiedSrc
            text: list.theme.glyphCopied
            color: list.theme.playing
            font.family: list.theme.fontFamily
            font.pointSize: list.theme.fontSize
            width: showing ? implicitWidth : 0
            opacity: showing ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        }
        // THE SWOOP. A band of green running into white, sweeping the width of
        // the row once and going out with it. Above the text on purpose -- it
        // passes OVER the row rather than lighting it from behind, which is what
        // makes it read as a stroke across the thing you picked.
        Item {
            anchors.fill: parent
            clip: true
            visible: swoop.opacity > 0
            Rectangle {
                id: swoop
                width: parent.width
                height: parent.height
                opacity: 0
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0;  color: list.theme.fade(list.theme.playing, 0) }
                    GradientStop { position: 0.55; color: list.theme.fade(list.theme.playing, 0.55) }
                    GradientStop { position: 0.78; color: list.theme.fade(list.theme.foreground, 0.75) }
                    GradientStop { position: 1.0;  color: list.theme.fade(list.theme.foreground, 0) }
                }
                ParallelAnimation {
                    id: swoopAnim
                    NumberAnimation { target: swoop; property: "x"
                                      from: -swoop.width; to: swoop.width
                                      duration: 440; easing.type: Easing.OutCubic }
                    SequentialAnimation {
                        NumberAnimation { target: swoop; property: "opacity"
                                          from: 0; to: 1; duration: 90 }
                        NumberAnimation { target: swoop; property: "opacity"
                                          to: 0; duration: 350; easing.type: Easing.InCubic }
                    }
                }
            }
            Connections {
                target: list
                function onFlashSeqChanged() {
                    if (list.flashSrc === model.src) swoopAnim.restart()
                }
            }
        }
        MouseArea {
            anchors.fill: parent
            onClicked: list.currentIndex = index
        }
    }
}
