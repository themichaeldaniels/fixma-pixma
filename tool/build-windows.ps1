param([string]$FlutterRoot = (Join-Path $PSScriptRoot '../../work/tooling/flutter'))
$ErrorActionPreference = 'Stop'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$appRoot = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content -LiteralPath (Join-Path $appRoot 'pubspec.yaml') -Raw
if ($manifest -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') { throw 'Missing application version.' }
$releaseVersion = $Matches[1]
$flutter = Join-Path $FlutterRoot 'bin/flutter.bat'
$dart = Join-Path $FlutterRoot 'bin/dart.bat'
if (-not (Test-Path -LiteralPath $flutter)) { throw 'Set -FlutterRoot to a Flutter stable SDK folder.' }
Push-Location $appRoot
try {
    & $flutter pub get
    if ($LASTEXITCODE) { throw 'Dependency resolution failed.' }
    $outputRoot = Join-Path (Split-Path $appRoot -Parent) 'outputs'
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    $analysisLog = Join-Path $outputRoot "PrinterCare-$releaseVersion-analysis-final.log"
    $testLog = Join-Path $outputRoot "PrinterCare-$releaseVersion-tests-final.log"
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
    $helperPrefix = Join-Path $helperTempBase ('PrinterCare-native-' + [Guid]::NewGuid().ToString('N'))
    $usbEntry = "$helperPrefix-printer_worker.dart"
    $queueEntry = "$helperPrefix-queue_worker.dart"
    Copy-Item -LiteralPath bin/printer_worker.dart -Destination $usbEntry
    Copy-Item -LiteralPath bin/queue_worker.dart -Destination $queueEntry
    $packages = Join-Path $appRoot '.dart_tool/package_config.json'
    & $dart compile exe "--packages=$packages" $usbEntry -S build/symbols/printer_care_worker.debug -o build/native/printer_care_worker.exe
    if ($LASTEXITCODE) { throw 'Native helper compilation failed.' }
    & $dart compile exe "--packages=$packages" $queueEntry -S build/symbols/printer_care_queue.debug -o build/native/printer_care_queue.exe
    if ($LASTEXITCODE) { throw 'Queue helper compilation failed.' }
    & $flutter build windows --release --no-pub --split-debug-info=build/symbols
    if ($LASTEXITCODE) { throw 'Windows compilation failed.' }
    Copy-Item -LiteralPath build/native/printer_care_worker.exe -Destination build/windows/x64/runner/Release
    Copy-Item -LiteralPath build/native/printer_care_queue.exe -Destination build/windows/x64/runner/Release
    $out = Join-Path $outputRoot "PrinterCare-Windows-$releaseVersion"
    if (Test-Path -LiteralPath $out) { throw "Release directory already exists. Use a new version or move the previous package: $out" }
    New-Item -ItemType Directory -Path $out | Out-Null
    Get-ChildItem -LiteralPath build/windows/x64/runner/Release | Where-Object { $_.Extension -ne '.pdb' } | Copy-Item -Destination $out -Recurse
    Copy-Item -LiteralPath START-HERE.txt,PENDING-WORK.txt,THIRD_PARTY_NOTICES.txt,LICENSE,README.md,TESTING.md,VALIDATION.md -Destination $out
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $redist = Join-Path $vs 'VC/Redist/MSVC'
    $runtime = Get-ChildItem -LiteralPath $redist -Directory | Where-Object Name -Match '^\d+\.' | Sort-Object Name -Descending | Select-Object -First 1
    $crt = Get-ChildItem -LiteralPath (Join-Path $runtime.FullName 'x64') -Directory | Where-Object Name -Like '*.CRT' | Select-Object -First 1
    if (-not $crt) { throw 'The Visual C++ redistributable runtime was not found.' }
    foreach ($dll in @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')) { Copy-Item -LiteralPath (Join-Path $crt.FullName $dll) -Destination $out }
    $zip = "$out.zip"
    Compress-Archive -LiteralPath $out -DestinationPath $zip -Force
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
