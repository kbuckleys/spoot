// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// THE DOCK: what spoot is playing, without opening spoot.
//
// A second layer surface, mapped whenever the panel is not. It is the size of
// the whole output for the same reason the panel's surface is -- position is
// ours and a pointer event outside our own surface does not exist -- but this
// one is up while you are using other programs, so what it ACCEPTS is a 4px band
// along the edge the panel opens from, and the pill's own shape once that band
// has been touched. Everything else on the output passes straight through it.
// See Shell::dockRegion, which is handed the region this file computes.
//
// It draws in the panel's language and not a language of its own: same ground,
// same radius, same border, same shadow, and the transport glyphs the
// now-playing strip already uses. It is spoot's edge, not a widget beside it.
import QtQuick
import QtQuick.Window
import QtQuick.Shapes
import "components"

Window {
    id: dock
    objectName: "spootDock"
    color: "transparent"
    flags: Qt.FramelessWindowHint
    // Mapped and unmapped by the host, which is also the only thing that knows
    // whether the panel is up. See Shell::dockRegion and Shell::reveal.
    visible: false
    // REGISTERED BEFORE IT IS SHOWN. The host turns this into a layer surface,
    // and that can only be done to a window that has no platform window yet --
    // which is exactly what Component.onCompleted describes. See
    // Shell::registerDock.
    Component.onCompleted: if (typeof Shell !== "undefined")
                              Shell.registerDock(dock, dock.screenName)

    // THE FREE AREA, measured by the compositor rather than guessed at.
    //
    // A surface of its own, because the dock's has to be the whole output (see
    // Shell::registerProbe). This one is never drawn and never takes input; its
    // SIZE is the entire point, and it changes on its own when a bar appears,
    // moves or goes away, so the pill follows without anything having to notice.
    Window {
        id: probe
        objectName: "spootProbe"
        color: "transparent"
        flags: Qt.FramelessWindowHint
        visible: false
        Component.onCompleted: if (typeof Shell !== "undefined")
                                  Shell.registerProbe(probe, dock.screenName)
    }
    // What a bar has taken, on the axis the dock lives on. Zero where nothing
    // reserves anything, which is the ordinary case and changes nothing.
    readonly property int edgeInset: {
        if (probe.height <= 0 || dock.outH <= 0) return 0
        // CLAMPED, because a wrong answer here puts the hot spot somewhere the
        // pointer cannot go. The probe is a second layer surface whose SIZE is the
        // free area (see Shell::registerProbe), and how a compositor sizes it is
        // the compositor's business -- one that answers oddly, or not at all,
        // would otherwise push the band off the screen and the dock would simply
        // never open. A quarter of the output is more than any bar reserves.
        var reserved = dock.outH - probe.height
        if (reserved <= 0) return 0
        return Math.min(reserved, Math.round(dock.outH / 4))
    }
    // WHERE THE EDGE EFFECTIVELY IS: the screen's, less whatever is parked on it.
    // Every placement below reads this rather than the output's own edge -- the
    // pill, the glow, and the line the pointer is measured against -- so a bar
    // moves all three together.
    readonly property int edgeY: dock.onTop ? dock.edgeInset : dock.outH - dock.edgeInset

    property var theme
    // Straight from main.qml -- the poll that feeds the now-playing strip runs
    // whether or not the panel is up, so this is live without a second reader.
    property var playback: ({})
    property int positionMs: 0
    property string art: ""
    // Liked, explicit, lyrics -- exactly as Util.status_icons built them, never
    // re-derived here. The strip inside spoot rides them on the title for the same
    // reason: the glyphs and their order are the engine's to decide.
    property string icons: ""
    // Whether the playing track is saved. From the playback payload as a fact of
    // its own -- not picked back out of `icons`, which is the engine's finished
    // answer about how a status looks.
    property bool liked: false
    // "top" / "middle" / "bottom" and "left" / "center" / "right", exactly as the
    // panel reads them out of UI Settings.
    property string anchorV: "bottom"
    property string anchorH: "center"
    property bool armed: false
    // WHICH OUTPUT THIS ONE IS. There is a dock per screen -- see main.qml's
    // Instantiator -- and the host binds each surface to the output named here.
    property string screenName: ""
    // ...and how big it is, for the moment before the compositor has said. A
    // layer surface has no size until it is mapped and this one does not map
    // until it has an input region computed from its size; the screen's own
    // geometry breaks that circle. Once mapped, the surface's size is the truth.
    property int scrW: 0
    property int scrH: 0
    // Where this output starts in the layout, so a global cursor position can be
    // made local to it.
    property int scrX: 0
    property int scrY: 0
    // THE POINTER, IN LAYOUT COORDINATES, from the compositor rather than from a
    // pointer event -- see Shell::watchCursor. -1 means nobody is telling us,
    // which is every compositor but Hyprland, and the dock falls back to a band
    // you have to touch.
    property int curX: -1
    property int curY: -1
    property bool tracked: false

    signal openRequested()
    signal actionsRequested()
    signal controlRequested(string action, int by)

    // WHICH EDGE. "middle" is not an edge you can hover, so a centred panel puts
    // its dock on the bottom -- the same place a panel with no preference goes.
    // HOW BIG THE OUTPUT IS, before the compositor has said.
    //
    // A layer surface has no size until it is mapped, and this one is not mapped
    // until it has an input region -- which is computed from its size. That is a
    // circle, and it closed on zero: the band came out 0 wide, the host read an
    // empty region and hid the window, so the dock could never appear at all.
    // Screen breaks it. Once the surface IS mapped its own size is the truth and
    // these fall through to it.
    readonly property int outW: dock.width > 0 ? dock.width : dock.scrW
    readonly property int outH: dock.height > 0 ? dock.height : dock.scrH

    readonly property string edge: dock.anchorV === "top" ? "top" : "bottom"
    readonly property bool onTop: dock.edge === "top"
    // A HOT SPOT, NOT A HOT EDGE.
    //
    // The dock has to know you are COMING, not only that you have arrived -- a
    // 6px line you cannot see until you are standing on it is a secret, and the
    // whole point of the glow is that it warms up as you approach. Knowing you
    // are near means accepting pointer motion out to where "near" begins, and a
    // client only hears about motion inside its own input region.
    //
    // So the region is deep rather than wide: 44px out from the edge, and only
    // across the stretch of it the pill actually occupies. A band the width of
    // the output at this depth would take a strip off the bottom of every
    // monitor; this takes a patch the size of the thing it is offering you, in
    // the one place that thing appears.
    // HOW FAR OUT "NEAR" REACHES. Deep when the compositor is telling us where
    // the pointer is, because nothing is being taken from the desktop to find
    // out; shallow when it is not, because then the only way to know is to accept
    // input over that whole patch -- and a 44px band that swallows clicks is a
    // worse bargain than a glow that comes up late.
    //
    // Tracked, the region is one pixel and this is only how far the glow reaches:
    // Hyprland answers `cursorpos`, so an approach can be FELT from 64px out
    // without owning any ground, and trackedNear ramps across it.
    //
    // UNTRACKED THERE IS NO APPROACH, only an arrival. The region IS this depth --
    // the only way to hear about the pointer is to accept input over it -- so
    // twenty pixels is all that can be taken from the desktop without the dock
    // becoming a strip that swallows clicks, and inside twenty pixels there is
    // nothing to ramp: you are at the edge or you are not. Every other compositor
    // gets that bargain, which is the difference between a dock that exists and
    // one that does not.
    readonly property int hotDepth: dock.tracked ? 64 : 20
    readonly property int hotPad: 60
    readonly property int hotW: Math.min(dock.outW, pill.width + dock.hotPad * 2)
    readonly property int hotX: Math.round(pill.x + pill.width / 2 - dock.hotW / 2)
    // How close to the edge counts as arriving. The glow ramps the whole way in;
    // this is where the pill starts its own wait.
    readonly property real touchAt: 0.82
    // 0 at the far side of the hot spot, 1 at the edge itself. The whole
    // mechanism: the glow reads it, and crossing `touchAt` starts the pill's wait.
    //
    // Computed from the compositor's answer where there is one -- which is what
    // lets the idle input region be a single pixel -- and written by the MouseArea
    // where there is not.
    property real trackedNear: {
        if (!dock.tracked || dock.open || !dock.armed) return 0
        if (dock.curX < 0 || dock.outW <= 0) return 0
        var lx = dock.curX - dock.scrX
        var ly = dock.curY - dock.scrY
        if (lx < dock.hotX || lx > dock.hotX + dock.hotW) return 0
        // Against the FREE edge, not the screen's -- the pill lives inside the
        // free area, so that is the line being approached.
        var d = dock.onTop ? (ly - dock.edgeY) : (dock.edgeY - 1 - ly)
        if (d > dock.hotDepth) return 0
        // PAST IT IS ARRIVED, NOT ABSENT. Everything between the free edge and
        // the screen's is the bar, and throwing the pointer at the bottom of the
        // screen is exactly how you reach for this -- it is the gesture, not a
        // miss. Read as a negative distance it came out below zero and the hot
        // spot stopped answering at the very place people aim at.
        //
        // Clamped rather than rejected, so the bar's own strip counts as fully
        // arrived. Nothing is taken from the bar for it: the pointer is only
        // being LOOKED at, and the pill still sits above the reserved area.
        if (d < 0) d = 0
        return 1 - d / dock.hotDepth
    }
    // ARRIVED, OR NOT ARRIVED, read off where the pointer IS rather than written
    // by the last motion event that happened to be delivered.
    //
    // A HANDLER STOOD HERE and that is "the hot spot sometimes does not trigger",
    // and on another machine "does not work at all". `onPositionChanged` fires on
    // MOTION -- and the gesture people actually make is to throw the pointer at
    // the edge and STOP. The compositor then delivers an enter and no motion
    // inside the band at all, so nothing ever set this, `near` never reached
    // touchAt and the pill never came. Whether it worked was down to whether your
    // hand kept moving after you arrived, which is why it looked intermittent
    // here and dead elsewhere.
    //
    // As a binding the question is asked whenever any part of the answer moves,
    // and `containsMouse` is what the compositor's own enter and leave already
    // drive -- the surface is masked to the band, so being in the region and
    // being over the band are the same fact.
    //
    // Bounds still tested rather than assumed: belt to the region's braces, and
    // it makes the answer depend on where the pointer is rather than on the host
    // having masked the surface exactly as asked. Past the free edge counts as
    // arrived, exactly as it does in trackedNear -- everything between it and the
    // screen's edge is the bar, and throwing the pointer at the bottom of the
    // screen is the gesture, not a miss.
    readonly property real touchedNear: {
        if (dock.tracked || dock.open || !dock.armed) return 0
        if (!hot.containsMouse) return 0
        var d = dock.onTop ? (hot.mouseY - dock.edgeY) : (dock.edgeY - 1 - hot.mouseY)
        var inX = hot.mouseX >= dock.hotX && hot.mouseX <= dock.hotX + dock.hotW
        // THE OTHER HALF OF THE DOCK LINE. That one says where the band was put;
        // this says where the pointer was reported. Either alone is a guess --
        // together they tell a band in the wrong place from a band nothing is
        // reaching, which is the entire diagnosis on a compositor nobody here can
        // run.
        if (dock.debug) console.log("DOCK POS " + dock.screenName
            + " m=" + hot.mouseX + "," + hot.mouseY + " edgeY=" + dock.edgeY
            + " d=" + d + " inX=" + inX)
        return (inX && d <= dock.hotDepth) ? 1 : 0
    }
    readonly property real near: dock.tracked ? dock.trackedNear : dock.touchedNear
    // Crossing the line starts the wait; falling back below it cancels it. One
    // watcher rather than a test in two places, because `near` now has two
    // sources and both have to reach the pill the same way.
    onNearChanged: {
        if (dock.open) return
        if (dock.near >= dock.touchAt) { shutWait.stop(); openWait.restart() }
        else openWait.stop()
    }
    // How much slack the pill keeps around itself once open. Leaving it by one
    // pixel must not close it, or the buttons on its own border are unclickable.
    readonly property int slack: 10

    // IS THERE A TRACK AT ALL. NOT `active`: that is a property of every QWindow
    // -- whether this surface has keyboard focus -- and shadowing it here means
    // any future reader of dock.active gets whichever of the two the resolver
    // happens to pick.
    readonly property bool hasTrack: !!(dock.playback && dock.playback.name)
    readonly property real progress: {
        var d = dock.playback && dock.playback.duration || 0
        if (d <= 0) return 0
        return Math.max(0, Math.min(1, dock.positionMs / d))
    }

    // --- what the host may send pointer events to ----------------------------
    // Two rects while open, one while idle. Recomputed by a binding rather than
    // pushed from each place that could change it: the pill's own width follows
    // the track name, so the region has to follow the pill and not a guess about
    // where it will be.
    property bool open: false
    readonly property var region: {
        if (!dock.armed || dock.outW <= 0) return []
        if (!dock.open) {
            // NOTHING, WHILE NOTHING IS OFFERED. With the compositor telling us
            // where the pointer is, the dock does not need to own any ground to
            // notice you approaching -- so it owns none, and the bar or the icon
            // under the hot spot goes on working exactly as it did.
            //
            // ONE PIXEL RATHER THAN AN EMPTY REGION, and this is not a detail: Qt
            // reads an empty mask as "no mask" and hands the surface a null input
            // region, which means the WHOLE OUTPUT accepts input. The opposite of
            // what is wanted, silently. A 1x1 in the corner is the smallest thing
            // that still says "only here".
            if (dock.tracked) return [Qt.rect(0, 0, 1, 1)]
            // Untracked, the only way to feel an approach is to accept it, so the
            // shallow band above is what gets touched.
            return [Qt.rect(dock.hotX,
                            dock.onTop ? dock.edgeY : dock.edgeY - dock.hotDepth,
                            dock.hotW, dock.hotDepth)]
        }
        // OPEN: the pill AND the ground between it and the edge, as one rect. The
        // pill floats a panelLift above the edge, so a region that held only the
        // pill left a gap the pointer crosses on its way up -- it would leave the
        // region, and leaving is what closes this.
        var top = dock.onTop ? dock.edgeY : pill.y - dock.slack
        var bot = dock.onTop ? pill.y + pill.height + dock.slack : dock.edgeY
        return [Qt.rect(pill.x - dock.slack, top,
                        pill.width + dock.slack * 2, bot - top)]
    }
    onRegionChanged: {
        if (typeof Shell !== "undefined") Shell.dockRegion(dock, dock.region)
        // WHAT THIS COMPOSITOR ACTUALLY GAVE US. The dock is built against
        // wlr-layer-shell, which KWin, sway, wayfire and Hyprland all implement --
        // and only Hyprland can be asked where the pointer is, so everywhere else
        // rides on the probe and the band being right. When it is not, this is the
        // one line that says which of them was wrong.
        if (dock.debug)
            console.log("DOCK " + dock.screenName
                + " probe=" + probe.width + "x" + probe.height
                + " out=" + dock.outW + "x" + dock.outH
                + " inset=" + dock.edgeInset + " edgeY=" + dock.edgeY
                + " tracked=" + dock.tracked + " depth=" + dock.hotDepth
                + " armed=" + dock.armed + " open=" + dock.open
                + " region=" + JSON.stringify(dock.region))
    }
    readonly property bool debug: (typeof SPOOT_DOCK_DEBUG !== "undefined")
                                  && SPOOT_DOCK_DEBUG === "1"

    // OPENS ON TOUCH, CLOSES ON A DELAY. The pointer crosses the band on its way
    // somewhere else all day long; a dock that appeared and vanished on every
    // one of those would be noise. The delay in is what makes it deliberate, and
    // the delay out is what lets you leave the pill for a moment -- past its own
    // edge, over a button -- without it going.
    Timer { id: openWait; interval: 220; onTriggered: dock.open = true }
    // A FULL SECOND. Reaching for a button on the pill takes you across its own
    // border and back, and past its edge on the way to the far end of it -- a
    // short grace turns every one of those into a flicker. A second is long
    // enough that leaving is something you did rather than something that
    // happened to you.
    Timer { id: shutWait; interval: 1000; onTriggered: dock.open = false }
    MouseArea {
        id: hot
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        // The two the binding above cannot express, because they are about TIME
        // rather than about position: entering cancels a close already counting
        // down, leaving starts one. Where the pointer is while it is here is
        // dock.touchedNear's question and is asked there.
        onEntered: shutWait.stop()
        onExited: { openWait.stop(); shutWait.restart() }
        // THE WHEEL IS VOLUME HERE, and seek on the now-playing strip. They are
        // not the same surface and not the same question: the strip is a picture
        // of the position, so moving the position is what a wheel over it means;
        // the dock is the whole player, and volume is what you reach for without
        // wanting to look at anything.
        onWheel: function (e) {
            var d = e.angleDelta.y !== 0 ? e.angleDelta.y : e.angleDelta.x
            if (d === 0) return
            dock.controlRequested("volume", d > 0 ? 5 : -5)
            e.accepted = true
        }
        // Anywhere on the pill that is not a button: the playing track's verbs,
        // which is the same card the now-playing strip's title opens.
        onClicked: function (m) {
            if (m.button === Qt.RightButton) dock.actionsRequested()
        }
    }

    // THE EDGE LIGHTS UP. The same light spoot burns while it is waiting on the
    // engine -- a wide, shallow ellipse of `playing` with no edge anywhere, so it
    // is the falloff itself rather than a bar drawn on the screen. It means the
    // same thing in both places: spoot is about to give you something.
    //
    // It is also the whole affordance. A 6px band you cannot see is a secret; a
    // band that answers the moment you touch it is a control, and the wait before
    // the pill arrives stops being a delay and becomes the thing acknowledging
    // you. So it comes up on ENTER and goes as the pill takes over.
    Item {
        id: edgeGlow
        // OVER THE HOT SPOT AND NOWHERE ELSE. It used to run the width of the
        // output, which reads as the whole edge of the screen lighting up -- a
        // system-wide event rather than one small thing offering itself. It is
        // the width of the patch you are actually approaching.
        width: dock.hotW
        x: dock.hotX
        height: 64
        y: dock.onTop ? dock.edgeY : dock.edgeY - height
        visible: opacity > 0
        // WARMER AS YOU GET CLOSER. Not a switch: `near` is a distance, so the
        // light comes up under the pointer as it arrives rather than snapping on
        // when it lands. Gone once the pill is out -- the pill is the answer the
        // glow was promising.
        opacity: dock.open ? 0 : dock.near
        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        // Breathing, exactly as the loading glow does -- same property, same
        // curve, same 620ms either way. Nothing here is measuring progress, and a
        // light that pulses claims nothing.
        Item {
            id: glowBreath
            anchors.fill: parent
            SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: edgeGlow.visible
                NumberAnimation { from: 0.2; to: 1.0; duration: 620
                                  easing.type: Easing.InOutSine }
                NumberAnimation { from: 1.0; to: 0.2; duration: 620
                                  easing.type: Easing.InOutSine }
            }
        Shape {
            id: glowShape
            width: 100
            height: edgeGlow.height
            transform: Scale { xScale: edgeGlow.width / glowShape.width }
            ShapePath {
                strokeWidth: 0
                // Centred just past the edge, so the light reaches into the screen
                // and not off it -- the mirror of the body glow hanging off the
                // header, flipped when the dock lives on the top edge.
                fillGradient: RadialGradient {
                    centerX: 50
                    centerY: dock.onTop ? -8 : edgeGlow.height + 8
                    centerRadius: 70
                    focalX: 50
                    focalY: dock.onTop ? -8 : edgeGlow.height + 8
                    GradientStop { position: 0.0;  color: dock.theme.fade(dock.theme.playing, 0.34) }
                    GradientStop { position: 0.45; color: dock.theme.fade(dock.theme.playing, 0.13) }
                    GradientStop { position: 1.0;  color: dock.theme.fade(dock.theme.playing, 0.0) }
                }
                startX: 0; startY: 0
                PathLine { x: glowShape.width; y: 0 }
                PathLine { x: glowShape.width; y: glowShape.height }
                PathLine { x: 0; y: glowShape.height }
                PathLine { x: 0; y: 0 }
            }
        }
        }
    }

    Shadow {
        theme: dock.theme
        target: pill
        fade: pill.opacity
    }

    Rectangle {
        id: pill
        readonly property int pad: 8
        readonly property int artSize: 44
        width: Math.min(dock.outW - 40, Math.max(420, row.implicitWidth + pad * 2))
        height: artSize + pad * 2
        x: dock.anchorH === "left"  ? dock.theme.panelLift
         : dock.anchorH === "right" ? dock.outW - width - dock.theme.panelLift
         : Math.round((dock.outW - width) / 2)
        // It comes OUT of the edge it is anchored to, which is the gesture the
        // panel makes -- so the two read as the same object at two sizes.
        y: (dock.onTop ? dock.edgeY + dock.theme.panelLift
                       : dock.edgeY - height - dock.theme.panelLift)
           + (dock.open ? 0 : (dock.onTop ? -height : height) * 0.4)
        Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        color: dock.theme.ground
        radius: dock.theme.radius
        border.width: dock.theme.borderWidth
        border.color: dock.theme.borderCol
        clip: true
        // IT COMES OUT WHETHER OR NOT ANYTHING IS PLAYING. It used to need a
        // track, so the one moment the dock was most worth having -- nothing
        // loaded, and you want to start something -- was the one moment it did
        // not appear, and the hot spot read as broken. What changes with no
        // track is what is ON it: no cover, no title, no progress, and no Like,
        // which is the only verb here that needs something to act on.
        opacity: dock.open ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Row {
            id: row
            anchors { left: parent.left; leftMargin: pill.pad
                      verticalCenter: parent.verticalCenter }
            spacing: 10

            // THE COVER, and the button that opens spoot. It is the biggest,
            // most obvious thing on the pill and it already means "the track",
            // so it is the one that takes you to it.
            Item {
                width: pill.artSize; height: pill.artSize
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    anchors.fill: parent
                    radius: 4
                    color: dock.theme.selectedBg
                    visible: cover.status !== Image.Ready
                    // spoot's own mark where a cover would be. With nothing
                    // playing this square is the whole of what the pill is
                    // offering, so an empty box would read as a picture that
                    // failed to load rather than as the button it is.
                    Text {
                        anchors.centerIn: parent
                        text: dock.theme.glyphSpoot
                        color: dock.theme.foreground
                        opacity: 0.5
                        font { family: dock.theme.fontFamily
                               pointSize: dock.theme.fontSize + 4 }
                    }
                }
                Image {
                    id: cover
                    anchors.fill: parent
                    source: dock.art.length ? dock.theme.fileUrl(dock.art) : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: dock.openRequested()
                }
            }

            Item {
                width: Math.min(260, Math.max(150, Math.max(nameText.implicitWidth,
                                                            byText.implicitWidth)))
                height: pill.artSize
                anchors.verticalCenter: parent.verticalCenter
                // ...AND ITS MARKS. One Text rather than a Row of two: the marks
                // belong to the title, so they travel with it and elide with it,
                // which is the same rule the now-playing strip follows.
                Text {
                    id: nameText
                    anchors { left: parent.left; right: parent.right; bottom: parent.verticalCenter }
                    text: dock.hasTrack
                          ? (dock.playback.name || "")
                            + (dock.icons.length ? "  " + dock.icons : "")
                          : "Nothing playing"
                    elide: Text.ElideRight
                    color: dock.theme.playing
                    font { family: dock.theme.fontFamily; pointSize: dock.theme.fontSize; bold: true }
                }
                Text {
                    id: byText
                    anchors { left: parent.left; right: parent.right; top: parent.verticalCenter
                              topMargin: 2 }
                    text: dock.hasTrack ? (dock.playback.artists || "")
                                      : "press play, or open spoot"
                    elide: Text.ElideRight
                    color: dock.theme.foreground
                    opacity: 0.7
                    font { family: dock.theme.fontFamily; pointSize: dock.theme.fontSize - 1 }
                }
            }

            // AIR BEFORE THE CONTROLS. What is playing and what drives it are two
            // different things on one pill, and the row's own spacing put them as
            // close together as the cover is to the name.
            Item { width: 12; height: 1 }

            // --- transport --------------------------------------------------
            Row {
                anchors.verticalCenter: parent.verticalCenter
                // EVEN, because every key is now the same square (see GlyphKey's
                // `side`). The play button used to be six pixels wider than the
                // two beside it, so the gaps either side of it were not the gaps
                // between the others and the group read as off-centre.
                spacing: 2
                GlyphKey { theme: dock.theme; glyph: dock.theme.glyphPrev
                          onTapped: dock.controlRequested("prev", 0) }
                GlyphKey { theme: dock.theme; big: true
                          glyph: dock.playback.playing === true ? dock.theme.glyphPause
                                                                : dock.theme.glyphPlay
                          onTapped: dock.controlRequested("playpause", 0) }
                GlyphKey { theme: dock.theme; glyph: dock.theme.glyphNext
                          onTapped: dock.controlRequested("next", 0) }
            }

            // A hairline between what plays the music and what changes how it
            // plays -- the same seam the now-playing strip draws with spacing.
            Rectangle {
                width: 1; height: pill.artSize - 14
                anchors.verticalCenter: parent.verticalCenter
                color: dock.theme.borderCol
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                GlyphKey {
                    theme: dock.theme
                    glyph: dock.playback.shuffle === true ? dock.theme.glyphShuffleOn
                                                          : dock.theme.glyphShuffleOff
                    lit: dock.playback.shuffle === true
                    onTapped: dock.controlRequested("shuffle", 0)
                }
                GlyphKey {
                    theme: dock.theme
                    glyph: dock.playback.repeat_ === "track" ? dock.theme.glyphRepeatTrack
                         : dock.playback.repeat_ === "context" ? dock.theme.glyphRepeatAll
                         : dock.theme.glyphRepeatOff
                    lit: (dock.playback.repeat_ || "off") !== "off"
                    onTapped: dock.controlRequested("repeat", 0)
                }
                // THE ONE VERB THE PILL WAS MISSING. Everything else on it drives
                // the music; this is the only thing that changes what you keep,
                // and it was the reach-for-the-menu case the dock exists to avoid.
                // ...AND ONLY WHILE THERE IS SOMETHING TO SAVE. Every other key
                // on the pill drives the player and still means something with
                // nothing loaded; a heart with no track under it is a button
                // whose only possible answer is "nothing playing".
                GlyphKey {
                    theme: dock.theme
                    // A Row skips an invisible child outright, so the gap goes
                    // with the key rather than being left behind as a hole.
                    visible: dock.hasTrack
                    glyph: dock.liked ? dock.theme.glyphLiked : dock.theme.glyphUnliked
                    lit: dock.liked
                    onTapped: dock.controlRequested("like", 0)
                }
                GlyphKey {
                    theme: dock.theme
                    glyph: dock.theme.glyphSpoot
                    onTapped: dock.openRequested()
                }
            }
        }

        // --- the progress line ---------------------------------------------
        // Along the pill's own bottom edge rather than as a bar of its own: it
        // costs no height, it reads as the pill filling up, and it is the same
        // idea the now-playing strip draws at full size.
        Rectangle {
            id: rule
            // INSIDE THE CURVE. `clip` on the pill is a bounding-box clip and not
            // a rounded one, so a line run to both edges carried straight on
            // through the corner radius and out past the shape -- two green nubs
            // where the pill turns. Inset by the radius, it starts and stops where
            // the pill's own bottom edge is actually straight.
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                      leftMargin: parent.radius; rightMargin: parent.radius
                      bottomMargin: 1 }
            height: 2
            radius: 1
            color: "transparent"
            Rectangle {
                width: Math.round(rule.width * dock.progress)
                height: parent.height
                radius: parent.radius
                color: dock.theme.playing
            }
            // CLICK TO SEEK, worked out as a NUDGE. The player takes a signed
            // number of seconds and nothing else, and the position is already
            // being interpolated here for the fill -- so where you clicked minus
            // where it is IS the argument, and no absolute seek has to exist.
            MouseArea {
                anchors { fill: parent; topMargin: -8 }
                cursorShape: Qt.PointingHandCursor
                onClicked: function (m) {
                    var dur = dock.playback.duration || 0
                    if (dur <= 0) return
                    var want = Math.max(0, Math.min(1, m.x / rule.width)) * dur
                    dock.controlRequested("seek", Math.round((want - dock.positionMs) / 1000))
                }
            }
        }
    }
}
