$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Source = Join-Path $Root 'build\headless\windows-x86_64'
$Stage = Join-Path $Root 'build\package-windows-x86_64'
$Archive = Join-Path $Root 'dist\JioJoin-Desktop-0.8.0-windows-x86_64.zip'
if (-not (Test-Path (Join-Path $Source 'jiojoin-engine.exe'))) { throw 'Build the Windows engine first.' }
if (Test-Path $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage, (Split-Path $Archive) -Force | Out-Null
Copy-Item (Join-Path $Source '*') $Stage
Copy-Item (Join-Path $Root 'windows\JioJoinDesktop.ps1') $Stage
Copy-Item (Join-Path $Root 'windows\Install.ps1') $Stage
Copy-Item (Join-Path $Root 'windows\Uninstall.ps1') $Stage
Copy-Item (Join-Path $Root 'LICENSE.md') $Stage
$OriginalPath = $env:PATH
try {
    $env:PATH = "$Stage;$env:SystemRoot\System32;$env:SystemRoot"
    $ErrorActionPreference = 'Continue'
    $SelfTestOutput = & (Join-Path $Stage 'jiojoin-engine.exe') --self-test 2>$null
    $SelfTestExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $SelfTestLine = $SelfTestOutput |
        Where-Object { $_ -like '{"event":"self-test"*' } |
        Select-Object -Last 1
    if ($SelfTestExitCode -ne 0 -or -not $SelfTestLine) { throw 'Packaged Windows engine self-test failed.' }
    $SelfTest = $SelfTestLine | ConvertFrom-Json
    if (-not $SelfTest.tls -or -not $SelfTest.amr -or -not $SelfTest.amr_wb) {
        throw 'Packaged Windows engine is missing TLS or AMR support.'
    }
    if ($SelfTest.platform -ne 'windows' -or $SelfTest.architecture -ne 'x86_64') {
        throw 'Packaged engine has the wrong platform or architecture.'
    }
}
finally {
    $env:PATH = $OriginalPath
}
Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $Archive -Force
$Hash = (Get-FileHash -Algorithm SHA256 $Archive).Hash.ToLowerInvariant()
Write-Output "$Archive`nsha256=$Hash"
