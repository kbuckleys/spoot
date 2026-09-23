// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// THE MATCHED CHARACTERS, and only those.
//
// A filter narrows the list; this says WHY each row survived. Without it a
// filtered list is a list you have to read again to see what it did -- with a
// long title the matching part is rarely the part your eye lands on. rofi drew
// this and spoot lost it in the port, because rofi's matcher and its renderer
// were the same program and here they are two.
//
// A .js library rather than a function on the shell, because both views need it
// and neither can see the other's file: a list row and a tile caption are the
// same question asked twice, and answering it twice is how the two drift.
//
// Works on markup as well as on plain text, since a row can be either -- an
// action menu dims the verbs it cannot offer, and a dimmed row is still
// filterable. Tags and entities are walked OVER rather than matched into:
// typing "span" must light up the word in a title, never the markup drawing it.
.pragma library

// The characters Qt's rich text would eat, made literal. Same three the
// breadcrumb escapes, and for the same reason -- a track called "<3" is a title,
// not a tag.
function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

var _ENT = {"&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " "}

// What `s` READS as, plus, for every character of that reading, where it starts
// in `s` and how many source characters it spends -- one for an ordinary
// character, several for an entity. That map is the whole trick: the match is
// found in the reading and the markup is inserted into the source.
function _plain(s) {
    var text = "", at = [], len = []
    for (var i = 0; i < s.length; i++) {
        var c = s.charAt(i)
        if (c === "<") {
            var gt = s.indexOf(">", i)
            i = (gt < 0) ? s.length : gt
            continue
        }
        if (c === "&") {
            var sc = s.indexOf(";", i)
            if (sc > i && sc - i <= 8) {
                var e = s.substring(i, sc + 1)
                // An entity nobody here decodes still occupies exactly one
                // character of the reading, or every offset after it would be
                // wrong. U+FFFD is a character no filter can contain, so it
                // holds the place without ever matching.
                text += (_ENT[e] !== undefined) ? _ENT[e] : "�"
                at.push(i); len.push(sc - i + 1)
                i = sc
                continue
            }
        }
        text += c; at.push(i); len.push(1)
    }
    return {text: text, at: at, len: len}
}

// `s` marked up so that every occurrence of `needle` wears `color` and a heavier
// weight. `markup` says whether `s` already carries markup; when it does not it
// is escaped first, so the answer is markup either way and the caller must draw
// it as Text.StyledText.
//
// EVERY occurrence, not the first: the matcher is a substring test, and a word
// you typed because you were looking for it can appear more than once in the
// same row.
function mark(s, markup, needle, color) {
    var src = markup ? String(s) : esc(s)
    if (!needle || !needle.length) return src
    var p = _plain(src)
    var hay = p.text.toLowerCase()
    var f = String(needle).toLowerCase()
    var i = hay.indexOf(f)
    if (i < 0) return src
    // Gathered before any markup is written, so that matches which TOUCH become
    // one run: "Seek" narrowed by "e" is a marked pair, not two spans that
    // happen to abut.
    var runs = []
    while (i >= 0) {
        var last = i + f.length - 1
        var a = p.at[i]
        var b = p.at[last] + p.len[last]
        var n = runs.length
        if (n > 0 && runs[n - 1][1] === a) runs[n - 1][1] = b
        else runs.push([a, b])
        i = hay.indexOf(f, last + 1)
    }
    var open = '<b><font color="' + color + '">'
    var close = '</font></b>'
    var out = "", cut = 0
    for (var k = 0; k < runs.length; k++) {
        out += src.substring(cut, runs[k][0])
               + open + src.substring(runs[k][0], runs[k][1]) + close
        cut = runs[k][1]
    }
    return out + src.substring(cut)
}
