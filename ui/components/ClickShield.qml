// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// WHAT AN OVERLAY PUTS BETWEEN ITSELF AND EVERYTHING UNDERNEATH IT.
//
// Named for what it catches, not for what it looks like: it draws nothing at
// all. `ctxScrim` is the DARKENING behind a card, which is a different job.
//
// Four things in spoot float over the menu -- the card layer, a details sheet,
// the image viewer, and the modal barrier over the panel -- and every one of them
// needs the same five lines: span the parent, take all three buttons, eat the
// wheel, and treat a click on nothing as a dismissal.
//
// THEY WERE FIVE LINES EACH, COPIED. That is not a tidiness complaint: the sheet
// simply did not have them, so a click on an opaque details sheet fell straight
// through to the card underneath and ran whichever verb it landed on. A copied
// block is a block a new overlay can forget, and one did.
//
// A MouseArea rather than a wrapper around one, so a caller can still set
// `enabled` and `hoverEnabled` on it directly -- the modal barrier needs both,
// and hover is the half that leaks: a MouseArea taking BUTTONS still lets pointer
// moves through to whatever is beneath, which is how the trail went on lighting up
// under a card.
//
// `dismisses` is the one thing they differ on. A click on the layer AROUND a card
// means "put it away"; a click on the sheet itself is a click on what you are
// reading and must do nothing at all -- but it must still be swallowed, or it
// reaches the rows behind.
import QtQuick

MouseArea {
    id: shield
    property bool dismisses: true
    // Reported rather than acted on: this file knows nothing about what is open.
    signal dismissed()

    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: if (shield.dismisses) shield.dismissed()
    onWheel: function (e) { e.accepted = true }
}
