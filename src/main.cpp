// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// spoot Spotify Client ~ Part of the ZENWORKS Suite
// https://github.com/kbuckleys/

// spoot -- the host.
//
// Deliberately dumb and deliberately small. It does exactly four things:
//   1. spawns the Lua engine and pumps newline-delimited JSON both ways,
//   2. exposes that pipe to QML as one object with one method and two signals,
//   3. anchors the window to the bottom of the screen through wlr-layer-shell,
//   4. loads the UI from disk at runtime.
//
// Everything else -- every view, every pixel, every keybinding -- lives in
// ui/*.qml and needs no rebuild to change. This file should change about twice
// a year.

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QProcess>
#include <QJsonDocument>
#include <QJsonObject>
#include <QFileInfo>
#include <QDir>
#include <QUrl>
#include <functional>
#include <QTimer>
#include <QScreen>
#include <QFileSystemWatcher>
#include <QDirIterator>
#include <QLocalServer>
#include <QLocalSocket>
#include <QProcess>
#include <QDateTime>
#include <QThread>
#include <mutex>
#include <condition_variable>
#include <QQueue>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QNetworkReply>
#include <QEventLoop>
#include <QBuffer>
#include <QFile>
#include <QVector>
#include <QSet>
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusReply>
#include <QDBusObjectPath>
#include <QDBusMetaType>
#include <QDBusConnectionInterface>
#include <QClipboard>
#include <lua.hpp>
#include <csignal>
#include <cstdlib>
#include <cstdio>
#include <unistd.h>
#include <fcntl.h>
#include <LayerShellQt/Shell>
#include <LayerShellQt/Window>

// WHAT "THE PLAYER CHANGED" IS, on the bus, in one place. Two signals, because
// one of them cannot report the other: PropertiesChanged tells you about a
// player that already exists, and a player that has only just appeared -- a
// spotifyd started after we were -- announces itself as a name gaining an owner
// and nothing else.
//
// Two things listen for this pair: the host's Watchers, which posts a request
// into the running engine, and MprisWatch, which blocks a standalone `--daemon`
// until it fires. They do different things about it; what it IS belongs here.
static void connectPlayerSignals(QDBusConnection bus, QObject *receiver,
                                 const char *propsSlot, const char *nameSlot) {
    // Any sender: the match is on the object path every MPRIS player exposes,
    // because which bus name spotifyd holds is not known here and changes when
    // it restarts.
    bus.connect(QString(), QStringLiteral("/org/mpris/MediaPlayer2"),
                QStringLiteral("org.freedesktop.DBus.Properties"),
                QStringLiteral("PropertiesChanged"), receiver, propsSlot);
    bus.connect(QStringLiteral("org.freedesktop.DBus"),
                QStringLiteral("/org/freedesktop/DBus"),
                QStringLiteral("org.freedesktop.DBus"),
                QStringLiteral("NameOwnerChanged"), receiver, nameSlot);
}

// IS THIS SIGNAL WORTH WAKING FOR. Also shared, for the same reason: both
// listeners drop the same things -- a property change that is not Metadata (a
// pause carries no track), and a name that is not a player or is leaving rather
// than arriving.
static bool playerPropsInteresting(const QString &iface, const QVariantMap &changed) {
    return iface == QLatin1String("org.mpris.MediaPlayer2.Player")
        && changed.contains(QStringLiteral("Metadata"));
}
static bool playerNameInteresting(const QString &name, const QString &owner) {
    return name.startsWith(QStringLiteral("org.mpris.MediaPlayer2.")) && !owner.isEmpty();
}

// ── THE TRANSPORTS ───────────────────────────────────────────────────────────
// The half of the `spoot` table that is not about serving: HTTP and MPRIS. It
// is its own class because the request state is no longer the only Lua state in
// the process -- every background job gets one too (see JobRunner), and each
// needs its own QNetworkAccessManager and its own bus connection, created and
// used on the thread that owns it and destroyed with it.
//
// Nothing in here is shared between instances, which is what lets a job run
// beside the engine without a lock between them.
// ONE WAIT ON THE BUS. A standalone `spoot --daemon` has no window and no event
// loop of its own; it asks for a snapshot, then asks to be told when to ask
// again. That is this: a nested loop that runs until the player changes or the
// timeout expires, which is precisely what the `playerctl --follow` pipe was
// doing with a process.
class MprisWatch : public QObject {
    Q_OBJECT
public:
    // True if a change arrived; false if the wait simply ran out.
    bool wait(QDBusConnection bus, int ms) {
        if (!m_armed) {
            connectPlayerSignals(bus, this,
                                 SLOT(onProps(QString, QVariantMap, QStringList)),
                                 SLOT(onName(QString, QString, QString)));
            m_armed = true;
        }
        // A change that landed between two waits is still a change. Without this
        // the daemon would miss anything that arrived while it was writing the
        // last snapshot out.
        if (m_fired) { m_fired = false; return true; }
        QTimer clock;
        clock.setSingleShot(true);
        connect(&clock, &QTimer::timeout, &m_loop, &QEventLoop::quit);
        clock.start(ms);
        m_loop.exec();
        const bool fired = m_fired;
        m_fired = false;
        return fired;
    }

private slots:
    void onProps(const QString &iface, const QVariantMap &changed, const QStringList &) {
        if (!playerPropsInteresting(iface, changed)) return;
        m_fired = true;
        m_loop.quit();
    }
    void onName(const QString &name, const QString &, const QString &owner) {
        if (!playerNameInteresting(name, owner)) return;
        m_fired = true;
        m_loop.quit();
    }

private:
    QEventLoop m_loop;
    bool m_armed = false;
    bool m_fired = false;
};

class Natives {
public:
    ~Natives() {
        delete m_watch;
        delete m_nam;
        if (m_bus) {
            const QString name = m_bus->name();
            delete m_bus;
            QDBusConnection::disconnectFromBus(name);
        }
    }

    // Pushes (or extends) the global `spoot` table with the transports. The
    // caller adds whatever else its role needs -- the request state adds emit
    // and next; a job state has neither, and the Lua side reads `role` to tell
    // which kind of host it is running under.
    void install(lua_State *L, const char *role, const QByteArray &busName) {
        m_owner = QThread::currentThread();
        m_busName = busName;
        lua_getglobal(L, "spoot");
        if (!lua_istable(L, -1)) { lua_pop(L, 1); lua_newtable(L); }
        lua_pushlightuserdata(L, this);
        lua_pushcclosure(L, &Natives::l_http, 1);
        lua_setfield(L, -2, "http");
        lua_pushlightuserdata(L, this);
        lua_pushcclosure(L, &Natives::l_mpris, 1);
        lua_setfield(L, -2, "mpris");
        lua_pushlightuserdata(L, this);
        lua_pushcclosure(L, &Natives::l_notify, 1);
        lua_setfield(L, -2, "notify");
        lua_pushcclosure(L, &Natives::l_sleep, 0);
        lua_setfield(L, -2, "sleep");
        // THE CLIPBOARD IS THE GUI THREAD'S, and only a GUI application has one.
        // A `spoot --doctor` on a terminal is a QCoreApplication with no display
        // and no clipboard at all, so the shim is simply absent there and the Lua
        // takes its wl-clipboard branch -- which is what it did everywhere until
        // a moment ago.
        if (qobject_cast<QGuiApplication *>(qApp)) {
            lua_pushlightuserdata(L, this);
            lua_pushcclosure(L, &Natives::l_clip, 1);
            lua_setfield(L, -2, "clip");
        }
        lua_pushstring(L, role);
        lua_setfield(L, -2, "role");
        // WHERE WE ARE. Util.spawn_self forks `lua engine/spoot.lua --flag` when
        // there is no host; with one, the binary can run the flag itself, so the
        // fallback forks this instead and the lua interpreter stops being needed
        // at runtime at all.
        const QByteArray exe = QCoreApplication::applicationFilePath().toUtf8();
        lua_pushlstring(L, exe.constData(), size_t(exe.size()));
        lua_setfield(L, -2, "exe");
        lua_setglobal(L, "spoot");
    }

private:
    static Natives *self(lua_State *L) {
        return static_cast<Natives *>(lua_touserdata(L, lua_upvalueindex(1)));
    }

