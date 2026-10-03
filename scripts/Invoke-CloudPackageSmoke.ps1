param(
    [Parameter(Mandatory)]
    [ValidateSet('Fetch', 'Dependencies', 'Tools', 'Editor', 'Package', 'Verify')]
    [string]$Phase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'Engine acquisition and building are allowed only on the cloud Windows runner.'
}

$engineRevision = '585df42eb3a391efd295abd231333df20cddbcf3'
$sdkRevision = 'b7ac82de0b64ef3eff744b7c4d6ca22c95d12757'
$engineRoot = Join-Path $env:RUNNER_TEMP 'ue551'
$logRoot = Join-Path $env:RUNNER_TEMP 'package-smoke-private-logs'
$sdkRoot = Join-Path $env:GITHUB_WORKSPACE 'sdk'
$reportPath = Join-Path $env:GITHUB_WORKSPACE 'package-report.json'
$archiveRoot = Join-Path $sdkRoot 'Saved\StagedMods'
$projectPath = Join-Path $sdkRoot 'Loc.uproject'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

$report = [ordered]@{
    runId = $env:GITHUB_RUN_ID
    engineRevision = $engineRevision
    sdkRevision = $sdkRevision
    currentPhase = $Phase
    status = 'running'
    phases = @()
    commands = @()
    modPackageProduced = $false
}
if (Test-Path -LiteralPath $reportPath) {
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -AsHashtable
    $report.currentPhase = $Phase
    $report.status = 'running'
}

function Save-Report {
    $script:report.diskFreeGiB = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' | ForEach-Object {
        @{ drive = $_.DeviceID; freeGiB = [math]::Round($_.FreeSpace / 1GB, 2) }
    })
    $script:report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
}

