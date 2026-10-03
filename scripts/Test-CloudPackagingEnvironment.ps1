Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'This diagnostic runs only on a GitHub-hosted Windows runner. It does not install Unreal Engine on a local computer.'
}

$expectedRevision = 'b7ac82de0b64ef3eff744b7c4d6ca22c95d12757'
$sdkRoot = Join-Path $env:GITHUB_WORKSPACE 'sdk'
$actualRevision = (& git -C $sdkRoot rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read the official SDK revision.'
}

$computer = Get-CimInstance Win32_ComputerSystem
$disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' | ForEach-Object {
    [ordered]@{
        drive = $_.DeviceID
        totalGiB = [math]::Round($_.Size / 1GB, 2)
        freeGiB = [math]::Round($_.FreeSpace / 1GB, 2)
    }
})

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$compilerInstallations = @()
if (Test-Path -LiteralPath $vswhere) {
    $compilerInstallations = @(& $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    if ($LASTEXITCODE -ne 0) {
        throw 'Visual Studio compiler discovery failed.'
    }
}

$windowsSdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib'
$windowsSdkVersions = @()
if (Test-Path -LiteralPath $windowsSdkRoot) {
    $windowsSdkVersions = @(Get-ChildItem -LiteralPath $windowsSdkRoot -Directory | Select-Object -ExpandProperty Name)
}

$engineRoot = Join-Path $env:RUNNER_TEMP 'UE_5.5'
$engineFiles = @(
    'Engine\Build\Build.version',
    'Engine\Binaries\Win64\UnrealEditor-Cmd.exe',
    'Engine\Build\BatchFiles\Build.bat',
    'Engine\Build\BatchFiles\RunUAT.bat'
)
$missingEngineFiles = @($engineFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $engineRoot $_)) })
$blockers = @()
if ($actualRevision -ne $expectedRevision) {
    $blockers += 'Official SDK revision does not match the pinned snapshot.'
}
if (-not (Test-Path -LiteralPath (Join-Path $sdkRoot 'Content\Mods\RecipeSwitcher\ModBase.uasset'))) {
    $blockers += 'Official RecipeSwitcher ModBase asset is missing.'
}
if ($compilerInstallations.Count -eq 0) {
    $blockers += 'Visual Studio C++ compiler is missing.'
}
if ($windowsSdkVersions.Count -eq 0) {
    $blockers += 'Windows SDK is missing.'
}
if ($missingEngineFiles.Count -gt 0) {
    $blockers += 'An authorized Unreal Engine 5.5 Windows toolchain has not been provisioned. Engine acquisition is not configured.'
}

$report = [ordered]@{
    checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    workflowRunId = $env:GITHUB_RUN_ID
    runnerImage = $env:ImageOS
    logicalProcessors = $computer.NumberOfLogicalProcessors
    memoryGiB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 2)
    disks = $disks
    sdkRevision = $actualRevision
    compilerInstallations = $compilerInstallations
    windowsSdkVersions = $windowsSdkVersions
    engineRoot = $engineRoot
    missingEngineFiles = $missingEngineFiles
    blockers = $blockers
    status = 'prerequisites-inspected'
    packagingAttempted = $false
    modPackageProduced = $false
}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $env:GITHUB_WORKSPACE 'preflight.json') -Encoding utf8

$summary = @(
    '# OddModKit cloud packaging prerequisite probe',
    '',
    "- Official SDK revision: ``$actualRevision``",
    "- CPU threads: $($report.logicalProcessors)",
    "- Memory: $($report.memoryGiB) GiB",
    "- C++ compiler installations: $($compilerInstallations.Count)",
    "- Windows SDK versions: $($windowsSdkVersions -join ', ')",
    '',
    '## Actual runner disk space'
)
foreach ($disk in $disks) {
    $summary += "- $($disk.drive): $($disk.freeGiB) GiB free / $($disk.totalGiB) GiB total"
}
$summary += @('', '## Blocking prerequisites')
foreach ($blocker in $blockers) {
    $summary += "- $blocker"
}
$summary += @('', '**This is only a prerequisite probe. Mod cooking and packaging have not run, and no installable mod has been produced.**')
$summary | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8

if ($blockers.Count -gt 0) {
    throw ('Packaging prerequisites are blocked: ' + ($blockers -join ' '))
}

Write-Host 'Prerequisite inspection finished. This workflow does not build or package a mod.'
