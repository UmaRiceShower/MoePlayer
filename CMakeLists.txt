cmake_minimum_required(VERSION 3.21)
project(MoePlayer VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# 生成源码根的 .qmlls.ini 与 build/.qt/.qmlls.build.ini:Qt VS Code 扩展的
# QML Language Server 据此解析 MoePlayer.Core 模块(qmldir/qmltypes)与
# qrc 资源路径。buildDir 由 qmlls 自动读取,无需手动配置扩展。
set(QT_QML_GENERATE_QMLLS_INI ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick QuickControls2 Network WebSockets ShaderTools)
# QTP0004 NEW:为模块内含 .qml 的子目录(views/theme/player)自动生成 qmldir。
qt_policy(SET QTP0004 NEW)
# 模块产物(qmldir/qmltypes)输出到 build/qml/,避免与可执行文件同名冲突
# (默认输出 build/MoePlayer/Core 会占用 build/MoePlayer 目录名)。
set(QT_QML_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/qml")

# pragma Singleton 文件须显式声明,qmldir 才会生成 singleton 条目
# (qmlls/LSP 才能识别 Theme/Constants 为单例并解析 Theme.bg 等成员)。
set_source_files_properties(qml/theme/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
set_source_files_properties(qml/theme/Constants.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

find_package(PkgConfig REQUIRED)
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)

# QML 模块:所有 QML 文件 + C++ 类型统一归入 URI MoePlayer.Core,
# 替代旧的 qml.qrc + 运行时 qmlRegister 布局。qt_add_qml_module 生成
# qmldir/MoePlayer.Core.qmltypes 到 build/qml/MoePlayer/Core/,资源嵌入
# qrc:/qt/qml/MoePlayer/Core/。NO_PLUGIN 对可执行目标自动生效。
qt_add_executable(MoePlayer
    src/main.cpp
    src/core/settingsstore.cpp
    src/core/embyclient.cpp
    src/core/accountmanager.cpp
    src/models/colorprovider.cpp
    src/models/mediaitemmodel.cpp
    src/models/posterprovider.cpp
    src/playback/mpvitem.cpp
    assets.qrc
)

qt_add_qml_module(MoePlayer
    URI MoePlayer.Core
    VERSION 1.0
    RESOURCE_PREFIX /qt/qml
    # 让生成的源码根 .qmlls.ini 自带模块 import 路径(模块查找按
    # <importPath>/MoePlayer/Core,故此处为 build/qml 父目录):无 CMake
    # Tools 提供 -b buildDir 时,qmlls 仅靠 .qmlls.ini 也能解析。
    IMPORT_PATH "${CMAKE_BINARY_DIR}/qml"
    QML_FILES
        qml/Main.qml
        qml/player/PlayerWindow.qml
        qml/theme/Theme.qml
        qml/theme/Constants.qml
        qml/theme/AppText.qml
        qml/theme/CrossfadeImage.qml
        qml/views/Home.qml
        qml/views/Library.qml
        qml/views/Detail.qml
        qml/views/Settings.qml
        qml/views/ServerManager.qml
        qml/views/SearchOverlay.qml
        qml/views/PosterCard.qml
        qml/views/ServerIcon.qml
)

# ShaderEffect 用 qsb 编译的 shader(官方路径):资源嵌入 qrc:
# /qt/qml/MoePlayer/Core/shaders/*.frag.qsb,与 QML 模块同前缀。
qt_add_shaders(MoePlayer moeplayer_shaders
    PREFIX "/qt/qml/MoePlayer/Core"
    # 仅 GLSL 目标:ShaderEffect 的属性按名绑定直接 uniform,Vulkan 要求
    # uniform block,与 ShaderEffect 绑定模型不兼容(本应用 RHI 后端为
    # OpenGL)。
    GLSL "100es,120,150"
    FILES shaders/crossfade.frag
)

# 子目录全量加入,qmltyperegistrar 生成的 #include <xxx.h>(按源文件
# 的 basename include 惯例记录)才能解析;无同名头文件冲突。
target_include_directories(MoePlayer PRIVATE src src/core src/models src/playback)
# 应用名/版本单一来源:CMake project() → 编译期宏 → 运行时引用。
# applicationName 决定 QSettings 存储路径,改名会失联旧配置,改前需评估。
target_compile_definitions(MoePlayer PRIVATE
    MOEPLAYER_VERSION="${PROJECT_VERSION}"
    MOEPLAYER_NAME="${PROJECT_NAME}")
target_link_libraries(MoePlayer PRIVATE Qt6::Core Qt6::Gui Qt6::Quick Qt6::QuickControls2 Qt6::Network Qt6::WebSockets PkgConfig::MPV)