    // ONE REQUEST, ON THIS THREAD. Util.http describes what it wants; this is
    // the native half of that.
    //
    // The win is connection reuse: curl paid a fresh connect and TLS handshake
    // per request -- measured at ~105ms against Spotify -- where one long-lived
    // QNetworkAccessManager keeps the connection and speaks HTTP/2 over it.
    //
    // It BLOCKS the worker, deliberately, on a nested event loop. That is safe
    // here precisely because the worker runs no loop of its own: nothing else is
    // ever posted to this thread, so the only events the nested loop can see are
    // this reply's. The GUI thread is untouched throughout and keeps drawing.
    static int l_http(lua_State *L) {
        Natives *w = self(L);
        Q_ASSERT(QThread::currentThread() == w->m_owner);
        luaL_checktype(L, 1, LUA_TTABLE);

        lua_getfield(L, 1, "jobs");
        const bool batch = lua_istable(L, -1);
        lua_pop(L, 1);
        if (batch) return l_http_batch(L);

        const QByteArray url    = field(L, 1, "url");
        QByteArray method       = field(L, 1, "method");
        if (method.isEmpty()) method = "GET";
        const QByteArray body   = field(L, 1, "body");
        lua_getfield(L, 1, "timeout");
        const int timeoutMs = int(luaL_optnumber(L, -1, 10) * 1000);
        lua_pop(L, 1);
        // `compressed` is read and deliberately ignored. Qt already asks for gzip
        // and decompresses the reply transparently -- but only while IT owns the
        // header. Setting Accept-Encoding by hand takes that over and hands the
        // caller raw gzip bytes, which json.decode cannot read: every search came
        // back empty. The flag stays in the request table because the curl branch
        // still needs it.
        QNetworkRequest req{QUrl(QString::fromUtf8(url))};
        lua_getfield(L, 1, "headers");
        if (lua_istable(L, -1)) {
            const lua_Integer n = luaL_len(L, -1);
            for (lua_Integer i = 1; i <= n; ++i) {
                lua_rawgeti(L, -1, i);
                const QByteArray h = QByteArray(lua_tostring(L, -1) ? lua_tostring(L, -1) : "");
                lua_pop(L, 1);
                const int c = h.indexOf(':');
                if (c > 0) req.setRawHeader(h.left(c).trimmed(), h.mid(c + 1).trimmed());
            }
        }
        lua_pop(L, 1);

        if (!w->m_nam) w->m_nam = new QNetworkAccessManager();
        // A BODYLESS POST STILL HAS A BODY: an empty one. Handed a null device,
        // sendCustomRequest sends no Content-Length at all -- and Spotify answers
        // 400 to a POST that does not say how long its body is. That is the whole
        // of "can't add to queue": /me/player/queue is the one endpoint spoot
        // reaches with a POST and nothing to send, and it failed every time here
        // while succeeding instantly under SPOOT_FORCE_CURL, which sends
        // Content-Length: 0 for exactly this case. (Util.api_write's `len0` flag
        // is the curl side of the same question; this is the native side, and it
        // needs no flag because an empty buffer IS the answer.)
        //
        // GET and HEAD are the two that must NOT be given one -- a body on those
        // is meaningless and Qt is right to refuse it. DELETE gets one, because
        // spoot sends DELETE with a body (removing tracks from a playlist).
        //
        // ON THE HEAP, PARENTED TO THE REPLY, because Qt reads the device while
        // the request is in flight and `bg` below returns before that. A stack
        // buffer was fine while only bodied requests got one -- none of those
        // are backgrounded -- and became a use-after-free the moment every
        // POST/PUT got one: a shuffle toggle is fire-and-forget, so the frame
        // holding the buffer was gone before Qt read it, and the engine
        // segfaulted a few requests later. As a child of the reply it dies with
        // it on both paths, and neither has to remember to free it.
        QBuffer *buf = nullptr;
        if (method != "GET" && method != "HEAD") {
            buf = new QBuffer();
            buf->setData(body);
            buf->open(QIODevice::ReadOnly);
        }
        QNetworkReply *rep = w->m_nam->sendCustomRequest(req, method, buf);
        if (buf) buf->setParent(rep);

        // FIRE AND FORGET. The caller has already committed to the new state
        // locally -- a shuffle or repeat toggle -- and must not pay a round trip
        // for a frame. Nothing waits; the reply cleans itself up.
        lua_getfield(L, 1, "bg");
        const bool bg = lua_toboolean(L, -1);
        lua_pop(L, 1);
        if (bg) {
            QObject::connect(rep, &QNetworkReply::finished, rep, &QObject::deleteLater);
            lua_newtable(L);
            lua_pushinteger(L, 0); lua_setfield(L, -2, "code");
            lua_pushliteral(L, ""); lua_setfield(L, -2, "body");
            lua_pushliteral(L, ""); lua_setfield(L, -2, "headers");
            return 1;
        }

        QEventLoop loop;
        QTimer clock;
        clock.setSingleShot(true);
        QObject::connect(rep, &QNetworkReply::finished, &loop, &QEventLoop::quit);
        QObject::connect(&clock, &QTimer::timeout, rep, &QNetworkReply::abort);
        clock.start(timeoutMs);
        loop.exec();

        const int code = rep->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray out = rep->readAll();
        // Rebuilt in curl's -D shape, because the one caller that reads them is
        // looking for Retry-After off a 429 with a pattern match.
        QByteArray heads;
        for (const auto &p : rep->rawHeaderPairs())
            heads += p.first + ": " + p.second + "\r\n";
        rep->deleteLater();

        lua_newtable(L);
        lua_pushinteger(L, code);                              lua_setfield(L, -2, "code");
        lua_pushlstring(L, out.constData(), size_t(out.size()));   lua_setfield(L, -2, "body");
        lua_pushlstring(L, heads.constData(), size_t(heads.size())); lua_setfield(L, -2, "headers");
        return 1;
    }

