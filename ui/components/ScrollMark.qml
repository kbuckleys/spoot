// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// WHERE YOU ARE IN A LONG LIST, and nothing else.
//
// A thumb with no track behind it: a groove would be a permanent line down the
// edge of every view, and the question this answers -- "how far down 691 tracks
// am I" -- is only ever asked while the list is moving. So it appears with the
// motion and goes when the motion stops, the way a scroll position indicator on
// a phone does.
//
// PINNED, so it is declared beside the list and handed it, never inside it.
// Anything in a Flickable's default property becomes a child of contentItem and
// scrolls away with the rows -- an indicator that travels with what it is
// indicating says nothing at all.
import QtQuick

Item {
    id: mark
    // The Flickable (a GridView here) whose position this describes. May be null
    // while a Loader is between components; every binding tolerates that.
    property var view: null
    property var theme

    // WHICH AXIS OVERFLOWS. A RowList fills top-to-bottom, so a multi-column menu
    // grows sideways and scrolls on x -- the same question Scroll.js asks, and
    // for the same reason.
    readonly property bool horiz: !!view && view.contentWidth > view.width + 1
    readonly property real span: !view ? 0
        : Math.max(0, (horiz ? view.contentWidth - view.width
                             : view.contentHeight - view.height))
    readonly property real at: !view || span <= 0 ? 0
        : Math.max(0, Math.min(1, (horiz ? view.contentX : view.contentY) / span))
    // How much of the whole is on screen, which is how long the thumb is. Floored
    // so a list of thousands still leaves something to see.
    readonly property real shown: !view ? 1
        : Math.max(0.06, Math.min(1, (horiz ? view.width / Math.max(1, view.contentWidth)
                                            : view.height / Math.max(1, view.contentHeight))))

    // ...AND IT BELONGS TO THE LIST IT DESCRIBES. Handed the body's own fade (see
    // main.qml's bodyFade) so it goes out with the rows during a menu change: a
    // new menu replaces the model, which moves contentY, which is motion as far as
    // the Connections below can tell -- so without this the mark woke up and sat
    // there for a second over every transition, describing a list that was no
    // longer on screen.
    property real fade: 1
    visible: span > 0 && fade > 0.01
    // SEEN WHILE IT MOVES. Faded up the instant the position changes and back
    // down a beat after it settles -- long enough to read where you landed, short
    // enough that a still list has no furniture on it.
    opacity: 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    Timer {
        id: rest
        interval: 900
        onTriggered: mark.opacity = 0
    }
    function wake() {
        if (mark.span <= 0) return
        mark.opacity = 1
        rest.restart()
    }
    Connections {
        target: mark.view
        enabled: !!mark.view
        function onContentYChanged() { mark.wake() }
        function onContentXChanged() { mark.wake() }
    }

    Rectangle {
        id: thumb
        readonly property int thick: 3
        readonly property int gap: 2
        readonly property real room: (mark.horiz ? mark.width : mark.height) - mark.thumbLen
        width: mark.horiz ? mark.thumbLen : thick
        height: mark.horiz ? thick : mark.thumbLen
        x: mark.horiz ? Math.round(room * mark.at) : mark.width - thick - gap
        y: mark.horiz ? mark.height - thick - gap : Math.round(room * mark.at)
        radius: thick / 2
        // The dim the trail's inactive steps use. It is chrome about the list,
        // not part of it, and it must never compete with a row.
        color: mark.theme ? mark.theme.foreground : "#808080"
        opacity: 0.45 * mark.fade
    }
    // Long enough to grab hold of even when the list is enormous.
    readonly property real thumbLen:
        Math.max(24, (horiz ? width : height) * shown)
}
