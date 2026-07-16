; DisplayXR Browser — developer-preview installer
; Copyright 2026, DisplayXR
; SPDX-License-Identifier: BSL-1.0
;
; Installs the branded static Chromium (the inline-3D fork) into
; $PROGRAMFILES64\DisplayXR\Browser, chains-or-requires the DisplayXR runtime + a
; display plug-in (the weave prerequisites), and on first run detects a DisplayXR 3D
; display / registered DP — surfacing a one-time "no 3D display" notice if absent
; (the weave already no-ops safely, so it just runs as a normal browser).
;
; Build (from a staged tree produced by scripts/package.sh):
;   makensis -DVERSION=x.y.z \
;            -DSTAGE_DIR=<abs path to dist/DisplayXR-Browser> \
;            -DSOURCE_DIR=<abs path to this repo> -DOUTPUT_DIR=<abs out> \
;            [-DRUNTIME_SETUP=<abs path to DisplayXRSetup.exe to chain>] \
;            installer/DisplayXRBrowserInstaller.nsi
; VERSION is a 3-part semantic version (major.minor.patch) for released builds.
; SIGN_CMD (optional) enables Authenticode + the two-pass signed uninstaller.

;--------------------------------
!ifndef VERSION
	!define VERSION "0.0.0"
!endif
!ifndef STAGE_DIR
	!error "STAGE_DIR (staged DisplayXR-Browser tree) is required"
!endif
!ifndef SOURCE_DIR
	!define SOURCE_DIR "."
!endif
!ifndef OUTPUT_DIR
	!define OUTPUT_DIR "."
!endif

;--------------------------------
; Two-pass signing (same robust recipe as the runtime installer — see
; DisplayXRInstaller.nsi header: !uninstfinalize dangles the cert table, so
; pre-sign the uninstaller in an inner pass and File-include it).
!ifndef INNER
	!ifdef SIGN_CMD
		!if "${SIGN_CMD}" != ""
			!finalize '${SIGN_CMD} "%1"'
			!makensis '-DINNER "-DVERSION=${VERSION}" "-DSTAGE_DIR=${STAGE_DIR}" "-DSOURCE_DIR=${SOURCE_DIR}" "-DOUTPUT_DIR=${OUTPUT_DIR}" "${__FILE__}"' = 0
			!system '"$%TEMP%\DisplayXRBrowser_inner.exe"' = 2
			!system '${SIGN_CMD} "$%TEMP%\Uninstall.exe"' = 0
			!define USE_PRESIGNED_UNINST
		!endif
	!endif
!endif

