// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// THE KEYMAP. One file, no rebuild to change it, and no ceiling.
//
// rofi allowed nineteen custom bindings and needed a whole subprocess (bsmon) to
// notice a Backspace, because a dmenu process cannot report a key it does not
// own. None of that applies now: every key below is just a key, several do
// different things depending on what is on screen, and adding one costs a line.
//
// `app` is the shell (main.qml). Everything routes through its functions rather
// than reaching into views, so a binding cannot depend on which view is loaded.
import QtQuick

Item {
    id: keys
    property var app
    anchors.fill: parent
    focus: true

    // Bindings that carry a printable key must come after the typing branch, or
    // filtering would never see those characters.
    Keys.onPressed: function (e) {
        // A sheet is modal while it is up: anything dismisses it, and nothing
        // behind it moves. Checked before every other binding for that reason.
        if (app.sheet.length || app.sheetRows.length || app.artPath.length) {
            app.closeOverlay()
            e.accepted = true
            return
        }
        var mod = e.modifiers
        var ctrl = (mod & Qt.ControlModifier) !== 0
        var alt = (mod & Qt.AltModifier) !== 0
        // Transport on ctrl+arrows, since alt+arrows now walk the trail.
        if (ctrl && !alt) {
            if (e.key === Qt.Key_Right) { app.control("next"); e.accepted = true; return }
            if (e.key === Qt.Key_Left)  { app.control("prev"); e.accepted = true; return }
        }
        var shift = (mod & Qt.ShiftModifier) !== 0

        // --- Alt: global jumps and transport -------------------------------
        // Checked first precisely because these ARE printable keys; typing must
        // not swallow Alt+L.
        if (alt && !ctrl) {
            switch (e.key) {
            case Qt.Key_Space:    app.openMain();                     break
            case Qt.Key_L:        app.openView("liked");              break
            case Qt.Key_P:        app.openView("recently-played");    break
            case Qt.Key_T:        app.openView("top-tracks");         break
            case Qt.Key_Q:        app.openView("your-queue");         break
            case Qt.Key_S:        app.control("shuffle");             break
            case Qt.Key_R:        app.control("repeat");              break
            case Qt.Key_Equal:
            case Qt.Key_Plus:     app.control("seek", 10);            break
            case Qt.Key_Minus:    app.control("seek", -10);           break
            // The trail, walked. Non-destructive both ways -- Backspace is what
            // removes a step. Transport moved to ctrl+arrows below, because
            // walking where you have been is the more common thing to want and
            // deserves the easier key.
            case Qt.Key_Right:    app.trailForward();                 break
            case Qt.Key_Left:     app.trailBack();                    break
            // THE CURRENT-TRACK KEYS. Each is a view named for what it opens,
            // so the binding carries no knowledge of what the engine does with
            // it -- see Util.SERVE_VIEWS.
            case Qt.Key_Y:        app.openView("lyrics-current");     break
            case Qt.Key_A:        app.openView("art-current");        break
            case Qt.Key_E:        app.openView("seek-current");       break
            case Qt.Key_C:        app.jumpToPlaying();                break
            // PASTE AND GO, which is what Util.KEYBINDS has always said this
            // key is for: "open spotify web link". It was wired to the
            // opposite -- copying the playing track's URL -- which every
            // action menu already offers as a row.
            case Qt.Key_G:        app.openView("open-link");          break
            case Qt.Key_Return:
            case Qt.Key_Enter:    app.openView("actions-current");    break
            case Qt.Key_Delete:   app.goHome();                       break
            // Alt+1..9 jumps to a step in the trail. rofi allowed nineteen
            // custom bindings in total, so spending nine on the breadcrumb was
            // never on the table; here they cost nothing.
            case Qt.Key_1: case Qt.Key_2: case Qt.Key_3:
            case Qt.Key_4: case Qt.Key_5: case Qt.Key_6:
            case Qt.Key_7: case Qt.Key_8: case Qt.Key_9:
                app.jumpToCrumb(e.key - Qt.Key_1 + 1)
                break
            default: return
            }
            e.accepted = true
            return
        }

        // --- typing filters --------------------------------------------------
        // SPACE and DEL are both excluded, and for the same reason: this test
        // asks whether a key is printable, and these two answer to something
        // else first.
        //
        // Space is transport. It types only once there is something to type
        // INTO -- see Key_Space below -- and this branch was claiming it before
        // that case ever ran, so the key that plays and pauses only ever
        // inserted a space. Qt gives Key_Delete a text of "\u007F", likewise
        // greater than a space, so it was swallowed too: Delete appeared to do
        // nothing, and what it actually did was append a control character to
        // the filter. Backspace never had the problem -- its "\b" is below space.
        if (!ctrl && e.text.length === 1 && e.text > " " && e.text !== "\u007F") {
            app.setFilter(app.filter + e.text)
            e.accepted = true
            return
        }

        switch (e.key) {
        case Qt.Key_Escape:
            // Double duty: clear what you typed, and only leave when there is
            // nothing left to clear. A pending prompt is abandoned first --
            // Escape out of "New Playlist" must not also close spoot.
            if (app.promptFor.length) app.cancelPrompt()
            else if (app.filter.length) app.setFilter("")
            else app.dismiss()
            break
        case Qt.Key_Backspace:
            // Two different things, because typing is two different things.
            //
            // In the search box -- or a prompt asking for a name -- what you
            // have typed is TEXT you are composing, so this deletes a character:
            // losing a whole query to one keystroke is nobody's intent.
            //
            // Everywhere else it is a FILTER, which is one thing rather than a
            // string being built, so one press clears it whole and the next goes
            // back a level. Search RESULTS follow this rule, not the one above:
            // once the query is answered they are an ordinary list.
            if (app.composing && app.filter.length) app.setFilter(app.filter.slice(0, -1))
            else if (app.filter.length) app.setFilter("")
            else app.goBack()
            break
        case Qt.Key_Return:
        case Qt.Key_Enter:
            // Shift+Return is the action menu everywhere in the rofi build, and
            // it is one flag on the same path step rather than a second route.
            app.activateCurrent(shift)
            break
        case Qt.Key_Space:
            // Transport first, typing second -- and never the first character.
            // A leading space is not something anyone means to type, so an empty
            // field leaves the key free to be what it is everywhere else. Once
            // there is a word to separate, it separates it.
            if (app.filter.length) app.setFilter(app.filter + " ")
            else app.control("playpause")
            break
        // Tab is the menu's own when the menu claims it, and the trail menu
        // everywhere else -- see app.canTab.
        case Qt.Key_Tab:     app.tabHere();          break
        case Qt.Key_Delete:  app.deleteEntry();      break
        case Qt.Key_Home:    app.moveTo(0);          break
        case Qt.Key_End:     app.moveTo(-1);         break
        // Arrows are handled HERE rather than left to the view: with the view
        // unfocused (see main.qml) nothing else would move the cursor, and this
        // keeps grid and list navigation described in one place.
        case Qt.Key_Down:      app.move(0, 1);  break
        case Qt.Key_Up:        app.move(0, -1); break
        case Qt.Key_Right:     app.move(1, 0);  break
        case Qt.Key_Left:      app.move(-1, 0); break
        case Qt.Key_PageDown:  app.page(1);     break
        case Qt.Key_PageUp:    app.page(-1);    break
        default:
            return
        }
        e.accepted = true
    }
}
