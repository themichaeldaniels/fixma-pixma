param(
    [string]$FlutterRoot = (Join-Path $PSScriptRoot '../../work/tooling/flutter'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../../outputs')
)
$ErrorActionPreference = 'Stop'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$appRoot = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content -LiteralPath (Join-Path $appRoot 'pubspec.yaml') -Raw
if ($manifest -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)(?:\+[0-9]+)?\s*$') { throw 'Missing application version.' }
$releaseVersion = $Matches[1]
$flutter = Join-Path $FlutterRoot 'bin/flutter.bat'
$dart = Join-Path $FlutterRoot 'bin/dart.bat'
if (-not (Test-Path -LiteralPath $flutter)) { throw 'Set -FlutterRoot to a Flutter stable SDK folder.' }
Push-Location $appRoot
try {
    & $flutter pub get
    if ($LASTEXITCODE) { throw 'Dependency resolution failed.' }
    $outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    $analysisLog = Join-Path $outputRoot "PixmaFixa-$releaseVersion-analysis-final.log"
    $testLog = Join-Path $outputRoot "PixmaFixa-$releaseVersion-tests-final.log"
    & $flutter analyze --no-pub *> $analysisLog
    if ($LASTEXITCODE) { throw 'Static analysis failed.' }
    & $flutter test --no-pub --coverage *> $testLog
    if ($LASTEXITCODE) { throw 'Tests failed.' }
    New-Item -ItemType Directory -Path build/native -Force | Out-Null
    New-Item -ItemType Directory -Path build/symbols -Force | Out-Null
    # Use a machine temporary directory so entry URIs contain no user profile path.
    $helperTempBase = [Environment]::GetEnvironmentVariable('TEMP', 'Machine')
    if (-not $helperTempBase) { $helperTempBase = Join-Path $env:WINDIR 'Temp' }
    $helperTempBase = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($helperTempBase))
    if ($helperTempBase.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) { throw 'Native helper compilation requires a temporary directory outside the user profile.' }
    $helperPrefix = Join-Path $helperTempBase ('PixmaFixa-native-' + [Guid]::NewGuid().ToString('N'))
    $usbEntry = "$helperPrefix-printer_worker.dart"
    $queueEntry = "$helperPrefix-queue_worker.dart"
    Copy-Item -LiteralPath bin/printer_worker.dart -Destination $usbEntry
    Copy-Item -LiteralPath bin/queue_worker.dart -Destination $queueEntry
    $packages = Join-Path $appRoot '.dart_tool/package_config.json'
    & $dart compile exe "--packages=$packages" $usbEntry -S build/symbols/pixma_fixa_worker.debug -o build/native/pixma_fixa_worker.exe
    if ($LASTEXITCODE) { throw 'Native helper compilation failed.' }
    & $dart compile exe "--packages=$packages" $queueEntry -S build/symbols/pixma_fixa_queue.debug -o build/native/pixma_fixa_queue.exe
    if ($LASTEXITCODE) { throw 'Queue helper compilation failed.' }
    & $flutter build windows --release --no-pub --split-debug-info=build/symbols
    if ($LASTEXITCODE) { throw 'Windows compilation failed.' }
    Copy-Item -LiteralPath build/native/pixma_fixa_worker.exe -Destination build/windows/x64/runner/Release
    Copy-Item -LiteralPath build/native/pixma_fixa_queue.exe -Destination build/windows/x64/runner/Release
    $out = Join-Path $outputRoot "PixmaFixa-Windows-$releaseVersion"
    if (Test-Path -LiteralPath $out) { throw "Release directory already exists. Use a new version or move the previous package: $out" }
    New-Item -ItemType Directory -Path $out | Out-Null
    $executables = @('pixma_fixa.exe', 'pixma_fixa_worker.exe', 'pixma_fixa_queue.exe')
    Get-ChildItem -LiteralPath build/windows/x64/runner/Release | Where-Object {
        $_.Extension -ne '.pdb' -and ($_.Extension -ne '.exe' -or $_.Name -in $executables)
    } | Copy-Item -Destination $out -Recurse
    Copy-Item -LiteralPath START-HERE.txt,PENDING-WORK.txt,THIRD_PARTY_NOTICES.txt,LICENSE,README.md,TESTING.md,VALIDATION.md,BETA-NOTES.md,SUPPORT.md,REVIEW.md -Destination $out
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $redist = Join-Path $vs 'VC/Redist/MSVC'
    $runtime = Get-ChildItem -LiteralPath $redist -Directory | Where-Object Name -Match '^\d+\.' | Sort-Object Name -Descending | Select-Object -First 1
    $crt = Get-ChildItem -LiteralPath (Join-Path $runtime.FullName 'x64') -Directory | Where-Object Name -Like '*.CRT' | Select-Object -First 1
    if (-not $crt) { throw 'The Visual C++ redistributable runtime was not found.' }
    foreach ($dll in @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')) { Copy-Item -LiteralPath (Join-Path $crt.FullName $dll) -Destination $out }
    $zip = "$out.zip"
    Compress-Archive -LiteralPath $out -DestinationPath $zip -Force
    $testKit = Join-Path $outputRoot "PixmaFixa-Clean-Windows-Test-Kit-$releaseVersion"
    if (Test-Path -LiteralPath $testKit) { throw 'The clean Windows test kit directory already exists.' }
    New-Item -ItemType Directory -Path $testKit | Out-Null
    Copy-Item -LiteralPath tool/Invoke-CleanWindowsTest.ps1,tool/New-SandboxTest.ps1,tool/CLEAN-WINDOWS-TEST.txt -Destination $testKit
    Compress-Archive -LiteralPath $testKit -DestinationPath "$testKit.zip" -Force
    Write-Output "Portable app: $out"
    Write-Output "Archive: $zip"
} finally {
    foreach ($entry in @($usbEntry, $queueEntry)) {
        if ($entry -and (Test-Path -LiteralPath $entry)) {
            try { Remove-Item -LiteralPath $entry -Force -ErrorAction Stop }
            catch { Write-Warning 'A temporary compiler entry could not be removed. The packaged build is unaffected.' }
        }
    }
    Pop-Location
}
