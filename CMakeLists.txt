cmake_minimum_required(VERSION 3.21)
project(MoePlayer VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick QuickControls2 Network WebSockets)
find_package(PkgConfig REQUIRED)
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)

add_executable(MoePlayer
    src/main.cpp
    src/core/settingsstore.cpp
    src/core/embyclient.cpp
    src/models/mediaitemmodel.cpp
    src/models/posterprovider.cpp
    src/playback/mpvitem.cpp
    qml.qrc
)

target_include_directories(MoePlayer PRIVATE src)
target_link_libraries(MoePlayer PRIVATE Qt6::Core Qt6::Gui Qt6::Quick Qt6::QuickControls2 Qt6::Network Qt6::WebSockets PkgConfig::MPV)
