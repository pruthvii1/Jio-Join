$ErrorActionPreference = 'Stop'
$Target = Join-Path $env:LOCALAPPDATA 'Programs\JioJoin Desktop'
$Shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'JioJoin Desktop.lnk'
Remove-Item -LiteralPath $Shortcut -Force -ErrorAction SilentlyContinue
if ((Test-Path $Target) -and ($Target -like "$(Join-Path $env:LOCALAPPDATA 'Programs')*")) {
  Remove-Item -LiteralPath $Target -Recurse -Force
}
Write-Output 'Removed JioJoin application files. No reusable SIP credentials were stored.'
