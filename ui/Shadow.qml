// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// THE DROP SHADOW UNDER A FLOATING THING, once.
//
// Everything in spoot that floats -- the panel, the context card, the prompt,
// the sheet, the art viewer, the listening pill -- casts this. Each of them had,
// or was about to have, its own copy of the same twenty lines, and one of them
// being tuned and the others not is how the panel and the card came to cast
// different shadows while the comments in both claimed they matched. The numbers
// live in Theme; the machinery lives here.
//
// WHY IT IS NOT A BLUR ON THE OBJECT ITSELF: a blur redistributes what it is
// given, so blurring the object's own outline produces a halo that is darkest
// where the object already covers it and invisible everywhere else. A shadow is
// a BIGGER shape, offset, softened -- see Theme's grow/blur/drop.
//
// ── IT IS A RING, NOT A BLOCK ────────────────────────────────────────────────
// This used to build the shape by hand: a rounded rectangle grown past the
// object, captured through a ShaderEffectSource and blurred with MultiEffect.
// It worked, and it had one flaw that every number in Theme was bent around --
// the shape was FILLED. A filled shadow paints its own interior, and the
// interior is the part lying directly under the object.
//
// Behind something opaque that costs nothing, because the object hides it.
// Behind anything translucent -- which the panel and all three cards are -- it
// reads straight through, the object composites to near solid, and its own
// opacity stops meaning anything. It also put a band of near-solid ink hard
// against the edge that no amount of blur could reach into, which is what read
// as a hard line, and what the old 10/64/14 numbers were an apology for.
//
// So the object's footprint is punched out and what is left is the part that was
// ever meant to be seen: the edge. RectangularShadow draws the falloff -- it is
// Qt's own box-shadow primitive and it takes grow, blur and drop directly, so
// there is no capture and no hand-inflated rectangle any more -- and the mask
// below removes the middle.
//
// ANCHORS ARE FINE HERE, which is worth saying because the same component in the
// quickshell suite pointedly does not use them. There, a fill onto a sibling is
// resolved before the shell has reparented either item into the window's content
// item, Qt refuses it once and never retries, and the shadow sits at zero size.
// That is a quickshell reparenting quirk, not a Qt one: spoot's windows come up
// through LayerShellQt as ordinary QQuickWindows, the sibling is already a
// sibling, and these have always resolved.
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
    // The corner the shadow turns. The panel and both cards are the window
    // radius, so that is the default and no caller has to say it.
    //
    // It is also what the HOLE is cut to, which makes it load-bearing rather
    // than decorative: a radius smaller than the object's leaves four dark
    // slivers inside its corners, and larger eats into the falloff.
    property real cornerRadius: shade.theme.radius
    // The two things the target does that the shadow has to do with it, passed
    // rather than followed: a scale is a transform, and a transform is not a
    // property an outsider can read off an item.
    property real scaleFactor: 1
    property real fade: 1

    // PADDED BY THE WHOLE REACH. Nothing can paint outside the texture it is
    // handed, and a clipped shadow comes out as a hard rectangle -- which is
    // exactly how this first went wrong.
    readonly property int pad: shade.theme.shadowPad
    // The target's own box, in this item's coordinates. Both the shadow and the
    // hole are cut from it, so they are written down once.
    readonly property real boxW: Math.max(0, shade.width - shade.pad * 2)
    readonly property real boxH: Math.max(0, shade.height - shade.pad * 2)

    anchors.fill: shade.target
    anchors.margins: -shade.pad
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

    Item {
        id: ring
        anchors.fill: parent

        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: hole
            // The stencil marks the object. INVERTED, so what it marks is what
            // goes away and the edge around it is what stays.
            maskInverted: true
            maskThresholdMin: 0.5
        }

        RectangularShadow {
            x: shade.pad
            y: shade.pad
            width: shade.boxW
            height: shade.boxH
            radius: shade.cornerRadius
            blur: shade.theme.shadowBlur
            spread: shade.theme.shadowGrow
            offset: Qt.vector2d(0, shade.theme.shadowDrop)
            // The strength is the item's opacity above, so that one gate still
            // turns every shadow in spoot off at once.
            color: "black"
        }
    }

    // The object's footprint. Never drawn -- it is a texture the mask reads,
    // which is why it carries a layer of its own and why `visible: false` does
    // not stop it existing.
    Item {
        id: hole
        anchors.fill: parent
        visible: false
        layer.enabled: true

        Rectangle {
            x: shade.pad
            y: shade.pad
            width: shade.boxW
            height: shade.boxH
            radius: shade.cornerRadius
            color: "white"
        }
    }
}