    // MANY AT ONCE, one connection. The batch form of the same call: art
    // covers, library pages, the search prefetch. curl did this with
    // `-Z --parallel-max`, which was already one process and already reused the
    // connection -- so this is process hygiene rather than latency, and it also
    // gets HTTP/2 multiplexing over a single socket for free.
    //
    // Results are collected AFTER the loop, never inside the finished handler.
    // A handler that writes into locals of this frame would still be armed on a
    // reply that outlived a timeout, and would then scribble on a dead stack.
    static int l_http_batch(lua_State *L) {
        Natives *w = self(L);
        Q_ASSERT(QThread::currentThread() == w->m_owner);
        if (!w->m_nam) w->m_nam = new QNetworkAccessManager();

        QList<QByteArray> heads;
        lua_getfield(L, 1, "headers");
        if (lua_istable(L, -1)) {
            const lua_Integer hn = luaL_len(L, -1);
            for (lua_Integer i = 1; i <= hn; ++i) {
                lua_rawgeti(L, -1, i);
                if (const char *h = lua_tostring(L, -1)) heads << QByteArray(h);
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);

        lua_getfield(L, 1, "timeout");
        const int timeoutMs = int(luaL_optnumber(L, -1, 10) * 1000);
        lua_pop(L, 1);

        QVector<QNetworkReply *> reps;
        QVector<QString> outs;
        lua_getfield(L, 1, "jobs");
        const lua_Integer n = luaL_len(L, -1);
        int pending = 0;
        QEventLoop loop;
        for (lua_Integer i = 1; i <= n; ++i) {
            lua_rawgeti(L, -1, i);
            const QByteArray u = field(L, -1, "url");
            const QByteArray o = field(L, -1, "out");
            lua_pop(L, 1);
            if (u.isEmpty()) continue;
            QNetworkRequest req{QUrl(QString::fromUtf8(u))};
            for (const QByteArray &h : heads) {
                const int c = h.indexOf(':');
                if (c > 0) req.setRawHeader(h.left(c).trimmed(), h.mid(c + 1).trimmed());
            }
            QNetworkReply *rep = w->m_nam->get(req);
            reps << rep;
            outs << QString::fromUtf8(o);
            ++pending;
            QObject::connect(rep, &QNetworkReply::finished, &loop,
                             [&pending, &loop] { if (--pending == 0) loop.quit(); });
        }
        lua_pop(L, 1);

        if (pending > 0) {
            QTimer clock;
            clock.setSingleShot(true);
            QObject::connect(&clock, &QTimer::timeout, &loop, &QEventLoop::quit);
            clock.start(timeoutMs);
            loop.exec();
        }

        lua_newtable(L);
        for (int i = 0; i < reps.size(); ++i) {
            QNetworkReply *rep = reps[i];
            QObject::disconnect(rep, nullptr, nullptr, nullptr);
            if (!rep->isFinished()) rep->abort();
            const int code = rep->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            const QByteArray body = rep->readAll();
            rep->deleteLater();
            // NOTHING IS WRITTEN FOR A FAILED FETCH. curl's -f suppressed the
            // error body; writing one here would leave a file that looks like a
            // cover and decodes as an apology.
            qint64 wrote = 0;
            if (code >= 200 && code < 300 && !outs[i].isEmpty()) {
                QFile f(outs[i]);
                if (f.open(QIODevice::WriteOnly)) wrote = f.write(body);
            }
            lua_newtable(L);
            lua_pushinteger(L, code);  lua_setfield(L, -2, "code");
            lua_pushinteger(L, wrote); lua_setfield(L, -2, "size");
            lua_setfield(L, -2, outs[i].toUtf8().constData());
        }
        return 1;
    }

    // ── MPRIS ────────────────────────────────────────────────────────────────
    // What `playerctl` was for: one D-Bus round trip on the session bus, which
    // is what that binary did too after 4.7ms of process startup. The connection
    // is the worker's own and is opened once, so a status read -- the most
    // frequent call in the engine, four per skip -- costs the call and nothing
    // else.
    //
    // Player resolution mirrors playerctl's: every org.mpris.MediaPlayer2.* name
    // on the bus, the one whose suffix contains `player` if one was asked for,
    // otherwise the first. The choice is remembered and dropped the moment a
    // call to it fails, which is what happens when spotifyd restarts.
    QString mprisName(const QByteArray &want) {
        const QString hint = QString::fromUtf8(want);
        if (!m_player.isEmpty() && (hint.isEmpty() || m_player.contains(hint)))
            return m_player;
        QDBusReply<QStringList> names = bus().interface()->registeredServiceNames();
        if (!names.isValid()) return QString();
        QString first;
        for (const QString &n : names.value()) {
            if (!n.startsWith(QStringLiteral("org.mpris.MediaPlayer2."))) continue;
            if (first.isEmpty()) first = n;
            if (!hint.isEmpty() && n.mid(23).contains(hint)) { m_player = n; return n; }
        }
        if (!hint.isEmpty()) return QString();
        m_player = first;
        return first;
    }

    QDBusConnection &bus() {
        if (!m_bus) {
            // A named connection of our own rather than the shared sessionBus():
            // it is created on this thread, torn down with it, and never touched
            // by the GUI thread -- the same confinement the QNetworkAccessManager
            // above has.
            m_bus = new QDBusConnection(QDBusConnection::connectToBus(
                QDBusConnection::SessionBus, QString::fromUtf8(m_busName)));
        }
        return *m_bus;
    }

    static void pushMeta(lua_State *L, const QVariantMap &m) {
        auto str = [&](const char *k) {
            const QVariant v = m.value(QString::fromLatin1(k));
            if (v.metaType().id() == QMetaType::QStringList)
                return v.toStringList().join(QStringLiteral(", "));
            if (v.metaType().id() == qMetaTypeId<QDBusObjectPath>())
                return v.value<QDBusObjectPath>().path();
            return v.toString();
        };
        lua_newtable(L);
        auto set = [&](const char *field, const QString &v) {
            const QByteArray b = v.toUtf8();
            lua_pushlstring(L, b.constData(), b.size());
            lua_setfield(L, -2, field);
        };
        set("title",   str("xesam:title"));
        set("artist",  str("xesam:artist"));
        set("album",   str("xesam:album"));
        set("art",     str("mpris:artUrl"));
        set("trackid", str("mpris:trackid"));
        // Microseconds on the wire, as playerctl's {{mpris:length}} also gave.
        lua_pushnumber(L, double(m.value(QStringLiteral("mpris:length")).toLongLong()));
        lua_setfield(L, -2, "length");
    }

    // ── NOTIFICATIONS ────────────────────────────────────────────────────────
    // `notify-send` is a process that connects to this bus, sends one method
    // call and exits. This is the method call. It runs on job states as well as
    // the request state, which matters because the one notification spoot raises
    // in normal use -- the track change -- is raised by a job.
    static int l_notify(lua_State *L) {
        Natives *w = self(L);
        Q_ASSERT(QThread::currentThread() == w->m_owner);
        luaL_checktype(L, 1, LUA_TTABLE);
        const QString title = QString::fromUtf8(field(L, 1, "title"));
        const QString body  = QString::fromUtf8(field(L, 1, "body"));
        const QString icon  = QString::fromUtf8(field(L, 1, "icon"));
        lua_getfield(L, 1, "urgency");
        const uchar urgency = uchar(luaL_optinteger(L, -1, 1));
        lua_pop(L, 1);

        QDBusInterface notifications(
            QStringLiteral("org.freedesktop.Notifications"),
            QStringLiteral("/org/freedesktop/Notifications"),
            QStringLiteral("org.freedesktop.Notifications"), w->bus());
        QVariantMap hints;
        hints.insert(QStringLiteral("urgency"), QVariant::fromValue(urgency));
        // The argument order is the spec's: app_name, replaces_id, app_icon,
        // summary, body, actions, hints, expire_timeout. -1 leaves the timeout to
        // the daemon, which is what notify-send does when not told otherwise.
        const QDBusMessage r = notifications.call(
            QStringLiteral("Notify"), QStringLiteral("spoot"), uint(0), icon,
            title, body, QStringList(), hints, int(-1));
        lua_pushboolean(L, r.type() != QDBusMessage::ErrorMessage);
        return 1;
    }

    // A WAIT THAT IS NOT A PROCESS. `os.execute("sleep 25")` forks a shell to
    // fork a sleep, twice a minute for as long as the standalone recent-watch
    // runs. This is the same wait with neither.
    //
    // An event loop rather than QThread::sleep so the bus connection underneath
    // it keeps dispatching -- a daemon that went deaf for 25 seconds at a time
    // would miss exactly the signals it exists to hear.
    static int l_sleep(lua_State *L) {
        const double secs = luaL_checknumber(L, 1);
        if (secs <= 0) return 0;
        QEventLoop loop;
        QTimer::singleShot(int(secs * 1000), &loop, &QEventLoop::quit);
        loop.exec();
        return 0;
    }

    // ── CLIPBOARD ────────────────────────────────────────────────────────────
    // QClipboard belongs to the GUI thread and to nothing else, so the engine's
    // thread hops over and waits. Blocking this way round is safe by the same
    // rule that makes the rest of it safe: the GUI thread never waits on the
    // engine, so the two can never be waiting on each other.
    static int l_clip(lua_State *L) {
        const char *op = luaL_optstring(L, 1, "get");
        const QByteArray text = luaL_optstring(L, 2, "") ? QByteArray(luaL_optstring(L, 2, "")) : QByteArray();
        const bool set = QByteArray(op) == "set";
        QString out;
        auto work = [&] {
            QClipboard *cb = QGuiApplication::clipboard();
            if (!cb) return;
            if (set) cb->setText(QString::fromUtf8(text));
            else out = cb->text();
        };
        if (QThread::currentThread() == qApp->thread()) work();
        else QMetaObject::invokeMethod(qApp, work, Qt::BlockingQueuedConnection);
        if (set) { lua_pushboolean(L, 1); return 1; }
        const QByteArray b = out.toUtf8();
        lua_pushlstring(L, b.constData(), size_t(b.size()));
        return 1;
    }

    static int l_mpris(lua_State *L) {
        Natives *w = self(L);
        Q_ASSERT(QThread::currentThread() == w->m_owner);
        luaL_checktype(L, 1, LUA_TTABLE);
        const QByteArray op   = field(L, 1, "op");
        const QByteArray want = field(L, 1, "player");
        lua_getfield(L, 1, "value");
        double value = lua_tonumber(L, -1);
        lua_pop(L, 1);
        // A watch's argument is a duration; every other op's is a position or a
        // level. Same field, read under the name the caller would expect.
        lua_getfield(L, 1, "timeout");
        if (lua_isnumber(L, -1)) value = lua_tonumber(L, -1);
        lua_pop(L, 1);

        // BEFORE the player is resolved, deliberately. Waiting for one to appear
        // is half of what a watch is for, and `mprisName` answers nothing when
        // spotifyd has not started yet.
        if (op == "watch") {
            if (!w->m_watch) w->m_watch = new MprisWatch();
            const bool fired = w->m_watch->wait(w->bus(), int(value > 0 ? value * 1000 : 60000));
            lua_newtable(L);
            lua_pushboolean(L, 1);     lua_setfield(L, -2, "ok");
            lua_pushboolean(L, fired); lua_setfield(L, -2, "value");
            return 1;
        }

        const QString name = w->mprisName(want);
        auto fail = [&]() { lua_newtable(L); lua_pushboolean(L, 0);
                            lua_setfield(L, -2, "ok"); return 1; };
        if (name.isEmpty()) return fail();

        QDBusInterface player(name, QStringLiteral("/org/mpris/MediaPlayer2"),
                              QStringLiteral("org.mpris.MediaPlayer2.Player"), w->bus());
        QDBusInterface props(name, QStringLiteral("/org/mpris/MediaPlayer2"),
                             QStringLiteral("org.freedesktop.DBus.Properties"), w->bus());
        const QString IFACE = QStringLiteral("org.mpris.MediaPlayer2.Player");
        auto get = [&](const char *prop) {
            return props.call(QStringLiteral("Get"), IFACE, QString::fromLatin1(prop));
        };
        // A call that failed is a player that went away -- spotifyd restarting,
        // most often. Forgetting the name here is what makes the next call
        // re-resolve instead of talking to a bus name nobody owns.
        auto ok = [&](const QDBusMessage &m) {
            if (m.type() == QDBusMessage::ErrorMessage) { w->m_player.clear(); return false; }
            return true;
        };

        lua_newtable(L);
        if (op == "status") {
            const QDBusMessage m = get("PlaybackStatus");
            if (!ok(m)) { lua_pushboolean(L, 0); lua_setfield(L, -2, "ok"); return 1; }
            const QByteArray v = m.arguments().value(0).value<QDBusVariant>()
                                  .variant().toString().toUtf8();
            lua_pushlstring(L, v.constData(), v.size()); lua_setfield(L, -2, "value");
        } else if (op == "position") {
            const QDBusMessage m = get("Position");
            if (!ok(m)) { lua_pushboolean(L, 0); lua_setfield(L, -2, "ok"); return 1; }
            lua_pushnumber(L, double(m.arguments().value(0).value<QDBusVariant>()
                                      .variant().toLongLong()) / 1e6);
            lua_setfield(L, -2, "value");
        } else if (op == "volume") {
            const QDBusMessage m = get("Volume");
            if (!ok(m)) { lua_pushboolean(L, 0); lua_setfield(L, -2, "ok"); return 1; }
            lua_pushnumber(L, m.arguments().value(0).value<QDBusVariant>().variant().toDouble());
            lua_setfield(L, -2, "value");
        } else if (op == "metadata") {
            const QDBusMessage m = get("Metadata");
            if (!ok(m)) { lua_pushboolean(L, 0); lua_setfield(L, -2, "ok"); return 1; }
            QVariantMap meta;
            const QDBusArgument arg = m.arguments().value(0).value<QDBusVariant>()
                                       .variant().value<QDBusArgument>();
            arg >> meta;
            pushMeta(L, meta);
            lua_setfield(L, -2, "value");
        } else if (op == "setvol") {
            const QDBusMessage m = props.call(QStringLiteral("Set"), IFACE,
                QStringLiteral("Volume"), QVariant::fromValue(QDBusVariant(value)));
            if (!ok(m)) { lua_pushboolean(L, 0); lua_setfield(L, -2, "ok"); return 1; }
        } else if (op == "setpos") {
            // SetPosition is absolute and needs the track it applies to, so the
            // id is read first -- seeking a track that has since changed is what
            // the argument exists to prevent.
            const QDBusMessage id = get("Metadata");
            if (!ok(id)) { lua_pushboolean(L, 0); lua_setfield(L, -2, "ok"); return 1; }
            QVariantMap meta;
            const QDBusArgument arg = id.arguments().value(0).value<QDBusVariant>()
                                       .variant().value<QDBusArgument>();
            arg >> meta;
            const QVariant tid = meta.value(QStringLiteral("mpris:trackid"));
            const QDBusObjectPath path = tid.canConvert<QDBusObjectPath>()
                ? tid.value<QDBusObjectPath>() : QDBusObjectPath(tid.toString());
            if (!ok(player.call(QStringLiteral("SetPosition"),
                                QVariant::fromValue(path), qint64(value * 1e6)))) {
                lua_pushboolean(L, 0); lua_setfield(L, -2, "ok"); return 1;
            }
        } else if (op == "seek") {
            // Relative, signed, microseconds -- what playerctl's "10+"/"10-" is.
            if (!ok(player.call(QStringLiteral("Seek"), qint64(value * 1e6)))) {
                lua_pushboolean(L, 0); lua_setfield(L, -2, "ok"); return 1;
            }
        } else {
            static const QHash<QByteArray, QString> METHOD{
                {"play", QStringLiteral("Play")}, {"pause", QStringLiteral("Pause")},
                {"play-pause", QStringLiteral("PlayPause")},
                {"next", QStringLiteral("Next")}, {"previous", QStringLiteral("Previous")}};
            const QString method = METHOD.value(op);
            if (method.isEmpty() || !ok(player.call(method))) {
                lua_pushboolean(L, 0); lua_setfield(L, -2, "ok"); return 1;
            }
        }
        lua_pushboolean(L, 1); lua_setfield(L, -2, "ok");
        return 1;
    }

    static QByteArray field(lua_State *L, int idx, const char *k) {
        lua_getfield(L, idx, k);
        size_t n = 0;
        const char *v = lua_tolstring(L, -1, &n);
        QByteArray out(v ? QByteArray(v, int(n)) : QByteArray());
        lua_pop(L, 1);
        return out;
    }

    QNetworkAccessManager *m_nam = nullptr;
    QDBusConnection *m_bus = nullptr;
    QString m_player;
    QByteArray m_busName;
    QThread *m_owner = nullptr;
    MprisWatch *m_watch = nullptr;
};

class JobPool;

static void installJob(lua_State *L, JobPool *pool);

// ── BACKGROUND JOBS ──────────────────────────────────────────────────────────
// What `nohup lua spoot.lua --prefetch-art-batch &` was. Five jobs use this --
// artwork prefetch, the playlist index, revalidation, lyrics, the notification
// helper -- and each one used to be a process: a fork, an exec, and a fresh
// 13,400-line script parsed from disk before it could do anything.
//
// A JOB IS STILL COMPLETELY ISOLATED. It gets a lua_State of its own, which
// shares no memory whatsoever with the engine's -- separate heap, separate
// globals, separate everything, the same isolation the fork had -- and it is
// DISPOSED of when the job ends, so its memory leaves with it exactly as a
// process' did. What it does not get is the fork.
//
// The state has no `emit` and no `next`: a job does not serve. It reads its
// arguments from `arg` and takes the same entry point the process took, which
// is why not one line of any job's code had to change.
class JobRunner : public QObject {
    Q_OBJECT
public:
    JobRunner(QString script, QStringList args, JobPool *pool, QByteArray busName)
        : m_script(std::move(script)), m_args(std::move(args)), m_pool(pool),
          m_busName(std::move(busName)) {}

public slots:
    void run() {
        lua_State *L = luaL_newstate();
        luaL_openlibs(L);
        m_nat.install(L, "job", m_busName);
        installJob(L, m_pool);

        // arg[0] is the script and arg[1..] the job's own arguments -- the same
        // table the interpreter would have built for the command line this
        // replaces.
        const QByteArray script = m_script.toUtf8();
        lua_newtable(L);
        lua_pushstring(L, script.constData()); lua_rawseti(L, -2, 0);
        for (int i = 0; i < m_args.size(); ++i) {
            const QByteArray a = m_args.at(i).toUtf8();
            lua_pushlstring(L, a.constData(), size_t(a.size()));
            lua_rawseti(L, -2, i + 1);
        }
        lua_setglobal(L, "arg");

        // EVERY JOB ENDS IN os.exit(0), which in a process meant "I am done" and
        // here would mean "kill spoot". It is replaced with an error carrying a
        // sentinel, so the same statement unwinds this state and nothing else.
        luaL_dostring(L, "os.exit = function() error('\1spoot-job-done', 0) end");

        if (luaL_dofile(L, script.constData()) != LUA_OK) {
            const char *m = lua_tostring(L, -1);
            const QByteArray err = m ? QByteArray(m) : QByteArray();
            if (err != "\1spoot-job-done")
                qWarning("spoot: job %s: %s", qPrintable(m_args.value(0)), err.constData());
        }
        lua_close(L);
        emit finished();
    }

signals:
    void finished();

private:
    Natives m_nat;
    QString m_script;
    QStringList m_args;
    JobPool *m_pool;
    QByteArray m_busName;
};

// The queue in front of those states. Submission is callable from any thread --
// the engine's Lua calls it from the worker -- and the in-flight key set is what
// the pid files used to be: the thing that stops a menu redrawing four times
// from starting four identical prefetches.
class JobPool : public QObject {
    Q_OBJECT
public:
    explicit JobPool(QString script, QObject *parent = nullptr)
        : QObject(parent), m_script(std::move(script)) {}

