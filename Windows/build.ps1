[CmdletBinding()]
param(
    [ValidateSet('Debug','Release')][string]$Configuration = 'Release',
    [string]$PackagesDirectory = (Join-Path $PSScriptRoot 'packages'),
    [switch]$Test,
    [string]$MediaDirectory = (Join-Path $PSScriptRoot '..\Media')
)
$ErrorActionPreference = 'Stop'
$PackagesDirectory = [IO.Path]::GetFullPath($PackagesDirectory)
$finder = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $finder -latest -products '*' -version '[18.0,19.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vs) { throw 'Visual Studio 2026 with the Desktop development with C++ workload is required.' }
$toolsPath = Join-Path $PSScriptRoot '.tools'
$null = New-Item -ItemType Directory -Force -Path $toolsPath
$nuget = Join-Path $toolsPath 'nuget.exe'
if (!(Test-Path -LiteralPath $nuget)) {
    Invoke-WebRequest 'https://dist.nuget.org/win-x86-commandline/v8.0.0/nuget.exe' -OutFile $nuget -UseBasicParsing
}
$expectedHash = 'D4DDB222CB8FCA8200B59E82286C0CBA9C29B4FCE6F9835FDFA54E67C9483D07'
if ((Get-FileHash -LiteralPath $nuget).Hash -ne $expectedHash) { throw 'NuGet executable checksum mismatch.' }
& $nuget install (Join-Path $PSScriptRoot 'packages.config') -OutputDirectory $PackagesDirectory -Source 'https://api.nuget.org/v3/index.json' -NonInteractive -Verbosity quiet
if ($LASTEXITCODE) { throw "NuGet restore failed ($LASTEXITCODE)." }
$msbuild = Join-Path $vs 'MSBuild\Current\Bin\amd64\MSBuild.exe'
& $msbuild (Join-Path $PSScriptRoot 'Forma.vcxproj') /nologo /v:minimal "/p:Configuration=$Configuration" /p:Platform=x64 "/p:PackagesDir=$PackagesDirectory"
if ($LASTEXITCODE) { throw "MSBuild failed ($LASTEXITCODE)." }
$output = Join-Path $PSScriptRoot "bin\x64\$Configuration"
$redistRoot = Join-Path $vs 'VC\Redist\MSVC'
$redist = Get-ChildItem -LiteralPath $redistRoot -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending | ForEach-Object {
    Get-ChildItem -Path (Join-Path $_.FullName 'x64\Microsoft.VC*.CRT') -Directory
} | Select-Object -First 1
if (!$redist) { throw 'The x64 Microsoft Visual C++ redistributable files were not found.' }
Get-ChildItem -LiteralPath $redist.FullName -Filter '*.dll' | Copy-Item -Destination $output -Force
$notices = New-Item -ItemType Directory -Force -Path (Join-Path $output 'Licenses')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LICENSE') -Destination (Join-Path $notices 'Forma.txt')
$runtimePkg = Join-Path $PackagesDirectory 'Microsoft.WindowsAppSDK.Runtime.1.8.260921001'
Copy-Item -LiteralPath (Join-Path $runtimePkg 'NOTICE.txt') -Destination (Join-Path $notices 'WindowsAppSDK-NOTICE.txt')
Copy-Item -LiteralPath (Join-Path $runtimePkg 'license.txt') -Destination (Join-Path $notices 'WindowsAppSDK-LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'JSON-LICENSE.txt') -Destination $notices
$exe = Join-Path $output 'Forma.exe'
if ($Test) {
    $fixtures = (Resolve-Path -LiteralPath $MediaDirectory).Path
    $checkRoot = Join-Path $PSScriptRoot 'obj\checks'
    $testDir = New-Item -ItemType Directory -Force -Path (Join-Path $checkRoot ([guid]::NewGuid()))
    $process = Start-Process $exe -WindowStyle Hidden -PassThru -ArgumentList @('--self-test', ('"{0}"' -f $fixtures), ('"{0}"' -f $testDir.FullName))
    if (!$process.WaitForExit(90000)) { $process.Kill(); throw 'Editor self-test timed out.' }
    $report = Join-Path $testDir 'passed.txt'
    if ($process.ExitCode -ne 0 -or !(Test-Path -LiteralPath $report)) {
        $failure = Join-Path $testDir 'failure.txt'
        if (Test-Path -LiteralPath $failure) { Get-Content -LiteralPath $failure }
        throw "Editor self-test failed. Diagnostics: $testDir"
    }
    Get-Content -LiteralPath $report
}
Write-Output $exe
