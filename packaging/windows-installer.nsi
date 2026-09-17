Unicode true

!ifndef VERSION
  !define VERSION "0.0.0"
!endif

!include "MUI2.nsh"
!include "LogicLib.nsh"

!define APPNAME "MoePlayer"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"

Name "${APPNAME} ${VERSION}"
OutFile "..\MoePlayer-Setup-${VERSION}.exe"

; 安装器 exe 版本信息(属性页可见)。VERSION = 完整串(可带 -rc.1 后缀);
; VERSION_NUM = 纯数字(CI 一并传入),VIProductVersion 只收四段数字段。
; 本地手动 makensis 只传 /DVERSION 时回退同值(此时 VERSION 须为数字串)。
!ifndef VERSION_NUM
!define VERSION_NUM "${VERSION}"
!endif
VIProductVersion "${VERSION_NUM}.0"
VIAddVersionKey /LANG=2052 "ProductName" "${APPNAME}"
VIAddVersionKey /LANG=2052 "FileDescription" "${APPNAME} 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "Copyright (C) 2026 UmaRiceShower"
InstallDir "$PROGRAMFILES64\${APPNAME}"
InstallDirRegKey HKLM "Software\${APPNAME}" "InstallDir"
RequestExecutionLevel admin
SetCompressor /SOLID lzma

!define MUI_ICON "moeplayer.ico"
!define MUI_UNICON "moeplayer.ico"
!define MUI_ABORTWARNING

!insertmacro MUI_PAGE_LICENSE "..\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_TEXT "${APPNAME} 已安装(内嵌播放组件已自带)。$\r$\n$\r$\n提示:仅当您在设置中选择「外部」播放后端时,才需要自备 mpv.exe(加入 PATH 或放到 $INSTDIR)。"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Section "${APPNAME}" SEC_APP
  SectionIn RO
  SetOutPath "$INSTDIR"
  File /r "..\package\*.*"
  File "..\vc_redist.x64.exe"
  File /oname=moeplayer.ico "moeplayer.ico"

  DetailPrint "安装 Microsoft Visual C++ 运行库"
  ExecWait '"$INSTDIR\vc_redist.x64.exe" /install /quiet /norestart' $0
  ${If} $0 != 0
    DetailPrint "vc_redist 退出码 $0(已安装则可忽略)"
  ${EndIf}
  Delete "$INSTDIR\vc_redist.x64.exe"

  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" "$INSTDIR\MoePlayer.exe"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\卸载 ${APPNAME}.lnk" "$INSTDIR\Uninstall.exe"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "Software\${APPNAME}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\MoePlayer.exe"
  WriteRegStr HKLM "${UNINSTKEY}" "UninstallString" "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "${UNINSTKEY}" "Publisher" "UmaRiceShower"
SectionEnd

Section /o "桌面快捷方式" SEC_DESKTOP
  CreateShortcut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\MoePlayer.exe"
SectionEnd

Section "un.MoePlayer"
  Delete "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk"
  Delete "$SMPROGRAMS\${APPNAME}\卸载 ${APPNAME}.lnk"
  RMDir "$SMPROGRAMS\${APPNAME}"
  Delete "$DESKTOP\${APPNAME}.lnk"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "${UNINSTKEY}"
  DeleteRegKey HKLM "Software\${APPNAME}"
SectionEnd
