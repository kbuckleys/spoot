// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// THE WHEEL, for every list in spoot.
//
// A Flickable moves a fixed, small amount per notch and this Qt exposes no
// property for it (wheelDeceleration is not on GridView here), so the wheel is
// answered directly. Both list shapes want the identical rule and neither is the
// other's parent, so it lives here rather than as two copies that drift -- the
// same reason Mark.js does.
//
// HOW FAR A NOTCH GOES is Theme.wheelStep, in viewports, and it is a THEME token
// rather than a number in here: it is the one thing about scrolling anybody ever
// wants to change, and hunting for it in a shared .js is the reason it had been
// changed twice already by editing this comment's own constant.
//
// A row at a time is a gesture you repeat twenty times to cross a list of six
// hundred. Past one viewport the notch lands you somewhere with nothing in common
// with what you were reading, so the default trades a little of that orientation
// for reach and the token is where to argue with it.
//
// Snapped to whole rows either way, so a notch never leaves half a row cut off at
// the edge.
.pragma library

// WHICH WAY THIS ONE SCROLLS.
//
// ASKED OF THE RANGE, not of the flow. A RowList is a GridView filling
// top-to-bottom, so what Qt does with its content -- one tall column or a row of
// short ones -- depends on the cell size against the viewport, and reading the
// flow property to guess was how a list ended up being scrolled on an axis with
// no travel in it. Vertical wins where both could move, because a list of rows is
// a vertical thing whatever the layout underneath is doing.
function axis(view) {
    if (view.contentHeight > view.height + 1) return "y"
    if (view.contentWidth > view.width + 1) return "x"
    return ""
}

// Returns true when the notch was used, so a caller can leave the event alone
// when there is nothing to scroll and let it fall through to whatever is behind.
function wheel(view, e, anim, step) {
    var ax = axis(view)
    if (ax === "") return false
    var horiz = ax === "x"
    var prop = horiz ? "contentX" : "contentY"
    var span = horiz ? view.width : view.height
    var cell = horiz ? view.cellWidth : view.cellHeight
    var max = Math.max(0, (horiz ? view.contentWidth : view.contentHeight) - span)
    if (max <= 0 || cell <= 0) return false
    // EITHER AXIS ON THE MOUSE, TOO. A plain wheel reports on y; a tilt wheel
    // reports sideways. Whichever one moved, moves the list.
    var d = e.angleDelta.y !== 0 ? e.angleDelta.y : e.angleDelta.x
    if (d === 0) return false
    // At least one whole row, whatever the token says -- a step small enough to
    // round to zero would be a wheel that does nothing.
    var by = Math.max(cell, Math.round(span * (step || 0.8) / cell) * cell)
    // FROM WHERE IT IS GOING, not from where it is. Spinning the wheel restarts
    // this mid-flight, and adding to the live value would fold each notch into
    // the distance the last one had not travelled yet -- so a fast spin moved
    // barely further than a slow one.
    var from = (anim.running && anim.target === view && anim.property === prop)
               ? anim.to : view[prop]
    if (view.flicking) view.cancelFlick()
    anim.target = view
    anim.property = prop
    anim.to = Math.max(0, Math.min(max, from + (d > 0 ? -by : by)))
    anim.restart()
    return true
}
