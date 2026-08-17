#!/usr/bin/env bash
# ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
# ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
# └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
# spoot Spotify Client ~ Part of the ZENWORKS Suite
# https://github.com/kbuckleys/
#
# GET SPOOT ONTO A MACHINE. Installs what it takes to build, builds, and hands
# over to spoot itself -- which asks about its own runtime dependencies and then
# signs you in.
#
# A SHELL SCRIPT because of an ordering problem nothing else solves. spoot's
# dependency installer is written in Lua and lives inside the engine, which is
# spawned by a Qt binary -- so on a machine with no Qt, the dynamic loader fails
# before main() and the installer never runs. You cannot use spoot to install the
# thing spoot needs in order to run its installer. This is the floor beneath
# that: it needs a shell and nothing else.
#
# It therefore restates what Util.PKG_MGRS already knows about package managers.
# That is not an oversight -- reading the Lua table would mean having Lua, which
# is one of the things this exists to install. The overlap is kept to the FLOOR:
# a toolchain, Qt, and Lua. Everything else spoot asks for itself on first run,
# through Util.DEPS, which stays the one description of what spoot needs.

set -eu

# WHERE THIS SCRIPT IS, not where you ran it from. `cd ~/somewhere && bash
# /path/to/install.sh` has to work, and so does ./install.sh -- and neither may
# write into whatever directory happened to be current.
here=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$here"

say()  { printf '\033[1;36m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m::\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m::\033[0m %s\n' "$*" >&2; exit 1; }

[ -f engine/spoot.lua ] && [ -f src/main.cpp ] \
    || die "run this from inside the spoot tree (engine/ and src/ are missing)"

# --- what to install, per manager ----------------------------------------
#
# The BUILD floor plus Lua. Names differ per distribution and only pacman's are
# verified here, so nothing downstream trusts them: the cmake configure below is
# what actually decides whether this worked, and it says exactly what is missing
# when it did not. A wrong name degrades to a clear message, never to a silent
# half-install.
mgr=""; install_cmd=""; needs_root=1; pkgs=""

if   command -v pacman        >/dev/null 2>&1; then
    mgr=pacman;   install_cmd="pacman -S --needed --noconfirm"
    pkgs="cmake gcc qt6-base qt6-declarative layer-shell-qt lua lua-cjson"
elif command -v apt-get       >/dev/null 2>&1; then
    mgr=apt-get
    install_cmd="apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y"
    pkgs="cmake g++ qt6-base-dev qt6-declarative-dev libqt6opengl6-dev \
          liblayershellqtinterface-dev lua5.4 lua-cjson"
elif command -v dnf           >/dev/null 2>&1; then
    mgr=dnf;      install_cmd="dnf install -y"
    pkgs="cmake gcc-c++ qt6-qtbase-devel qt6-qtdeclarative-devel \
          layer-shell-qt-devel lua lua-cjson"
elif command -v zypper        >/dev/null 2>&1; then
    mgr=zypper;   install_cmd="zypper --non-interactive install"
    pkgs="cmake gcc-c++ qt6-base-devel qt6-declarative-devel \
          layer-shell-qt-devel lua54 lua54-luajson"
elif command -v apk           >/dev/null 2>&1; then
    mgr=apk;      install_cmd="apk add"
    pkgs="cmake g++ qt6-qtbase-dev qt6-qtdeclarative-dev layer-shell-qt-dev \
          lua5.4 lua5.4-cjson"
elif command -v xbps-install  >/dev/null 2>&1; then
    mgr=xbps-install; install_cmd="xbps-install -y"
    pkgs="cmake gcc qt6-base-devel qt6-declarative-devel layer-shell-qt-devel \
          lua54 lua54-cjson"
elif command -v nix-env       >/dev/null 2>&1; then
    # Into the user's own profile, so this one must NOT be run through sudo --
    # the same rule Util.PKG_MGRS records with `root = false`.
    mgr=nix-env;  install_cmd="nix-env -iA"; needs_root=0
    pkgs="nixpkgs.cmake nixpkgs.gcc nixpkgs.qt6.qtbase nixpkgs.qt6.qtdeclarative \
          nixpkgs.layer-shell-qt nixpkgs.lua nixpkgs.luaPackages.cjson"
else
    warn "no package manager recognised -- skipping the install step."
    warn "spoot needs: cmake 3.21+, a C++17 compiler, Qt 6 (Base + Declarative),"
    warn "LayerShellQt, lua 5.4+ and lua-cjson. Install those and run this again."
fi

# --- becoming root, without ever handling a password ---------------------
#
# Same order and the same reasoning as Util.privilege: already root, then a rule
# that already grants it (fails instantly rather than prompting), then the
# desktop's own dialog. If none fits, the command is printed -- for plenty of
# setups that is the correct answer rather than a failure.
priv=""
if [ "$needs_root" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    if   command -v sudo   >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then priv="sudo "
    elif command -v doas   >/dev/null 2>&1 && doas -n true >/dev/null 2>&1; then priv="doas "
    elif command -v sudo   >/dev/null 2>&1; then priv="sudo "
    elif command -v doas   >/dev/null 2>&1; then priv="doas "
    elif command -v pkexec >/dev/null 2>&1; then priv="pkexec "
    else
        warn "no way to become root found -- run this as root, or install by hand:"
        warn "  $install_cmd $pkgs"
        mgr=""
    fi
fi

if [ -n "$mgr" ]; then
    say "installing build dependencies with $mgr"
    # NOT quiet. Unlike the engine's unattended install, someone is looking at
    # this terminal and a package manager is exactly the thing they want to
    # watch -- and sudo may need to ask them for a password.
    # shellcheck disable=SC2086
    ${priv}sh -c "$install_cmd $pkgs" || warn "the install reported a failure -- carrying on, the build below is the real test"
fi

# --- build ----------------------------------------------------------------
#
# THIS is the verification. Package names above are best-effort per distribution;
# cmake either finds Qt6 and LayerShellQt or it does not, and what it prints when
# it does not is more useful than anything this script could guess.
say "building"
if ! cmake -S . -B build; then
    die "cmake could not configure -- it needs Qt 6 (Gui, Qml, Quick, Network)
    and LayerShellQt development packages. The message above names which one it
    could not find."
fi
cmake --build build -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

# --- the executable bits --------------------------------------------------
#
# A GitHub source download is a zip, and a zip carries no permission bits -- so
# every script in the tree arrives unexecutable, this one included (which is why
# the README says `bash install.sh` rather than ./install.sh). cmake marks the
# binary itself, but say so anyway: it costs nothing and it is the one file a
# keybind points at.
chmod +x bin/spoot 2>/dev/null || true
chmod +x engine/smoke.sh engine/views.sh ui/check.sh install.sh 2>/dev/null || true

say "built $here/bin/spoot"
say "bind that path to a key -- a second run hands over to the first and exits"

# --- over to spoot --------------------------------------------------------
#
# exec, not a plain call: spoot is the program now, and leaving this script in
# the process tree only means one more thing to kill. It asks about its own
# runtime dependencies -- spotifyd, playerctl, curl and the rest of Util.DEPS --
# and then signs you in.
say "starting spoot"
exec ./bin/spoot
