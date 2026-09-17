cmake_minimum_required(VERSION 3.21)
project(MoePlayer VERSION 0.1.0 LANGUAGES CXX)

# 预发布后缀(SemVer):开发期 "-dev",预览期 "-alpha.1"/"-beta.1"/"-rc.1",
# 正式版清空。字符串位(关于页/rc 字符串/包文件名)用完整串,数值位
# (rc 四段数/NSIS VIProductVersion)保持纯数字 PROJECT_VERSION。
# CI tag 构建经环境变量覆盖(v0.2.0-rc.1 → -rc.1;正式 tag → 空串)——
# 空串也是有效覆盖,故用 DEFINED 判存在而非判非空。
set(MOEPLAYER_VERSION_SUFFIX "-dev")
if(DEFINED ENV{MOEPLAYER_VERSION_SUFFIX})
    set(MOEPLAYER_VERSION_SUFFIX "$ENV{MOEPLAYER_VERSION_SUFFIX}")
endif()
set(MOEPLAYER_VERSION_FULL "${PROJECT_VERSION}${MOEPLAYER_VERSION_SUFFIX}")

# 桌面集成标识(反向域名):desktop 文件名、图标名、Wayland app_id 与
# 打包(Flatpak/AppImage)统一取值,与 QSettings 路径(MOEPLAYER_NAME)解耦。
set(MOEPLAYER_APP_ID "io.github.umariceshower.MoePlayer")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
# AUTOMOC/AUTOUIC 与 Qt CMake 策略由下方 qt_standard_project_setup 一站式
# 启用(官方 6.3+ 推荐);AUTORCC 不需要——无 .qrc,资源走 qt_add_resources。

# 生成源码根的 .qmlls.ini 与 build/.qt/.qmlls.build.ini:Qt VS Code 扩展的
# QML Language Server 据此解析 MoePlayer.Core 模块(qmldir/qmltypes)与
# qrc 资源路径。buildDir 由 qmlls 自动读取,无需手动配置扩展。
set(QT_QML_GENERATE_QMLLS_INI ON)

# DBus 仅用于 Linux 的待机抑制(ScreenInhibit);Windows 走 SetThreadExecutionState。
if(UNIX)
    find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick QuickControls2 Network WebSockets ShaderTools DBus)
    set(MOEPLAYER_PLATFORM_LIBS Qt6::DBus)
    # 内嵌播放(Linux):libmpv + GL render API。找到即启用
    # MOEPLAYER_HAVE_LIBMPV;找不到自动退回纯外部 mpv 模式。
    find_package(PkgConfig)
    if(PkgConfig_FOUND)
        pkg_check_modules(MPV IMPORTED_TARGET mpv)
    endif()
    # 只取头文件路径(运行时 dlopen libmpv.so.2,不链接):deb/rpm/AppImage
    # 均无硬依赖,缺库静默回外部 mpv 模式。
    if(MPV_FOUND)
        list(APPEND MOEPLAYER_PLATFORM_INCLUDES ${MPV_INCLUDE_DIRS})
    endif()
else()
    find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick QuickControls2 Network WebSockets ShaderTools)
    set(MOEPLAYER_PLATFORM_LIBS "")
