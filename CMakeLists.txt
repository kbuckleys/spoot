# ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
# ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
# └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
# spoot Spotify Client ~ Part of the ZENWORKS Suite
# https://github.com/kbuckleys/

cmake_minimum_required(VERSION 3.21)
project(spoot LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Gui Qml Quick Network DBus)
find_package(LayerShellQt REQUIRED)

# The engine runs INSIDE this binary now -- see LuaWorker in src/main.cpp. Only
# the interpreter is linked in; engine/spoot.lua is still read from disk at
# runtime, so changing the engine costs a restart rather than a rebuild.
# WHICHEVER LUA THIS DISTRIBUTION SHIPS. The module name is not the same
# anywhere twice -- Arch installs lua5.5.pc, Debian lua5.4.pc, Fedora lua.pc --
# and pinning one of them meant the build only ever configured on Arch. setup
# installs whatever its own package manager calls Lua, so this has to accept the
# same range: 5.4 is the floor the engine is written against.
find_package(PkgConfig REQUIRED)
foreach(_lua_mod lua5.5 lua-5.5 lua5.4 lua-5.4 lua)
    pkg_check_modules(LUA QUIET IMPORTED_TARGET ${_lua_mod})
    if(LUA_FOUND)
        message(STATUS "spoot: using pkg-config module ${_lua_mod} (${LUA_VERSION})")
        break()
    endif()
endforeach()
if(NOT LUA_FOUND)
    message(FATAL_ERROR "no Lua found via pkg-config -- looked for lua5.5, lua5.4 and lua. "
                        "Install your distribution's Lua development package (5.4 or newer).")
endif()

# THE THREAD SANITIZER TARGET. The engine, every background job and the GUI now
# share one process, and the case for that resting on "nothing is shared, so
# nothing can race" is only worth as much as the evidence for it. This builds the
# same binary under -fsanitize=thread, beside the real one rather than over it, so
# the guards can be run against it:
#
#   cmake -S . -B build-tsan -DSPOOT_TSAN=ON && cmake --build build-tsan
#   SPOOT_BIN=../bin/spoot-tsan sh engine/smoke.sh
#   SPOOT_BIN=../bin/spoot-tsan sh engine/views.sh
#   SPOOT_BIN=./bin/spoot-tsan  sh ui/check.sh
option(SPOOT_TSAN "Build bin/spoot-tsan with the thread sanitizer" OFF)

add_executable(spoot src/main.cpp)
target_link_libraries(spoot PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network Qt6::DBus LayerShellQt::Interface PkgConfig::LUA)

# The binary lands in the project root, beside ui/ and engine/, because that is
# how it finds them: main.cpp resolves the root from its own location so `spoot`
# works as a keybind target from any working directory.
set_target_properties(spoot PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/bin)

if(SPOOT_TSAN)
    # -O1 and frame pointers: TSan needs the optimiser out of the way enough to
    # give a stack worth reading, and a name of its own so a sanitizer build can
    # never be the thing a keybind launches.
    set_target_properties(spoot PROPERTIES OUTPUT_NAME spoot-tsan)
    target_compile_options(spoot PRIVATE -fsanitize=thread -g -O1 -fno-omit-frame-pointer)
    target_link_options(spoot PRIVATE -fsanitize=thread)
endif()