    ~JobPool() override {
        // Jobs write caches. Cutting one off mid-write is how a half-written
        // json file gets left behind, so they are given a moment to land.
        for (QThread *t : std::as_const(m_threads)) { t->quit(); t->wait(2000); }
    }

    bool busy(const QString &key) {
        std::lock_guard<std::mutex> lk(m_mx);
        return m_keys.contains(key);
    }

    void submit(const QStringList &args, const QString &key) {
        {
            std::lock_guard<std::mutex> lk(m_mx);
            if (!key.isEmpty() && m_keys.contains(key)) return;
            if (!key.isEmpty()) m_keys.insert(key);
            m_queue.enqueue({args, key});
        }
        QMetaObject::invokeMethod(this, &JobPool::pump, Qt::QueuedConnection);
    }

private:
    struct Job { QStringList args; QString key; };

    // AT MOST THREE AT ONCE. Not a resource limit -- each is a thread asleep on
    // a socket most of its life -- but a memory one: every job state loads the
    // whole script, and an unbounded queue of them arriving at once is the one
    // way this costs more than the processes did.
    static constexpr int MAX = 3;

    // EVERYTHING THE OTHER THREAD CAN TOUCH IS READ UNDER THE LOCK. The loop
    // condition used to test m_queue and m_running outside it and only take the
    // lock to dequeue -- so the engine thread could be appending to the very
    // QList this was measuring. The thread sanitizer caught exactly that, which
    // is the first thing it found that was worth finding.
    void pump() {
        for (;;) {
            Job job;
            {
                std::lock_guard<std::mutex> lk(m_mx);
                if (m_running >= MAX || m_queue.isEmpty()) return;
                job = m_queue.dequeue();
                ++m_running;
            }
            auto *thread = new QThread(this);
            auto *runner = new JobRunner(m_script, job.args, this,
                                         QByteArray("spoot-job-") + QByteArray::number(++m_seq));
            runner->moveToThread(thread);
            m_threads.insert(thread);
            connect(thread, &QThread::started, runner, &JobRunner::run);
            connect(runner, &JobRunner::finished, this, [this, thread, runner, key = job.key] {
                {
                    std::lock_guard<std::mutex> lk(m_mx);
                    m_keys.remove(key);
                    --m_running;
                }
                runner->deleteLater();
                thread->quit();
                pump();
            });
            connect(thread, &QThread::finished, this, [this, thread] {
                m_threads.remove(thread);
                thread->deleteLater();
            });
            thread->start();
        }
    }

