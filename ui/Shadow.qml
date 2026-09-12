// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// THE DROP SHADOW UNDER A FLOATING THING, once.
//
// Three things in spoot float -- the panel, the context card, the art viewer --
// and each of them had, or was about to have, its own copy of the same twenty
// lines: a rectangle grown past the object, captured, blurred, and drawn behind
// it. One of them being tuned and the others not is how the panel and the card
// came to cast different shadows while the comments in both claimed they
// matched. The numbers live in Theme; the machinery lives here.
//
// WHY IT IS NOT A BLUR ON THE OBJECT ITSELF: a blur redistributes what it is
// given, so blurring the object's own outline produces a halo that is darkest
// where the object already covers it and invisible everywhere else. A shadow is
// a BIGGER shape, offset, softened -- see Theme's grow/blur/drop.
import QtQuick
import QtQuick.Effects

Item {
    id: shade
    property var theme
    // WHAT THIS IS THE SHADOW OF, and a SIBLING of it rather than a child. A
    // child would be simpler -- it would inherit the target's transform and
    // opacity for free -- and it does not work for two of the three: the art
    // viewer clips (its listening rings overrun the card on purpose), so it
    // would clip its own shadow away to nothing.
    property Item target
    // The corner the shadow turns before it is inflated. The panel and both
    // cards are the window radius, so that is the default and no caller has to
    // say it.
    property real cornerRadius: shade.theme.radius
    // The two things the target does that the shadow has to do with it, passed
    // rather than followed: a scale is a transform, and a transform is not a
    // property an outsider can read off an item.
    property real scaleFactor: 1
    property real fade: 1

    // PADDED BY THE WHOLE REACH. The blur cannot paint outside the texture it is
    // handed, and a clipped blur comes out as a hard rectangle -- which is
    // exactly how this first went wrong.
    anchors.fill: shade.target
    anchors.margins: -shade.theme.shadowPad
    visible: !!shade.target && shade.target.visible
             && shade.theme.shadows && shade.fade > 0
    opacity: shade.theme.shadowAlpha * shade.fade
    // Concentric with the target, so growing about its own centre is growing
    // about the target's.
    transform: Scale {
        origin.x: shade.width / 2
        origin.y: shade.height / 2
        xScale: shade.scaleFactor
        yScale: shade.scaleFactor
    }

    Rectangle {
        id: shape
        anchors.fill: parent
        anchors.margins: shade.theme.shadowPad - shade.theme.shadowGrow
        anchors.topMargin: shade.theme.shadowPad - shade.theme.shadowGrow
                           + shade.theme.shadowDrop
        anchors.bottomMargin: shade.theme.shadowPad - shade.theme.shadowGrow
                              - shade.theme.shadowDrop
        // The corner grows with the shape, or an inflated rectangle would have
        // sharper corners than the thing casting it.
        radius: shade.cornerRadius + shade.theme.shadowGrow
        color: "black"
    }
    ShaderEffectSource {
        id: shot
        anchors.fill: parent
        sourceItem: shape
        sourceRect: Qt.rect(-(shade.theme.shadowPad - shade.theme.shadowGrow),
                            -(shade.theme.shadowPad - shade.theme.shadowGrow),
                            shape.width + (shade.theme.shadowPad - shade.theme.shadowGrow) * 2,
                            shape.height + (shade.theme.shadowPad - shade.theme.shadowGrow) * 2)
        hideSource: true
        live: true
        visible: false
    }
    MultiEffect {
        anchors.fill: parent
        source: shot
        blurEnabled: true
        blur: 1.0
        blurMax: shade.theme.shadowBlur
        autoPaddingEnabled: false
    }
}