function Invoke-BuildCommand {
    param([string]$Name, [string]$Program, [string[]]$Arguments)
    $logPath = Join-Path $logRoot "$Name.txt"
    $started = [DateTime]::UtcNow
    Write-Host "Starting $Name. Raw output stays in the ephemeral runner and is not published."
    Push-Location $engineRoot
    try {
        & $Program @Arguments *> $logPath
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $command = @{ name = $Name; exitCode = $exitCode; elapsedMinutes = [math]::Round(([DateTime]::UtcNow - $started).TotalMinutes, 2) }
    if ($exitCode -ne 0) {
        $tail = Get-Content -LiteralPath $logPath -Tail 150 | Out-String
        $command.errorCodes = @([regex]::Matches($tail, '\b(?:C\d{4}|MSB\d{4}|NU\d{4})\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
        $command.errorFiles = @([regex]::Matches($tail, '[\w.-]+\.(?:cpp|h|cs)\(\d+(?:,\d+)?\)') | ForEach-Object { $_.Value } | Select-Object -Unique -First 8)
        $command.errorCategories = @(@('error', 'exception', 'out of memory', 'disk full', 'not enough space', 'not found', 'missing', 'failed', '403', '404', 'certificate', 'hash mismatch') | Where-Object { $tail -match [regex]::Escape($_) })
    }
    $script:report.commands += $command
    Save-Report
    Write-Host "$Name exited with $exitCode after $($command.elapsedMinutes) minutes."
    if ($exitCode -ne 0) {
        throw "Cloud build command $Name failed with exit code $exitCode. See the redacted package report."
    }
}

Save-Report
$phaseStarted = [DateTime]::UtcNow
try {
    switch ($Phase) {
        'Fetch' {
            if ([string]::IsNullOrWhiteSpace($env:UE_SOURCE_ARCHIVE_URL)) {
                throw 'The short-lived official source archive URL is missing. Start a fresh authorized run.'
            }
            $archiveUri = [uri]$env:UE_SOURCE_ARCHIVE_URL
            if ($archiveUri.Scheme -ne 'https' -or $archiveUri.Host -ne 'codeload.github.com' -or -not $archiveUri.AbsolutePath.EndsWith("/EpicGames/UnrealEngine/legacy.zip/$engineRevision", [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Source download is not the fixed official engine archive.'
            }
            $archivePath = Join-Path $env:RUNNER_TEMP 'ue551-source.zip'
            & curl.exe --fail --silent --show-error --location --connect-timeout 30 --max-time 1200 --output $archivePath $archiveUri.AbsoluteUri 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw 'Official source archive download failed or its five-minute authorization expired. No download URL is logged.'
            }
            $env:UE_SOURCE_ARCHIVE_URL = $null
            New-Item -ItemType Directory -Path $engineRoot -Force | Out-Null
            & tar.exe -xf $archivePath -C $engineRoot --strip-components=1 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'Official source extraction failed.' }
            $resolvedArchive = [IO.Path]::GetFullPath($archivePath)
            $temporaryPrefix = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\') + '\'
            if (-not $resolvedArchive.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive cleanup path is outside runner temp.' }
            Remove-Item -LiteralPath $resolvedArchive
            $version = Get-Content -LiteralPath (Join-Path $engineRoot 'Engine\Build\Build.version') -Raw | ConvertFrom-Json
            if ($version.MajorVersion -ne 5 -or $version.MinorVersion -ne 5 -or $version.PatchVersion -ne 1) { throw 'Unexpected engine version.' }
            $report.engineVersion = '5.5.1'
        }
        'Dependencies' {
            $actualSdkRevision = (& git -C $sdkRoot rev-parse HEAD | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $actualSdkRevision -ne $sdkRevision) { throw 'Official SDK revision mismatch.' }
            $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
            $visualStudioRoot = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Out-String).Trim()
            if (-not $visualStudioRoot) { throw 'Visual Studio C++ tools are missing.' }
            $toolchains = @(Get-ChildItem -LiteralPath (Join-Path $visualStudioRoot 'VC\Tools\MSVC') -Directory | Where-Object { $_.Name -like '14.38.*' } | Sort-Object Name -Descending)
            if ($toolchains.Count -eq 0) {
                $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
                if (-not (Test-Path -LiteralPath $installer)) { throw 'The cloud Visual Studio component installer is missing.' }
                Write-Host 'Installing the official MSVC 14.38 component on the ephemeral cloud runner only.'
                $compilerInstall = Start-Process -FilePath $installer -ArgumentList @('modify', '--installPath', "`"$visualStudioRoot`"", '--add', 'Microsoft.VisualStudio.Component.VC.14.38.17.8.x86.x64', '--quiet', '--norestart', '--nocache') -WorkingDirectory $engineRoot -WindowStyle Hidden -Wait -PassThru
                $report.compilerInstallerExitCode = $compilerInstall.ExitCode
                Save-Report
                if ($compilerInstall.ExitCode -notin @(0, 3010)) { throw 'Official cloud MSVC component installation failed.' }
                $toolchains = @(Get-ChildItem -LiteralPath (Join-Path $visualStudioRoot 'VC\Tools\MSVC') -Directory | Where-Object { $_.Name -like '14.38.*' } | Sort-Object Name -Descending)
                if ($toolchains.Count -eq 0) { throw 'MSVC 14.38 remains unavailable after cloud installation.' }
            }
            $compilerVersion = $toolchains[0].Name
            $sdkVersion = '10.0.22621.0'
            if (-not (Test-Path -LiteralPath (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Lib\$sdkVersion"))) { throw 'Windows SDK 10.0.22621.0 is missing.' }
            $configurationRoot = Join-Path $env:APPDATA 'Unreal Engine\UnrealBuildTool'
            New-Item -ItemType Directory -Path $configurationRoot -Force | Out-Null
            @"
<?xml version="1.0" encoding="utf-8"?>
<Configuration xmlns="https://www.unrealengine.com/BuildConfiguration">
  <BuildConfiguration>
    <MaxParallelActions>3</MaxParallelActions>
    <bAllowUBAExecutor>false</bAllowUBAExecutor>
    <bAllowUBALocalExecutor>false</bAllowUBALocalExecutor>
    <bAllowXGE>false</bAllowXGE>
    <bAllowFASTBuild>false</bAllowFASTBuild>
    <bAllowSNDBS>false</bAllowSNDBS>
  </BuildConfiguration>
  <WindowsPlatform>
    <CompilerVersion>$compilerVersion</CompilerVersion>
    <WindowsSdkVersion>$sdkVersion</WindowsSdkVersion>
  </WindowsPlatform>
</Configuration>
"@ | Set-Content -LiteralPath (Join-Path $configurationRoot 'BuildConfiguration.xml') -Encoding utf8
            $report.compilerVersion = $compilerVersion
            $report.windowsSdkVersion = $sdkVersion
            Save-Report
            $dependencyTool = Join-Path $engineRoot 'Engine\Binaries\DotNET\GitDependencies\win-x64\GitDependencies.exe'
            Invoke-BuildCommand -Name 'win64-dependencies' -Program $dependencyTool -Arguments @('--force', '--no-cache', '--threads=4', "--root=$engineRoot", '--exclude=Linux', '--exclude=LinuxArm64', '--exclude=Mac', '--exclude=Android', '--exclude=IOS', '--exclude=TVOS')
        }
        'Tools' {
            $buildTool = Join-Path $engineRoot 'Engine\Build\BatchFiles\Build.bat'
            foreach ($target in @('ShaderCompileWorker', 'UnrealPak')) {
                Invoke-BuildCommand -Name "build-$target" -Program $buildTool -Arguments @($target, 'Win64', 'Development', '-NoUBA', '-NoUBALocal', '-NoDebugInfo', '-MaxParallelActions=3')
            }
        }
        'Editor' {
            Invoke-BuildCommand -Name 'build-LocEditor' -Program (Join-Path $engineRoot 'Engine\Build\BatchFiles\Build.bat') -Arguments @('LocEditor', 'Win64', 'Development', "-Project=$projectPath", '-NoUBA', '-NoUBALocal', '-NoDebugInfo', '-MaxParallelActions=3')
            if (-not (Test-Path -LiteralPath (Join-Path $engineRoot 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe'))) { throw 'The compiled commandlet editor is missing.' }
        }
        'Package' {
            Invoke-BuildCommand -Name 'cook-package-Windows' -Program (Join-Path $engineRoot 'Engine\Build\BatchFiles\RunUAT.bat') -Arguments @('BuildCookRun', '-nop4', '-utf8output', '-unattended', '-nocompileeditor', '-skipbuildeditor', '-cook', "-project=$projectPath", '-target=LocGame', "-unrealexe=$(Join-Path $engineRoot 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe')", '-platform=Win64', '-stage', '-archive', '-package', '-build', '-pak', '-iostore', "-archivedirectory=$archiveRoot", '-manifests', '-clientconfig=Development', '-NoDebugInfo', '-nullrhi')
        }
        'Verify' {
            $pakRoot = Join-Path $archiveRoot 'Windows\Loc\Content\Paks'
            $pakStem = 'pakchunk12-Windows'
            $outputRoot = Join-Path $env:GITHUB_WORKSPACE 'dist\RecipeSwitcher'
            $nativeFiles = @('.pak', '.utoc', '.ucas') | ForEach-Object { Join-Path $pakRoot "$pakStem$_" }
            foreach ($nativeFile in $nativeFiles) {
                if (-not (Test-Path -LiteralPath $nativeFile) -or (Get-Item -LiteralPath $nativeFile).Length -eq 0) { throw 'A required native mod container is missing or empty.' }
            }
            $pakTool = Join-Path $engineRoot 'Engine\Binaries\Win64\UnrealPak.exe'
            Invoke-BuildCommand -Name 'verify-pak-integrity' -Program $pakTool -Arguments @($nativeFiles[0], '-Test')
            Invoke-BuildCommand -Name 'list-mod-registry' -Program $pakTool -Arguments @($nativeFiles[0], '-List')
            $pakListing = Get-Content -LiteralPath (Join-Path $logRoot 'list-mod-registry.txt') -Raw
            if ($pakListing -notmatch 'RecipeSwitcher' -or $pakListing -notmatch 'AssetRegistry') { throw 'Expected per-mod asset registry was not found in the cooked pak.' }
            New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
            foreach ($nativeFile in $nativeFiles) { Copy-Item -LiteralPath $nativeFile -Destination $outputRoot }
            $manifest = [ordered]@{ name = 'Recipe Switcher'; id = 'RecipeSwitcher'; author = 'Massive Miniteam GmbH'; version = '1.0'; gameVersion = '1.0'; dependencies = @(); lastUpdated = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString(); bAchievementsAllowed = $true }
            $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outputRoot 'RecipeSwitcher.manifest') -Encoding utf8
            Copy-Item -LiteralPath (Join-Path $env:GITHUB_WORKSPACE 'PACKAGE-NOTES.md') -Destination $outputRoot
            $checksums = @(Get-ChildItem -LiteralPath $outputRoot -File | Sort-Object Name | ForEach-Object { "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.Name)" })
            $checksums | Set-Content -LiteralPath (Join-Path $outputRoot 'SHA256SUMS.txt') -Encoding utf8
            $report.files = @(Get-ChildItem -LiteralPath $outputRoot -File | ForEach-Object { @{ name = $_.Name; bytes = $_.Length } })
            $report.modPackageProduced = $true
            $report.status = 'packaging-verified-game-test-pending'
        }
    }
    $report.phases += @{ name = $Phase; status = 'success'; elapsedMinutes = [math]::Round(([DateTime]::UtcNow - $phaseStarted).TotalMinutes, 2) }
    Save-Report
    "- $Phase completed in $($report.phases[-1].elapsedMinutes) minutes." | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
} catch {
    $report.status = 'failed'
    $report.phases += @{ name = $Phase; status = 'failed'; elapsedMinutes = [math]::Round(([DateTime]::UtcNow - $phaseStarted).TotalMinutes, 2) }
    Save-Report
    "- $Phase failed. No completed mod package is claimed; private source, tokens and raw build logs are not artifacts." | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    throw
}
