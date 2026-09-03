// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// A ROUNDED CORNER ON SOMETHING THAT CANNOT HAVE ONE.
//
// Qt Quick rounds a Rectangle and nothing else. Everything else that has to sit
// inside spoot's frame -- a cover, a list, a picture -- is masked into the shape
// instead, and that takes three declarations: a rounded rectangle, a
// ShaderEffectSource turning it into a texture, and a MultiEffect on the item
// being masked. Two of the three are the same every time, so they live here and
// a caller writes only the third:
//
//     CornerMask { id: foot; width: thing.width; height: thing.height
//                  bottomLeft: 12; bottomRight: 12 }
//     ...
//     layer.enabled: true
//     layer.effect: MultiEffect { maskEnabled: true; maskSource: foot.texture }
//
// PER CORNER, because that is the question spoot actually asks: a panel rounds
// all four, the thing at the foot of it rounds two, and the item in the middle
// rounds none. Zero everywhere by default, which is a mask that changes nothing.
//
// NOT `visible: false` on this item, however much it looks like it should be. An
// invisible parent makes its children invisible in Qt Quick, and a
// ShaderEffectSource cannot capture an item that is not being drawn -- the
// texture comes back empty and the thing being masked disappears. It draws
// nothing as it stands: the shape is hidden by `hideSource` and the source
// itself is invisible.
import QtQuick

Item {
    id: mask
    property int topLeft: 0
    property int topRight: 0
    property int bottomLeft: 0
    property int bottomRight: 0
    // What a MultiEffect samples -- pass it as `maskSource`.
    property alias texture: shot

    Rectangle {
        id: shape
        anchors.fill: parent
        // WHITE IS "KEEP". MultiEffect reads the mask's alpha, and a fully opaque
        // white rectangle with rounded corners is exactly "everything inside the
        // shape, nothing outside it".
        color: "white"
        topLeftRadius: mask.topLeft
        topRightRadius: mask.topRight
        bottomLeftRadius: mask.bottomLeft
        bottomRightRadius: mask.bottomRight
    }
    ShaderEffectSource {
        id: shot
        anchors.fill: parent
        sourceItem: shape
        hideSource: true
        live: true
        visible: false
    }
}