    QString m_script;
    std::mutex m_mx;              // see LuaWorker: the sanitizer can read this one
    QSet<QString> m_keys;
    QQueue<Job> m_queue;
    QSet<QThread *> m_threads;
    int m_running = 0;
    quint64 m_seq = 0;
};

// spoot.job / spoot.job_busy: what Util.spawn_self and its pid-file check reach
// when a host is present. Registered on the request state and on job states
// alike, so a job that queues another behaves the way the fork did.
static void installJob(lua_State *L, JobPool *pool) {
    lua_getglobal(L, "spoot");
    if (!lua_istable(L, -1)) { lua_pop(L, 1); return; }
    lua_pushlightuserdata(L, pool);
    lua_pushcclosure(L, [](lua_State *L) -> int {
        auto *pool = static_cast<JobPool *>(lua_touserdata(L, lua_upvalueindex(1)));
        luaL_checktype(L, 1, LUA_TTABLE);
        QStringList args;
        const lua_Integer n = luaL_len(L, 1);
        for (lua_Integer i = 1; i <= n; ++i) {
            lua_rawgeti(L, 1, i);
            args << QString::fromUtf8(lua_tostring(L, -1) ? lua_tostring(L, -1) : "");
            lua_pop(L, 1);
        }
        pool->submit(args, QString::fromUtf8(luaL_optstring(L, 2, "")));
        return 0;
    }, 1);
    lua_setfield(L, -2, "job");
    lua_pushlightuserdata(L, pool);
    lua_pushcclosure(L, [](lua_State *L) -> int {
        auto *pool = static_cast<JobPool *>(lua_touserdata(L, lua_upvalueindex(1)));
        lua_pushboolean(L, pool->busy(QString::fromUtf8(luaL_checkstring(L, 1))));
        return 1;
    }, 1);
    lua_setfield(L, -2, "job_busy");
    lua_pop(L, 1);
}

// ---------------------------------------------------------------------------
// THE ENGINE, IN THIS PROCESS.
//
// It used to be `lua spoot.lua --serve` on the other end of a pipe. It is the
// same script, unchanged and still read from disk, running on a worker thread
// inside this binary -- so editing engine/spoot.lua still costs a restart and
// not a rebuild.
//
// WHAT CROSSES THE THREAD BOUNDARY IS BYTES. The worker and the GUI thread
// exchange the very ndjson lines they exchanged over the pipe: QByteArray in,
// QByteArray out, never a live object and never a shared structure. That is the
// whole of the concurrency design -- with nothing shared there is nothing to
// race over, and the process boundary's semantics survive its removal.
//
// The worker deliberately runs NO event loop. It blocks inside Lua, and requests
// reach it through a plain mutex and condition variable rather than a queued
// slot -- a queued slot would be delivered by an event loop that is, by
// construction, never running. Replies go the other way as a queued signal,
// which Qt marshals onto the GUI thread for us.
class LuaWorker : public QObject {
    Q_OBJECT
public:
    LuaWorker(QString script, JobPool *pool)
        : m_script(std::move(script)), m_pool(pool) {}

    // Called DIRECTLY from the GUI thread, not as a slot. See above: the worker
    // is asleep in the condition variable, so there is no loop to deliver to.
    // The mutex is what makes this safe, and it is the only lock in the design.
    void post(const QByteArray &line) {
        {
            std::lock_guard<std::mutex> lk(m_mx);
            m_in.enqueue(line);
        }
        m_cv.notify_one();
    }

