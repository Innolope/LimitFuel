; Removes open-at-login on uninstall. An update also runs the old uninstaller
; (with /UPDATE), and must keep the user's choice.
!macro NSIS_HOOK_POSTUNINSTALL
  ${If} $UpdateMode <> 1
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "LimitFuel"
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" "LimitFuel"
  ${EndIf}
!macroend
