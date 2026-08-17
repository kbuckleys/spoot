cmake_minimum_required(VERSION 3.21)
project(spoot LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Gui Qml Quick Network)
find_package(LayerShellQt REQUIRED)

add_executable(spoot src/main.cpp)
target_link_libraries(spoot PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Network LayerShellQt::Interface)

# The binary lands in the project root, beside ui/ and engine/, because that is
# how it finds them: main.cpp resolves the root from its own location so `spoot`
# works as a keybind target from any working directory.
set_target_properties(spoot PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/bin)