    void stop() {
        {
            std::lock_guard<std::mutex> lk(m_mx);
            m_stop = true;
        }
        m_cv.notify_all();
    }

public slots:
    void run() {
        lua_State *L = luaL_newstate();
        luaL_openlibs(L);

        // The native side of Util.host: the transports, plus the two functions
        // that make this state the SERVING one -- a line in, a line out.
        m_nat.install(L, "serve", "spoot-engine");
        lua_getglobal(L, "spoot");
        lua_pushlightuserdata(L, this);
        lua_pushcclosure(L, &LuaWorker::l_emit, 1);
        lua_setfield(L, -2, "emit");
        lua_pushlightuserdata(L, this);
        lua_pushcclosure(L, &LuaWorker::l_next, 1);
        lua_setfield(L, -2, "next");
        lua_pop(L, 1);
        installJob(L, m_pool);

        // arg[0] is the script and arg[1] the mode, exactly as the interpreter
        // would set them -- the script dispatches on arg[1], and Util.spawn_self
        // still reads arg[0] to find itself.
        const QByteArray script = m_script.toUtf8();
        lua_newtable(L);
        lua_pushstring(L, script.constData()); lua_rawseti(L, -2, 0);
        lua_pushstring(L, "--serve");          lua_rawseti(L, -2, 1);
        lua_setglobal(L, "arg");

        QString err;
        if (luaL_dofile(L, script.constData()) != LUA_OK) {
            const char *m = lua_tostring(L, -1);
            err = m ? QString::fromUtf8(m) : QStringLiteral("unknown lua error");
        }
        lua_close(L);
        emit finished(err);
    }

signals:
    void line(QByteArray out);
    void finished(QString err);

private:
    static LuaWorker *self(lua_State *L) {
        return static_cast<LuaWorker *>(lua_touserdata(L, lua_upvalueindex(1)));
    }

    // Blocks the worker until there is a request, and answers nil when the host
    // is shutting down -- which is the contract io.lines() has at end of input,
    // so the Lua loop reading it cannot tell the two transports apart.
    static int l_next(lua_State *L) {
        LuaWorker *w = self(L);
        std::unique_lock<std::mutex> lk(w->m_mx);
        w->m_cv.wait(lk, [w] { return !w->m_in.isEmpty() || w->m_stop; });
        if (w->m_in.isEmpty()) { lua_pushnil(L); return 1; }
        const QByteArray line = w->m_in.dequeue();
        lua_pushlstring(L, line.constData(), size_t(line.size()));
        return 1;
    }

    static int l_emit(lua_State *L) {
        size_t n = 0;
        const char *sp = luaL_checklstring(L, 1, &n);
        // A queued connection: Qt copies the QByteArray and delivers it on the
        // GUI thread's loop. Nothing of the worker's escapes.
        emit self(L)->line(QByteArray(sp, int(n)));
        return 0;
    }


    QString m_script;
    // std::mutex rather than QMutex, and the same in JobPool. Not a preference:
    // QMutex synchronises through futexes inside libQt6Core, and a sanitizer
    // build cannot see into an uninstrumented library -- so every correctly
    // locked enqueue/dequeue pair on this queue was reported as a data race,
    // with both accesses shown holding the very mutex that ordered them. Thirty
    // five reports of that, and a real one would have been invisible among them.
    // pthread primitives are understood, so the target can now say something.
    std::mutex m_mx;
    std::condition_variable m_cv;
    QQueue<QByteArray> m_in;
    bool m_stop = false;
    Natives m_nat;
    JobPool *m_pool = nullptr;
};

// The bridge QML talks to. request() sends a command and answers with the id it
// was given; the reply arrives later on response(). Nothing blocks, which is the
// whole point -- a 600ms fetch must never hold a frame.
class Engine : public QObject {
    Q_OBJECT
public:
    explicit Engine(const QString &script, QObject *parent = nullptr)
        : QObject(parent), m_script(script) {
        if (qApp) connect(qApp, &QCoreApplication::aboutToQuit, this, [this] {
            m_stopping = true;
            shutdown();
        });
        spawn();
    }

    ~Engine() override { m_stopping = true; shutdown(); }

    // Returns the request id so a caller can match its own reply.
    Q_INVOKABLE int request(const QString &cmd, const QVariantMap &args = {}) {
        QJsonObject o{{"id", ++m_id}, {"cmd", cmd}};
        if (!args.isEmpty()) o["args"] = QJsonObject::fromVariantMap(args);
        if (m_worker) m_worker->post(QJsonDocument(o).toJson(QJsonDocument::Compact));
        return m_id;
    }

signals:
    void response(int id, bool ok, QVariant data, QString err);
    void event(QString name, QVariant data);

private slots:
    // One ndjson line out of the engine -- the same parse the pipe reader did,
    // minus the buffering, because a signal carries a whole line by construction.
    void onLine(const QByteArray &line) {
        if (line.trimmed().isEmpty()) return;
        const QJsonObject o = QJsonDocument::fromJson(line).object();
        if (o.contains("ev")) {
            // The engine asking to end is not the engine failing.
            if (o.value("ev").toString() == QLatin1String("quit")) m_stopping = true;
            emit event(o.value("ev").toString(), o.toVariantMap());
        } else {
            emit response(o.value("id").toInt(), o.value("ok").toBool(),
                          o.value("data").toVariant(), o.value("err").toString());
        }
    }

    // THE ENGINE DYING WAS SILENT. Nothing watched for it, so a crash left the
    // window up holding a dead pipe: every request after it went nowhere and the
    // UI waited forever for a reply that could not come. That is not crash
    // isolation, it is a zombie -- and the fix is cheap, because spoot already
    // restores its session and its trail, so a respawn lands back where you were.
    void died(const QString &err) {
        if (m_stopping) return;
        if (!err.isEmpty()) qWarning("spoot: engine error: %s", qPrintable(err));
        // A CRASH LOOP MUST NOT BE ANSWERED WITH AN INFINITE ONE. Five deaths in
        // ten seconds means it cannot start at all -- a syntax error, a missing
        // dependency -- and retrying forever would bury the reason.
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        if (now - m_firstDeath > 10000) { m_firstDeath = now; m_deaths = 0; }
        if (++m_deaths > 5) { emit event(QStringLiteral("engine-lost"), QVariantMap{}); return; }
        spawn();
        // Announced AFTER the respawn, so whatever the UI does about it -- drop
        // the replies it is waiting on, ask for its menu again -- is said to a
        // live engine.
        emit event(QStringLiteral("engine-restarted"), QVariantMap{});
    }

private:
    void spawn() {
        m_thread = new QThread(this);
        m_worker = new LuaWorker(m_script, &m_pool);
        m_worker->moveToThread(m_thread);
        connect(m_thread, &QThread::started, m_worker, &LuaWorker::run);
        connect(m_worker, &LuaWorker::line, this, &Engine::onLine, Qt::QueuedConnection);
        connect(m_worker, &LuaWorker::finished, this, &Engine::died, Qt::QueuedConnection);
        // The worker owns its own teardown once its loop has returned.
        connect(m_worker, &LuaWorker::finished, m_thread, &QThread::quit);
        connect(m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
        connect(m_thread, &QThread::finished, m_thread, &QObject::deleteLater);
        m_thread->start();
    }

    void shutdown() {
        if (!m_worker) return;
        m_worker->stop();
        if (m_thread) m_thread->wait(2000);
        m_worker = nullptr;
        m_thread = nullptr;
    }

    QString m_script;
    // Owned by the Engine so it outlives every worker restart: a job in flight
    // when the engine is respawned is not a job that should be cancelled.
    JobPool m_pool{m_script};
    QThread *m_thread = nullptr;
    LuaWorker *m_worker = nullptr;
    int m_id = 0;
    bool m_stopping = false;
    int m_deaths = 0;
    qint64 m_firstDeath = 0;
};

// Keeps spoot resident. Escape hides the surface instead of ending the process,
// and a second `spoot` hands its request to the first one over a socket and
// exits -- so the Lua engine, the token, and every warm cache survive between
// summons. A cold start pays for the engine, the API handshake and the first
// draw; a warm one pays for nothing.
class Shell : public QObject {
    Q_OBJECT
public:
    // CONSTRUCTED BEFORE THE WINDOW EXISTS, on purpose. main.qml binds
    // `Connections { target: Shell }`, and a context property added AFTER
    // qml.load() is a name that did not exist when that binding was compiled --
    // so whether the binding ever picks it up is a race, and losing it means the
    // reveal signal reaches nothing and spoot comes up as a mapped surface with
    // nothing drawn on it. Existing before the load removes the race; the window
    // arrives later, through attach().
    Shell() = default;

    void attach(QWindow *w, std::function<QScreen *()> pick) {
        m_win = w;
        m_pick = std::move(pick);
    }