endif()
# 官方推荐项目默认(Qt 6.3+):开 AUTOMOC/AUTOUIC、GNUInstallDirs、RPATH,
# 并按 REQUIRES 6.8 批量启用 QTP0001-QTP0005(替代原手动 qt_policy)。
# 不设 AUTORCC(无 .qrc)与 C++ 标准(上方手动设置,该命令不涉及)。
qt_standard_project_setup(REQUIRES 6.8)
# 模块产物(qmldir/qmltypes)输出到 build/qml/,避免与可执行文件同名冲突
# (默认输出 build/MoePlayer/Core 会占用 build/MoePlayer 目录名)。
set(QT_QML_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/qml")
# pragma Singleton 文件须显式声明,qmldir 才会生成 singleton 条目
# (qmlls/LSP 才能识别 Theme/Constants 为单例并解析 Theme.bg 等成员)。
set_source_files_properties(qml/theme/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
set_source_files_properties(qml/theme/Constants.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
set_source_files_properties(qml/theme/ThemeStore.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
set_source_files_properties(qml/FuzzyMatch.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

# QML 模块:所有 QML 文件 + C++ 类型统一归入 URI MoePlayer.Core,
# 替代旧的 qml.qrc + 运行时 qmlRegister 布局。qt_add_qml_module 生成
# qmldir/MoePlayer.Core.qmltypes 到 build/qml/MoePlayer/Core/,资源嵌入
# qrc:/qt/qml/MoePlayer/Core/。NO_PLUGIN 对可执行目标自动生效。
qt_add_executable(MoePlayer
    # WIN32:Windows 下 GUI 子系统,不弹控制台窗口(其它平台无副作用)。
    WIN32
    src/main.cpp
    src/core/settingsstore.cpp
    src/core/embyclient.cpp
    src/core/accountmanager.cpp
    src/core/applog.cpp
    src/core/apppaths.cpp
    src/core/configmanager.cpp
    src/core/persistmap.cpp
    src/core/playbackhistory.cpp
    src/core/recentsearches.cpp
    src/core/screeninhibit.cpp
    src/core/pinyinhelper.cpp
    src/core/pinyin_table.cpp
    src/models/colorprovider.cpp
    src/models/homerowsmodel.cpp
    src/models/mediaitemmodel.cpp
    src/models/posterprovider.cpp
    src/playback/mpvclient.cpp
    src/playback/mpvvideoitem.cpp
)

# Windows 可执行资源(.rc 由 rc.exe 处理):图标 + VERSIONINFO。
# 版本号唯一源 = 上方 project(VERSION),经 configure_file 注入;
# FILEVERSION/PRODUCTVERSION 须四段逗号格式。
if(WIN32)
    set(MOEPLAYER_ICO_PATH "${CMAKE_CURRENT_SOURCE_DIR}/packaging/moeplayer.ico")
    string(REPLACE "." "," MOEPLAYER_RC_VERSION "${PROJECT_VERSION}.0")
    configure_file(packaging/moeplayer.rc.in ${CMAKE_CURRENT_BINARY_DIR}/moeplayer.rc @ONLY)
    target_sources(MoePlayer PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/moeplayer.rc)
endif()

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
        qml/FuzzyMatch.qml
        qml/theme/Theme.qml
        qml/theme/Constants.qml
        qml/theme/AppText.qml
        qml/theme/CrossfadeImage.qml
        qml/theme/ThemedBackground.qml
        qml/theme/GlassBlurSource.qml
        qml/theme/GlassPanel.qml
        qml/theme/FrostedGlass.qml
        qml/theme/MoeScrollBar.qml
        qml/theme/ThemeStore.qml
        qml/views/Home.qml
        qml/views/Library.qml
        qml/views/Detail.qml
        qml/views/SettingsOverlay.qml
        qml/views/ServerManager.qml
        qml/views/SearchOverlay.qml
        qml/views/PosterCard.qml
        qml/views/ServerIcon.qml
        qml/views/FilterChip.qml
        qml/views/SegmentedControl.qml
        qml/views/PlaybackHistoryPage.qml
        qml/views/PlayerWindow.qml
        qml/views/BackCircleButton.qml
        qml/views/NavGlyph.qml
)

# ShaderEffect 用 qsb 编译的 shader(官方路径):资源嵌入 qrc:
# /qt/qml/MoePlayer/Core/shaders/*.frag.qsb,与 QML 模块同前缀。
qt_add_shaders(MoePlayer moeplayer_shaders
    PREFIX "/qt/qml/MoePlayer/Core"
    # 仅 GLSL 目标:ShaderEffect 的属性按名绑定直接 uniform,Vulkan 要求
    # uniform block,与 ShaderEffect 绑定模型不兼容(本应用 RHI 后端为
    # OpenGL)。
    GLSL "100es,120,150"
    FILES shaders/background.frag
          shaders/crossfade.frag
          shaders/episode-fade.frag
          shaders/glass-refract.frag
          shaders/hero-fade.frag
          shaders/hero.vert
          shaders/hero.frag
)

# 计数器 GIF:qt_add_resources 替代 AUTORCC + assets.qrc(官方推荐路径)。
# BASE 裁剪到 counter 目录(文件相对 BASE 为 0.gif…9.gif),
# PREFIX /counter 拼出 qrc:/counter/N.gif,与原 assets.qrc alias 一致。
qt_add_resources(MoePlayer "counter_assets"
    PREFIX "/counter"
    BASE "qml/assets/counter"
    FILES
        qml/assets/counter/0.gif
        qml/assets/counter/1.gif
        qml/assets/counter/2.gif
        qml/assets/counter/3.gif
        qml/assets/counter/4.gif
        qml/assets/counter/5.gif
        qml/assets/counter/6.gif
        qml/assets/counter/7.gif
        qml/assets/counter/8.gif
        qml/assets/counter/9.gif
)
# 顶部导航图标(Lucide, ISC):qrc:/icons/<name>.svg。
qt_add_resources(MoePlayer "nav_icons"
    PREFIX "/icons"
    BASE "qml/assets/icons"
    FILES
        qml/assets/icons/history.svg
        qml/assets/icons/search.svg
        qml/assets/icons/settings.svg
        qml/assets/icons/server.svg
        qml/assets/icons/petal.svg
        qml/assets/icons/dark/search.svg
        qml/assets/icons/dark/settings.svg
        qml/assets/icons/dark/history.svg
        qml/assets/icons/dark/server.svg
        qml/assets/icons/chevron-left.svg
        qml/assets/icons/chevron-right.svg
        qml/assets/icons/chevron-up.svg
        qml/assets/icons/dark/chevron-left.svg
        qml/assets/icons/dark/chevron-right.svg
        qml/assets/icons/dark/chevron-up.svg
        qml/assets/icons/play.svg
        qml/assets/icons/pause.svg
        qml/assets/icons/next.svg
        qml/assets/icons/prev.svg
        qml/assets/icons/volume.svg
        qml/assets/icons/mute.svg
        qml/assets/icons/fullscreen.svg
        qml/assets/icons/dark/play.svg
        qml/assets/icons/dark/pause.svg
        qml/assets/icons/dark/next.svg
        qml/assets/icons/dark/prev.svg
        qml/assets/icons/dark/volume.svg
        qml/assets/icons/dark/mute.svg
        qml/assets/icons/dark/fullscreen.svg
        qml/assets/icons/episodes.svg
        qml/assets/icons/audio.svg
        qml/assets/icons/subtitle.svg
        qml/assets/icons/dark/episodes.svg
        qml/assets/icons/dark/audio.svg
        qml/assets/icons/dark/subtitle.svg
)

# 应用图标(首页空态徽记等界面内引用):qrc:/app/app-icon.svg。
set_source_files_properties(packaging/io.github.umariceshower.MoePlayer.svg
    PROPERTIES QT_RESOURCE_ALIAS "app-icon.svg")
qt_add_resources(MoePlayer "app_icon"
    PREFIX "/app"
    FILES packaging/io.github.umariceshower.MoePlayer.svg)

# 子目录全量加入,qmltyperegistrar 生成的 #include <xxx.h>(按源文件
# 的 basename include 惯例记录)才能解析;无同名头文件冲突。
target_include_directories(MoePlayer PRIVATE src src/core src/models src/playback third_party/tomlplusplus)
# 应用名/版本单一来源:CMake project() → 编译期宏 → 运行时引用。
# applicationName 决定 QSettings 存储路径,改名会失联旧配置,改前需评估。
target_compile_definitions(MoePlayer PRIVATE
    MOEPLAYER_VERSION="${MOEPLAYER_VERSION_FULL}"
    $<$<BOOL:${MPV_FOUND}>:MOEPLAYER_HAVE_LIBMPV>
    MOEPLAYER_NAME="${PROJECT_NAME}"
    MOEPLAYER_APP_ID="${MOEPLAYER_APP_ID}"
    # 仅 Debug 启用 QML 调试/剖析(QML Profiler / -qmljsdebugger 需要 QT_QML_DEBUG)。
    $<$<CONFIG:Debug>:QT_QML_DEBUG>)
target_include_directories(MoePlayer PRIVATE ${MOEPLAYER_PLATFORM_INCLUDES})
target_link_libraries(MoePlayer PRIVATE Qt6::Core Qt6::Gui Qt6::Quick Qt6::QuickControls2 Qt6::Network Qt6::WebSockets ${MOEPLAYER_PLATFORM_LIBS})

include(GNUInstallDirs)
install(TARGETS MoePlayer RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

install(DIRECTORY resources/lua/
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/moeplayer/lua)

# Anime4K shader(随包,供 mpv --glsl-shaders 用;mpv 只收文件路径)。
install(DIRECTORY resources/shaders/
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/moeplayer/shaders)
add_custom_command(TARGET MoePlayer POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_CURRENT_SOURCE_DIR}/resources/lua
        ${CMAKE_BINARY_DIR}/lua
    COMMENT "Copying mpv lua scripts to build/lua")
add_custom_command(TARGET MoePlayer POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        ${CMAKE_CURRENT_SOURCE_DIR}/resources/shaders
        ${CMAKE_BINARY_DIR}/shaders
    COMMENT "Copying Anime4K shaders to build/shaders")
# desktop 文件/AppStream 元数据/hicolor 图标仅对 Linux 包有意义(Windows
# 由 windeployqt + NSIS 打包,exe 图标与版本信息在 packaging/moeplayer.rc.in)。
# metainfo 版本随 project(VERSION) 注入(configure_file),发行日期取构建日。
if(UNIX)
    string(TIMESTAMP MOEPLAYER_METAINFO_DATE "%Y-%m-%d")
    configure_file(packaging/${MOEPLAYER_APP_ID}.metainfo.xml.in
                   ${CMAKE_CURRENT_BINARY_DIR}/${MOEPLAYER_APP_ID}.metainfo.xml @ONLY)
    install(FILES packaging/${MOEPLAYER_APP_ID}.desktop
            DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/applications)
    install(FILES ${CMAKE_CURRENT_BINARY_DIR}/${MOEPLAYER_APP_ID}.metainfo.xml
            DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/metainfo)
    install(DIRECTORY packaging/icons/hicolor/
            DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/icons/hicolor)
endif()
install(FILES LICENSE THIRD-PARTY-NOTICES.md
        DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/doc/moeplayer)

set(CPACK_PACKAGE_NAME "moeplayer")
set(CPACK_PACKAGE_VERSION "${MOEPLAYER_VERSION_FULL}")
# RPM 的 Version 字段禁含 '-',预发布后缀映射为 '~'(0.1.0~dev 排序上仍
# 先于正式版 0.1.0);deb 的上游版本段允许字母,直接用完整串。
string(REPLACE "-" "~" CPACK_RPM_PACKAGE_VERSION "${MOEPLAYER_VERSION_FULL}")
set(CPACK_PACKAGE_VENDOR "UmaRiceShower")
set(CPACK_PACKAGE_CONTACT "UmaRiceShower")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Third-party Emby desktop client (Qt/QML, external mpv)")
set(CPACK_PACKAGE_HOMEPAGE_URL "https://github.com/UmaRiceShower/MoePlayer")
set(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_SOURCE_DIR}/LICENSE")
# 产物命名统一 MoePlayer-<版本>-linux-<架构>.<ext>(与 AppImage/Windows 同风格;
# CI 上传走通配符,改名无联动)。
set(CPACK_PACKAGE_FILE_NAME "MoePlayer-${CPACK_PACKAGE_VERSION}-linux-${CMAKE_SYSTEM_PROCESSOR}")
set(CPACK_GENERATOR "TGZ;DEB;RPM")

set(CPACK_DEBIAN_PACKAGE_SECTION "video")
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "UmaRiceShower")
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)
set(CPACK_DEBIAN_PACKAGE_DEPENDS "mpv (>= 0.38.0), \
    qml6-module-qtquick, qml6-module-qtquick-controls, qml6-module-qtquick-effects, \
    qml6-module-qtquick-layouts, qml6-module-qtquick-shapes, qml6-module-qtquick-window")
# deb 架构名与 GNU 机器名不同(x86_64→amd64),显式映射保持文件名同风格。
if(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
    set(CPACK_DEBIAN_PACKAGE_ARCHITECTURE "amd64")
else()
    set(CPACK_DEBIAN_PACKAGE_ARCHITECTURE "${CMAKE_SYSTEM_PROCESSOR}")
endif()
set(CPACK_DEBIAN_FILE_NAME "MoePlayer-${CPACK_PACKAGE_VERSION}-linux-${CPACK_DEBIAN_PACKAGE_ARCHITECTURE}.deb")

set(CPACK_RPM_PACKAGE_LICENSE "GPL-3.0-only")
set(CPACK_RPM_PACKAGE_GROUP "Applications/Multimedia")
set(CPACK_RPM_PACKAGE_REQUIRES "mpv >= 0.38.0, qt6-qtdeclarative")
# 内嵌播放(libmpv)为运行时装载的可选增强:缺库回外部模式,故 Suggests。
set(CPACK_RPM_PACKAGE_SUGGESTS "mpv-libs")
set(CPACK_DEBIAN_PACKAGE_SUGGESTS "libmpv2")
set(CPACK_RPM_FILE_NAME RPM-DEFAULT)

include(CPack)
