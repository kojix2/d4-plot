#!/usr/bin/env bash
set -euo pipefail
binary=${1:?Executable path required}
headers=$(objdump -p "$binary")
printf '%s\n' "$headers" | grep -E 'Subsystem|DLL Name'
grep -Eq 'Subsystem[[:space:]]+00000002' <<< "$headers" || {
  echo 'Expected the Windows GUI subsystem (no console window).' >&2; exit 1;
}
# Fail closed: any non-system import requires a deliberate packaging decision.
while read -r dll; do
  case ${dll,,} in
    kernel32.dll|user32.dll|gdi32.dll|comdlg32.dll|comctl32.dll|ole32.dll|oleaut32.dll|uuid.dll|shell32.dll|shlwapi.dll|advapi32.dll|ws2_32.dll|bcrypt.dll|crypt32.dll|secur32.dll|ntdll.dll|ucrtbase.dll|msvcrt.dll|d2d1.dll|dwrite.dll|dwmapi.dll|uxtheme.dll|windowscodecs.dll|version.dll|winmm.dll|imm32.dll|iphlpapi.dll|api-ms-win-*.dll) ;;
    *) echo "Unexpected DLL dependency: $dll" >&2; exit 1 ;;
  esac
done < <(printf '%s\n' "$headers" | awk '/DLL Name:/{print $3}')
