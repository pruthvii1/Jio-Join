$ErrorActionPreference = 'Stop'
$Source = Split-Path -Parent $MyInvocation.MyCommand.Path
$Target = Join-Path $env:LOCALAPPDATA 'Programs\JioJoin Desktop'
$Shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'JioJoin Desktop.lnk'
if (-not (Test-Path (Join-Path $Source 'jiojoin-engine.exe'))) { throw 'Run from the extracted Windows package.' }
New-Item -ItemType Directory -Path $Target -Force | Out-Null
Copy-Item (Join-Path $Source '*') $Target -Exclude 'Install.ps1' -Force
$Shell = New-Object -ComObject WScript.Shell
$Link = $Shell.CreateShortcut($Shortcut)
$Link.TargetPath = 'powershell.exe'
$Link.Arguments = '-NoProfile -ExecutionPolicy RemoteSigned -File "' + (Join-Path $Target 'JioJoinDesktop.ps1') + '"'
$Link.WorkingDirectory = $Target
$Link.Save()
Write-Output "Installed for the current user at $Target. No credentials were persisted."
