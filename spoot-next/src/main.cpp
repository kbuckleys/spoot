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
#include <LayerShellQt/Shell>
#include <LayerShellQt/Window>

// The bridge QML talks to. request() sends a command and answers with the id it
// was given; the reply arrives later on response(). Nothing blocks, which is the
// whole point -- a 600ms fetch must never hold a frame.
class Engine : public QObject {
    Q_OBJECT
public:
    explicit Engine(const QString &lua, const QString &script, QObject *parent = nullptr)
        : QObject(parent) {
        connect(&m_proc, &QProcess::readyReadStandardOutput, this, &Engine::drain);
        // The engine's stderr is spoot's stderr: a Lua traceback has to reach
        // the terminal rather than vanish into a pipe nobody reads.
        m_proc.setProcessChannelMode(QProcess::ForwardedErrorChannel);
        m_proc.start(lua, {script, "--serve"});
    }

    // Returns the request id so a caller can match its own reply.
    Q_INVOKABLE int request(const QString &cmd, const QVariantMap &args = {}) {
        QJsonObject o{{"id", ++m_id}, {"cmd", cmd}};
        if (!args.isEmpty()) o["args"] = QJsonObject::fromVariantMap(args);
        m_proc.write(QJsonDocument(o).toJson(QJsonDocument::Compact) + "\n");
        return m_id;
    }

signals:
    void response(int id, bool ok, QVariant data, QString err);
    void event(QString name, QVariant data);

private slots:
    void drain() {
        m_buf += m_proc.readAllStandardOutput();
        // Newline-delimited, so a partial line at the tail is normal and is
        // kept for the next read rather than parsed and discarded.
        int nl;
        while ((nl = m_buf.indexOf('\n')) >= 0) {
            const QByteArray line = m_buf.left(nl);
            m_buf.remove(0, nl + 1);
            if (line.trimmed().isEmpty()) continue;
            const QJsonObject o = QJsonDocument::fromJson(line).object();
            if (o.contains("ev"))
                emit event(o.value("ev").toString(), o.toVariantMap());
            else
                emit response(o.value("id").toInt(), o.value("ok").toBool(),
                              o.value("data").toVariant(), o.value("err").toString());
        }
    }

private:
    QProcess m_proc;
    QByteArray m_buf;
    int m_id = 0;
};

// Keeps spoot resident. Escape hides the surface instead of ending the process,
// and a second `spoot` hands its request to the first one over a socket and
// exits -- so the Lua engine, the token, and every warm cache survive between
// summons. A cold start pays for the engine, the API handshake and the first
// draw; a warm one pays for nothing.
class Shell : public QObject {
    Q_OBJECT
public:
    Shell(QWindow *w, std::function<QScreen *()> pick) : m_win(w), m_pick(pick) {}

    // Re-picks the monitor EVERY time. The pointer moves between summons, and a
    // resident process that always reappeared where it first opened would be
    // worse than a cold start that got it right.
    Q_INVOKABLE void reveal() {
        if (auto *ls = LayerShellQt::Window::get(m_win)) ls->setScreen(m_pick());
        m_win->show();
        m_win->requestActivate();
        emit revealed();
    }
    Q_INVOKABLE void conceal() { m_win->hide(); }

    // `spoot --listen` ARRIVING AT A SHELL THAT IS ALREADY RUNNING. The flag used
    // to be delivered by re-setting the `startView` context property, which only
    // main.qml's bootstrap ever read -- and bootstrap runs once, at load. So the
    // flag worked exactly once per process, on a cold start, and every later
    // press of the keybind just revealed the window wherever it had been left.
    //
    // A signal instead, because this is an EVENT: it happened again, and "the
    // value is still listen" cannot say that.
    void askListen() { emit listen(); }

    // LETTING GO OF THE KEYBOARD, briefly. The surface takes an exclusive grab,
    // which is right for a launcher and fatal for anything that needs to ask the
    // user a question of its own -- a polkit dialog raised by pkexec cannot be
    // typed into while spoot holds every key, so an unattended dependency
    // install would sit there forever waiting on a password nobody could enter.
    //
    // Released for exactly that, and taken straight back.
    Q_INVOKABLE void setGrab(bool on) {
        auto *ls = LayerShellQt::Window::get(m_win);
        if (!ls) return;
        ls->setKeyboardInteractivity(on ? LayerShellQt::Window::KeyboardInteractivityExclusive
                                        : LayerShellQt::Window::KeyboardInteractivityNone);
    }

signals:
    void revealed();
    void listen();

private:
    QWindow *m_win;
    std::function<QScreen *()> m_pick;
};

int main(int argc, char *argv[]) {
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

    Engine engine("lua", script);
    QQmlApplicationEngine qml;
    qml.rootContext()->setContextProperty("Engine", &engine);
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

        Shell *shell = new Shell(win, screenUnderCursor);
        qml.rootContext()->setContextProperty("Shell", shell);
        shell->reveal();

        // A stale socket file is what an unclean exit leaves behind; removing it
        // first is the difference between "resident" and "never starts again".
        QLocalServer::removeServer(sockName);
        auto *server = new QLocalServer(&app);
        server->listen(sockName);
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
