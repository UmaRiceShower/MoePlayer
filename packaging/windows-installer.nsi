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
!define MUI_FINISHPAGE_TEXT "${APPNAME} 已安装。$\r$\n$\r$\n提示:播放需要 mpv —— 未安装时请将 mpv.exe 所在目录加入 PATH,或把 mpv.exe 放到 $INSTDIR。"
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