;--------------------------------
; Launch flags — REQUIRED for the inline-3D weave to work (displayxr-browser#15 + the
; 2026-07-15 weave investigation). Baked into every launch path (shortcuts + finish-run):
;   --enable-inline-3d                        native weave pipe (browser/GPU weave client)
;   --enable-blink-features=DisplayXRInline3D exposes window.XRDisplayLayer (experimental Blink
;                                             feature, no switch->feature map; without it the JS
;                                             gate inline3DAvailable() is false -> page drops to 2D)
;   --inline-3d-sync-weave                    GPU-resident zero-lag weave submit
;   --disable-features=DelegatedCompositing   the real #16 fix (confirmed by instrumented build):
;                                             delegated compositing decomposes the page into DComp
;                                             visuals and destroys the root render-pass buffers
;                                             (skia_renderer.cc "delegating to the system compositor"),
;                                             so there is NO flattened composited surface for the
;                                             weave to read. Disabling ONLY delegation keeps
;                                             DirectComposition on and routes the root pass to a
;                                             renderer-allocated backing that MaybeWeaveRootRenderPass
;                                             weaves GPU-resident (zero-copy) — strictly better than
;                                             the old --disable-direct-composition (which forced the
;                                             GL CPU-readback path, #17).
!define BROWSER_FLAGS "--enable-inline-3d --enable-blink-features=DisplayXRInline3D --inline-3d-sync-weave --disable-features=DelegatedCompositing"

;--------------------------------
Name "DisplayXR Browser ${VERSION}"
!ifdef INNER
	OutFile "$%TEMP%\DisplayXRBrowser_inner.exe"
	RequestExecutionLevel user
!else
	OutFile "${OUTPUT_DIR}\DisplayXR-Browser-Preview-Setup-${VERSION}.exe"
	RequestExecutionLevel admin
!endif
InstallDir "$PROGRAMFILES64\DisplayXR\Browser"
InstallDirRegKey HKLM "Software\DisplayXR\Browser" "InstallPath"
ShowInstDetails show
ShowUninstDetails show

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"

!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!ifdef LICENSE_FILE
	!insertmacro MUI_PAGE_LICENSE "${LICENSE_FILE}"
!endif
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
; Offer to launch on finish. The installer runs elevated, so we must NOT Exec chrome.exe
; directly (it would inherit High integrity — the OpenXR loader then ignores XR_RUNTIME_JSON and
; the Low-integrity GPU weave process can't be DACL-widened by the Medium service). Launch the
; Start-menu shortcut through explorer.exe instead: explorer is Medium integrity, so chrome runs
; Medium with the shortcut's baked-in ${BROWSER_FLAGS}.
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Launch DisplayXR Browser"
!define MUI_FINISHPAGE_RUN_FUNCTION "LaunchBrowserDeElevated"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

;--------------------------------
; Section 1 — the browser (required)
Section "DisplayXR Browser" SecBrowser
	SectionIn RO
	SetRegView 64
	SetOutPath "$INSTDIR"

	; Kill a running browser so we can overwrite (locked exe/DLLs).
	nsExec::ExecToLog 'taskkill /f /im chrome.exe'
	Pop $0
	Sleep 1500

	; The whole staged tree (chrome.exe + resources + locales + version dir + openxr_loader.dll).
	File /r "${STAGE_DIR}\*.*"

	WriteRegStr HKLM "Software\DisplayXR\Browser" "InstallPath" "$INSTDIR"
	WriteRegStr HKLM "Software\DisplayXR\Browser" "Version" "${VERSION}"

	; Add/Remove Programs.
	!ifdef USE_PRESIGNED_UNINST
		File "/oname=Uninstall.exe" "$%TEMP%\Uninstall.exe"
	!else
		WriteUninstaller "$INSTDIR\Uninstall.exe"
	!endif
	!define ARP "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXR Browser"
	WriteRegStr   HKLM "${ARP}" "DisplayName"     "DisplayXR Browser (Developer Preview)"
	WriteRegStr   HKLM "${ARP}" "DisplayVersion"  "${VERSION}"
	WriteRegStr   HKLM "${ARP}" "Publisher"       "DisplayXR"
	WriteRegStr   HKLM "${ARP}" "DisplayIcon"     "$INSTDIR\chrome.exe"
	WriteRegStr   HKLM "${ARP}" "InstallLocation" "$INSTDIR"
	WriteRegStr   HKLM "${ARP}" "UninstallString"      "$\"$INSTDIR\Uninstall.exe$\""
	WriteRegStr   HKLM "${ARP}" "QuietUninstallString" "$\"$INSTDIR\Uninstall.exe$\" /S"
	WriteRegDWORD HKLM "${ARP}" "NoModify" 1
	WriteRegDWORD HKLM "${ARP}" "NoRepair" 1
	${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
	IntFmt $0 "0x%08X" $0
	WriteRegDWORD HKLM "${ARP}" "EstimatedSize" "$0"

	; Shortcuts — launch chrome with the inline-3D weave flags baked in.
	CreateShortCut "$SMPROGRAMS\DisplayXR Browser.lnk" "$INSTDIR\chrome.exe" "${BROWSER_FLAGS}"
	CreateShortCut "$DESKTOP\DisplayXR Browser.lnk"    "$INSTDIR\chrome.exe" "${BROWSER_FLAGS}"
SectionEnd

;--------------------------------
; Section 2 — chain the DisplayXR runtime + display plug-in (the weave prereqs).
; If a runtime installer is bundled (RUNTIME_SETUP), run it when the runtime isn't
; already present; otherwise just note the requirement (the browser still installs
; and runs 2D). A display plug-in (e.g. Leia) is the vendor's own installer.
Section "DisplayXR runtime (weave prerequisite)" SecRuntime
	SetRegView 64
	ReadRegStr $0 HKLM "Software\DisplayXR\Runtime" "InstallPath"
	${If} $0 != ""
		DetailPrint "DisplayXR runtime already installed at $0 — skipping."
	${Else}
		!ifdef RUNTIME_SETUP
			DetailPrint "Installing bundled DisplayXR runtime…"
			File "/oname=$PLUGINSDIR\DisplayXRSetup.exe" "${RUNTIME_SETUP}"
			; /NOSTART: don't hold plug-in DLLs; the runtime installer registers the
			; Run key + sim-display DP. Silent chain (mirrors the meta-bundle).
			ExecWait '"$PLUGINSDIR\DisplayXRSetup.exe" /S /NOSTART' $1
			DetailPrint "  runtime installer exit: $1"
		!else
			DetailPrint "No DisplayXR runtime found and none bundled — 3D weave will be inactive until a runtime + display plug-in are installed."
		!endif
	${EndIf}
SectionEnd

;--------------------------------
; First-run capability check → one-time "no 3D display" notice (graceful fallback).
; Detects (a) a registered display processor and (b) — if the runtime CLI is present —
; a DP-backed display via `displayxr-cli selftest`. Absent → the weave no-ops and we
; tell the user once. Written as a marker so we never nag twice.
Function .onInstSuccess
	SetRegView 64
	ReadRegStr $2 HKLM "Software\DisplayXR\Browser" "FirstRunNoticeShown"
	${If} $2 == "1"
		Return
	${EndIf}
	WriteRegStr HKLM "Software\DisplayXR\Browser" "FirstRunNoticeShown" "1"

	; (a) any registered display processor?
	StrCpy $3 ""
	EnumRegKey $3 HKLM "Software\DisplayXR\DisplayProcessors" 0

	; (b) if a runtime CLI is present, run the strict selftest (DP + valid display info).
	StrCpy $4 "1"   ; assume no-display unless selftest passes
	ReadRegStr $5 HKLM "Software\DisplayXR\Runtime" "InstallPath"
	${If} $5 != ""
		${AndIf} ${FileExists} "$5\displayxr-cli.exe"
		nsExec::Exec '"$5\displayxr-cli.exe" selftest'
		Pop $4   ; 0 = a DP-backed head + valid display info
	${EndIf}

	${If} $3 == ""
	${OrIf} $4 != "0"
		MessageBox MB_ICONINFORMATION|MB_OK \
"No DisplayXR 3D display detected.$\r$\n$\r$\nDisplayXR Browser will run as an ordinary browser. On a \
DisplayXR 3D display with the runtime and a display plug-in installed, inline-3D web pages weave \
glasses-free automatically.$\r$\n$\r$\nThis is a developer preview — not maintained to Chrome's \
mid-cycle security cadence. Don't use it for sensitive browsing."
	${EndIf}
FunctionEnd

;--------------------------------
Section "Uninstall"
	SetRegView 64
	nsExec::ExecToLog 'taskkill /f /im chrome.exe'
	Pop $0
	Sleep 1000

	; Remove the installed tree. The browser dir is self-contained; recursive delete.
	RMDir /r "$INSTDIR"

	Delete "$SMPROGRAMS\DisplayXR Browser.lnk"
	Delete "$DESKTOP\DisplayXR Browser.lnk"

	DeleteRegKey HKLM "Software\DisplayXR\Browser"
	DeleteRegKey /ifempty HKLM "Software\DisplayXR"
	DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\DisplayXR Browser"

	; NOTE: we intentionally do NOT uninstall the DisplayXR runtime / display plug-in —
	; they are shared prerequisites other DisplayXR apps may depend on.
SectionEnd

;--------------------------------
; Finish-page launch: run the Start-menu shortcut via explorer.exe so chrome starts at Medium
; integrity (not the installer's High) with the shortcut's baked-in ${BROWSER_FLAGS}.
Function LaunchBrowserDeElevated
	Exec 'explorer.exe "$SMPROGRAMS\DisplayXR Browser.lnk"'
FunctionEnd

;--------------------------------
Function .onInit
!ifdef INNER
	SetSilent silent
	WriteUninstaller "$%TEMP%\Uninstall.exe"
	Quit
!endif
	${IfNot} ${RunningX64}
		MessageBox MB_ICONSTOP "DisplayXR Browser requires 64-bit Windows."
		Abort
	${EndIf}
FunctionEnd

;--------------------------------
VIProductVersion "0.0.0.0"
VIAddVersionKey "ProductName"    "DisplayXR Browser"
VIAddVersionKey "CompanyName"    "DisplayXR"
VIAddVersionKey "LegalCopyright" "Copyright (c) 2026 DisplayXR"
VIAddVersionKey "FileDescription" "DisplayXR Browser (Developer Preview) Installer"
VIAddVersionKey "FileVersion"    "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