    // Re-picks the monitor EVERY time. The pointer moves between summons, and a
    // resident process that always reappeared where it first opened would be
    // worse than a cold start that got it right.
    Q_INVOKABLE void reveal() {
        if (!m_win) return;
        if (auto *ls = LayerShellQt::Window::get(m_win)) ls->setScreen(m_pick());
        m_win->show();
        m_win->requestActivate();
        emit revealed();
    }
    Q_INVOKABLE void conceal() { if (m_win) m_win->hide(); }

    // `spoot --listen` ARRIVING AT A SHELL THAT IS ALREADY RUNNING. The flag used
    // to be delivered by re-setting the `startView` context property, which only
    // main.qml's bootstrap ever read -- and bootstrap runs once, at load. So the
    // flag worked exactly once per process, on a cold start, and every later
    // press of the keybind just revealed the window wherever it had been left.
    //
    // A signal instead, because this is an EVENT: it happened again, and "the
    // value is still listen" cannot say that.
    void askListen() { emit listen(); }

signals:
    void revealed();
    void listen();

private:
    QWindow *m_win = nullptr;
    std::function<QScreen *()> m_pick;
};

// ── THE TWO WATCHERS ─────────────────────────────────────────────────────────
// What `spoot.lua --daemon` and `spoot.lua --recent-watch` were: one process
// each, permanently resident, so that a track change could raise a notification
// and Recently Played could fill while the menu was closed. Both were loops
// waiting on something -- an MPRIS stream and a 25-second sleep -- which is
// exactly what an event loop this process already runs does for free.
//
// Neither does any work here. They notice, and post a request; the engine does
// the same thing it did before, on the same code, reached through Util.SERVE.
// That keeps the watching in the host, where the event sources are, and the
// behaviour in the engine, where the rest of spoot is.
class Watchers : public QObject {
    Q_OBJECT
public:
    Watchers(Engine *engine, QObject *parent = nullptr)
        : QObject(parent), m_engine(engine) {
        connectPlayerSignals(QDBusConnection::sessionBus(), this,
                             SLOT(onProps(QString, QVariantMap, QStringList)),
                             SLOT(onName(QString, QString, QString)));

        // Recently Played, on the same 25s the standalone watcher slept for.
        auto *recent = new QTimer(this);
        recent->setInterval(25000);
        connect(recent, &QTimer::timeout, this, [this] { m_engine->request(QStringLiteral("recent-tick")); });
        recent->start();
        // The first pass of each, once the engine is up: the loops both did
        // their work before their first sleep, and a session that starts with
        // something already playing depends on it.
        QTimer::singleShot(2500, this, [this] {
            m_engine->request(QStringLiteral("daemon-snap"));
            m_engine->request(QStringLiteral("recent-tick"));
        });
    }

private slots:
    void onProps(const QString &iface, const QVariantMap &changed, const QStringList &) {
        if (!playerPropsInteresting(iface, changed)) return;
        m_engine->request(QStringLiteral("daemon-snap"));
    }
    void onName(const QString &name, const QString &, const QString &owner) {
        if (!playerNameInteresting(name, owner)) return;
        m_engine->request(QStringLiteral("daemon-snap"));
    }

private:
    Engine *m_engine;
};

// ── SURVIVING A FAULT ────────────────────────────────────────────────────────
// The engine used to be a process of its own, so a fault in it left the window
// up and useless -- which is why Engine already respawns it. Now that everything
// is in here, a fault takes the window with it, and the honest answer is not to
// pretend that cannot happen but to come straight back.
//
// spoot restores its session, its trail and its scroll position on a cold start,
// so an execv of ourselves lands on the menu that was open. What the user sees is
// a blink. That is strictly better than what a separated engine gave: there, a
// crash in the UI half was simply the end.
//
// THREE STRIKES. A fault that happens every time -- a bad build, a missing
// library -- must not become an infinite respawn that buries its own reason, so
// the generation rides in the environment and the fourth start does not install
// the handler at all. It resets after a minute of staying up, because a crash an
// hour into a session is a new crash, not a continuing one.
namespace crashguard {

static char **s_argv = nullptr;
static char   s_gen[32] = "SPOOT_REEXEC=0";
// RESOLVED ONCE, HERE, rather than exec'ing /proc/self/exe directly: the kernel
// names a process after the path it was exec'd from, so exec'ing the symlink
// brought spoot back as `exe`. It ran perfectly and was invisible to everything
// that looks for it by name -- pgrep, pkill, and a process monitor with the
// human reading it.
static char   s_exe[4096];

// Async-signal-safe and nothing else: reset the disposition, say one line, and
// exec. If the exec fails there is nothing left to try, so re-raise and take the
// default action -- a core file, as though none of this were here.
static void onFatal(int sig) {
    struct sigaction dfl {};
    dfl.sa_handler = SIG_DFL;
    sigaction(sig, &dfl, nullptr);
    static const char msg[] = "spoot: fatal signal -- restarting\n";
    ssize_t unused = write(STDERR_FILENO, msg, sizeof(msg) - 1);
    (void)unused;
    execv(s_exe, s_argv);
    raise(sig);
}

static void install(char **argv) {
    const char *prev = getenv("SPOOT_REEXEC");
    const int gen = prev ? atoi(prev) : 0;
    if (gen >= 3) return;
    // readlink here and not in the handler: it is safe to call there, but there
    // is no reason to do work in a handler that can be done now.
    const ssize_t n = readlink("/proc/self/exe", s_exe, sizeof s_exe - 1);
    if (n <= 0) return;
    s_exe[n] = '\0';
    snprintf(s_gen, sizeof s_gen, "SPOOT_REEXEC=%d", gen + 1);
    putenv(s_gen);
    s_argv = argv;
    struct sigaction sa {};
    sa.sa_handler = onFatal;
    sigemptyset(&sa.sa_mask);
    // NODEFER and RESETHAND so a fault raised while handling one is not caught
    // again by the same handler, which is how a crash handler becomes a hang.
    sa.sa_flags = SA_NODEFER | SA_RESETHAND;
    for (int sig : {SIGSEGV, SIGBUS, SIGABRT, SIGFPE, SIGILL}) sigaction(sig, &sa, nullptr);
}

// putenv keeps the pointer, not a copy, so rewriting the buffer is the update.
static void clearGeneration() { snprintf(s_gen, sizeof s_gen, "SPOOT_REEXEC=0"); }

} // namespace crashguard

// ── THE COMMAND LINE ─────────────────────────────────────────────────────────
// `spoot --doctor`, `spoot --revalidate liked`, `spoot --serve`: the same twelve
// entry points the script has always had, run by this binary rather than by a
// `lua` on the PATH. They get the transports -- so a --doctor makes its requests
// the same way the app does -- and nothing else: no window, no QML, and
// QCoreApplication rather than QGuiApplication, because a terminal has no
// display and asking for one would fail before the first line ran.
//
// NOT the job pool. Its queue is pumped by an event loop, and a one-shot command
// never starts one, so a job handed to it would sit there and never run. Without
// it Util.spawn_self forks -- which is exactly what these commands did before,
// and now forks THIS binary rather than an interpreter.
//
// Deliberately ahead of the single-instance socket: a resident spoot must not
// answer `--doctor` by opening its window, which is what asking it first did.
static int runCli(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    app.setApplicationName("spoot");
    const QString root = QFileInfo(QCoreApplication::applicationDirPath()).dir().absolutePath();
    const QByteArray script = (root + "/engine/spoot.lua").toUtf8();

    Natives nat;
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    nat.install(L, "cli", "spoot-cli");

    lua_newtable(L);
    lua_pushstring(L, script.constData()); lua_rawseti(L, -2, 0);
    for (int i = 1; i < argc; ++i) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");

    int rc = 0;
    if (luaL_dofile(L, script.constData()) != LUA_OK) {
        const char *m = lua_tostring(L, -1);
        fprintf(stderr, "spoot: %s\n", m ? m : "unknown lua error");
        rc = 1;
    }
    lua_close(L);
    return rc;
}

int main(int argc, char *argv[]) {
    // A FLAG THAT IS NOT --listen is a command, not a summon. --listen opens the
    // listener in the UI and belongs to the path below with everything else that
    // draws; the rest are the script's own entry points. An unrecognised one
    // exits 2, which is what the script has always answered.
    {
        const QByteArray first = argc > 1 ? QByteArray(argv[1]) : QByteArray();
        if (first.startsWith("--") && first != "--listen") return runCli(argc, argv);
    }
    // Before Qt, so a fault in its own initialisation is covered too.
    crashguard::install(argv);

    // Qt 6.5+ needs no useLayerShell() call: asking LayerShellQt::Window::get()
    // for a window below is what turns its surface into a layer surface. ZENON
    // anchors south, and Wayland forbids a client positioning itself, so that
    // call is the only reason the 1:1 look is reachable at all.
    QGuiApplication app(argc, argv);
    app.setApplicationName("spoot");

    // If one is already resident, hand it the request and leave. Done before the
    // engine is spawned or any QML is loaded, so a second invocation costs a
    // socket round trip rather than a process.
    const QString sockName = QStringLiteral("spoot-%1").arg(qEnvironmentVariable("USER", "u"));
    {
        QLocalSocket probe;
        probe.connectToServer(sockName);
        if (probe.waitForConnected(200)) {
            probe.write(app.arguments().contains("--listen") ? "listen\n" : "show\n");
            probe.waitForBytesWritten(200);
            return 0;
        }
    }

    // Run from anywhere: resolve the project root from the binary, so `spoot`
    // works as a keybind target without a working directory.
    const QString root = QFileInfo(QCoreApplication::applicationDirPath()).dir().absolutePath();
    const QString ui = root + "/ui/main.qml";
    const QString script = root + "/engine/spoot.lua";

    Engine engine(script);
    Watchers watchers(&engine);
    QQmlApplicationEngine qml;
    // A minute up is a session that started, so the next fault is a fresh one
    // and gets its own three tries -- see crashguard.
    QTimer::singleShot(60000, &app, [] { crashguard::clearGeneration(); });
    Shell *shell = new Shell();
    qml.rootContext()->setContextProperty("Engine", &engine);
    qml.rootContext()->setContextProperty("Shell", shell);
    // --listen opens straight on the Listen view, the way the rofi build's one
    // rofi-opening flag does today.
    qml.rootContext()->setContextProperty("startView",
        app.arguments().contains("--listen") ? "listen" : "main");
    qml.load(QUrl::fromLocalFile(ui));
    if (qml.rootObjects().isEmpty()) return 1;

    // Which monitor spoot opens on: the one the pointer is in.
    //
    // QCursor::pos() is not the answer on Wayland -- a client is not told where
    // the pointer is until it enters one of its own surfaces, so a freshly
    // launched app reads a stale (0,0) and Qt picks the first screen. That is
    // exactly why spoot always came up on HDMI-A-1. The compositor is the only
    // thing that actually knows, so ask it, and fall back to Qt's guess if the
    // query fails or spoot is running somewhere without hyprctl.
    auto screenUnderCursor = [] () -> QScreen * {
        QProcess p;
        p.start("hyprctl", {"cursorpos"});
        if (p.waitForFinished(300)) {
            const QStringList xy = QString::fromUtf8(p.readAllStandardOutput()).trimmed().split(',');
            if (xy.size() == 2) {
                const QPoint at(xy[0].trimmed().toInt(), xy[1].trimmed().toInt());
                for (QScreen *s : QGuiApplication::screens())
                    if (s->geometry().contains(at)) return s;
            }
        }
        return QGuiApplication::primaryScreen();
    };

    if (qEnvironmentVariableIsSet("SPOOT_DEBUG_SCREENS")) {
        for (QScreen *s : QGuiApplication::screens())
            qWarning("screen %s geometry %d,%d %dx%d dpr %.2f",
                     qPrintable(s->name()), s->geometry().x(), s->geometry().y(),
                     s->geometry().width(), s->geometry().height(), s->devicePixelRatio());
        QScreen *pick = screenUnderCursor();
        qWarning("picked: %s", pick ? qPrintable(pick->name()) : "(null)");
    }

    // Configure the surface BEFORE it is shown -- main.qml deliberately leaves
    // visible false. get() has to reach the window while it still has no
    // platform window; once QML has shown it the compositor has already been
    // handed an ordinary toplevel and tiles spoot like any other app.
    if (auto *win = qobject_cast<QWindow *>(qml.rootObjects().first())) {
        if (auto *ls = LayerShellQt::Window::get(win)) {
            // LayerShellQt::Window::setScreen, NOT QWindow::setScreen. The
            // layer surface binds to an output of its own, and the QWindow's
            // screen has no say in it -- setting only that left spoot on
            // HDMI-A-1 no matter where the pointer was.
            ls->setScreen(screenUnderCursor());
            ls->setLayer(LayerShellQt::Window::LayerOverlay);
            // THE SURFACE IS THE WHOLE OUTPUT, and the panel is positioned
            // inside it by QML. Two things fall out of that, neither reachable
            // from a surface the size of the menu:
            //
            //   - A click outside the panel is an event we actually receive. A
            //     Wayland client gets no pointer events beyond its own surface,
            //     so a menu that hugs its own edges can never learn that you
            //     clicked away from it.
            //   - Position becomes ours. A layer-shell client cannot place
            //     itself, which is why centring the image viewer used to mean
            //     asking the compositor to re-anchor the surface mid-animation;
            //     inside a full-output surface it is an anchor change on an Item
            //     and nothing round-trips.
            //
            // Menu geometry does not change: the panel still anchors to the
            // bottom edge, which is where a bottom-anchored surface put it.
            ls->setAnchors(LayerShellQt::Window::Anchors(
                LayerShellQt::Window::AnchorTop | LayerShellQt::Window::AnchorBottom
                | LayerShellQt::Window::AnchorLeft | LayerShellQt::Window::AnchorRight));
            // Zero, not -1: spoot overlays whatever is behind it rather than
            // reserving a strip the way a bar does.
            ls->setExclusiveZone(0);
            ls->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityExclusive);
            ls->setScope("spoot");
        }
        // LIVE RELOAD. Every view lives in a .qml file read at runtime, so an
        // edit can take effect in the running shell -- no rebuild, and no
        // closing the menu you are looking at, which was never possible when a
        // menu was a rofi process that had already exited.
        if (qEnvironmentVariableIsSet("SPOOT_DEV")) {
            auto *watch = new QFileSystemWatcher(&app);
            QDirIterator it(root + "/ui", {"*.qml"}, QDir::Files, QDirIterator::Subdirectories);
            while (it.hasNext()) watch->addPath(it.next());
            QObject::connect(watch, &QFileSystemWatcher::fileChanged,
                             [&qml, ui, watch](const QString &path) {
                // Editors replace rather than write in place, so the watch has
                // to be re-armed or it fires exactly once per file.
                if (!watch->files().contains(path)) watch->addPath(path);
                qml.clearComponentCache();
                qml.load(QUrl::fromLocalFile(ui));
            });
        }

        shell->attach(win, screenUnderCursor);
        shell->reveal();

        // A stale socket file is what an unclean exit leaves behind; removing it
        // first is the difference between "resident" and "never starts again".
        QLocalServer::removeServer(sockName);
        auto *server = new QLocalServer(&app);
        server->listen(sockName);
        // CLOSE ON EXEC. Without this the listening socket is inherited by every
        // child -- each forked job, and, fatally, the execv the crash handler
        // does: the restarted spoot found the socket it had itself inherited
        // still open, decided a spoot was already resident, handed itself a
        // "show" and exited. A crash then read as spoot simply disappearing,
        // which is the exact failure the handler exists to prevent.
        if (server->isListening()) {
            const auto fd = server->socketDescriptor();
            if (fd != -1) fcntl(int(fd), F_SETFD, FD_CLOEXEC);
        }
        QObject::connect(server, &QLocalServer::newConnection, [server, shell, &qml] {
            QLocalSocket *c = server->nextPendingConnection();
            QObject::connect(c, &QLocalSocket::readyRead, [c, shell] {
                const QByteArray cmd = c->readAll().trimmed();
                // Revealed FIRST, so the view opens onto a window that is already
                // up rather than one that appears mid-request.
                shell->reveal();
                if (cmd == "listen") shell->askListen();
                c->deleteLater();
            });
        });
    }
    return app.exec();
}

#include "main.moc"
