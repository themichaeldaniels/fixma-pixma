param(
    [Parameter(Mandatory = $true)][string]$PackageZip,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [switch]$ConfirmCleanMachine,
    [switch]$ExpectOffline,
    [switch]$ShowApplication
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutputPath) { throw 'Use a new report filename.' }
$package = (Resolve-Path -LiteralPath $PackageZip).Path
$reportPath = [IO.Path]::GetFullPath($OutputPath)
$work = Join-Path ([IO.Path]::GetTempPath()) ('PrinterCare-clean-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$developerTools = @(Get-Command flutter.bat,dart.exe,cl.exe,cmake.exe,MSBuild.exe -ErrorAction SilentlyContinue | ForEach-Object Name)
if (Test-Path -LiteralPath "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe") { $developerTools += 'Visual Studio installation' }
$report = [ordered]@{
    schemaVersion = 1
    cleanEnvironmentConfirmed = [bool]$ConfirmCleanMachine
    windowsSandboxAccount = ($env:USERNAME -eq 'WDAGUtilityAccount')
    osVersion = [Environment]::OSVersion.Version.ToString()
    developerToolsDetected = $developerTools
    tests = [ordered]@{}
    printerWrites = 0
    cleanWindowsPassed = $false
}

function Invoke-TestProcess([string]$Executable, [string]$Arguments, [string]$InputText = '') {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = $Arguments
    $info.WorkingDirectory = $work
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.EnvironmentVariables['PATH'] = "$env:WINDIR/System32;$env:WINDIR"
    $info.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $work 'Isolated application data'
    $info.EnvironmentVariables['TEMP'] = $work
    $info.EnvironmentVariables['TMP'] = $work
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'Test process did not start.' }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if ($InputText) { $process.StandardInput.Write($InputText) }
    $process.StandardInput.Close()
    if (-not $process.WaitForExit(60000)) {
        $process.Kill()
        $process.WaitForExit(5000) | Out-Null
        throw 'Test process timed out.'
    }
    $result = @{ ExitCode = $process.ExitCode; Output = $stdout.Result }
    $stderr.Result | Out-Null
    $process.Dispose()
    return $result
}

try {
    $report['lastStep'] = 'Extract portable archive'
    $extracted = Join-Path $work 'Portable folder with spaces'
    Expand-Archive -LiteralPath $package -DestinationPath $extracted
    $applications = @(Get-ChildItem -LiteralPath $extracted -Filter printer_care.exe -Recurse -File)
    if ($applications.Count -ne 1) { throw 'Expected one application executable.' }
    $app = $applications[0]
    $appFolder = $app.DirectoryName
    $report['lastStep'] = 'Native application startup'
    $proofPath = Join-Path $work 'startup.json'
    $native = Invoke-TestProcess $app.FullName "--smoke-output=`"$proofPath`""
    if ($native.ExitCode -ne 0) { throw 'Application startup returned an error.' }
    $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json
    if (-not $proof.launched -or $proof.error -or $proof.usbError -or $proof.counterCommandsSent) { throw 'Startup checks did not pass.' }
    $report['applicationVersion'] = $proof.version
    $report.tests['portableStartupWithRestrictedPath'] = $true
    $report.tests['differentWorkingDirectory'] = $true
    if ($ExpectOffline) {
        if ($proof.networkStatus -or @($proof.discoveredPrinters).Count -gt 0) { throw 'Expected an offline test environment.' }
        $report.tests['offlineStartup'] = $true
    }
    $report['lastStep'] = 'Native USB helper initialization and enumeration'
    $profile = Get-Content -LiteralPath (Join-Path $appFolder 'data/flutter_assets/assets/protocol.json') -Raw | ConvertFrom-Json
    $requests = (@{op='init';profile=$profile;reset=$false} | ConvertTo-Json -Depth 30 -Compress) + "`n" + '{"op":"scan"}' + "`n" + '{"op":"close"}' + "`n"
    $worker = Invoke-TestProcess (Join-Path $appFolder 'printer_care_worker.exe') '' $requests
    $replies = @($worker.Output -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    if ($worker.ExitCode -ne 0 -or $replies.Count -ne 3 -or @($replies | Where-Object { -not $_.ok }).Count) { throw 'USB helper checks did not pass.' }
    $report.tests['usbHelperReadOnlyEnumeration'] = $true
    $report['lastStep'] = 'Windows queue helper read-only listing'
    $queue = Invoke-TestProcess (Join-Path $appFolder 'printer_care_queue.exe') '' ('{"op":"list"}' + "`n")
    $queueReply = $queue.Output | ConvertFrom-Json
    if (-not $queueReply.ok -and -not $queueReply.error) { throw 'Queue helper returned an invalid response.' }
    $report.tests['queueHelperResponsive'] = $true
    $report['queueListingAvailable'] = [bool]$queueReply.ok
    $report['lastStep'] = 'Graceful missing-helper startup'
    $missing = Join-Path $work 'Application without USB helper'
    New-Item -ItemType Directory -Path $missing | Out-Null
    Get-ChildItem -LiteralPath $appFolder | Where-Object Name -NE 'printer_care_worker.exe' | Copy-Item -Destination $missing -Recurse
    $missingProof = Join-Path $work 'missing-helper.json'
    $missingRun = Invoke-TestProcess (Join-Path $missing 'printer_care.exe') "--smoke-output=`"$missingProof`""
    $missingResult = Get-Content -LiteralPath $missingProof -Raw | ConvertFrom-Json
    if ($missingRun.ExitCode -ne 0 -or -not $missingResult.launched -or -not $missingResult.usbError -or $missingResult.counterCommandsSent) { throw 'Missing-helper handling did not pass.' }
    $report.tests['missingHelperReportedWithoutStartupCrash'] = $true
    $report['portableChecksPassed'] = $true
    $report['cleanWindowsPassed'] = [bool]$ConfirmCleanMachine -and $developerTools.Count -eq 0
    $report['lastStep'] = 'Completed'
} catch {
    $report['portableChecksPassed'] = $false
    $report['failureType'] = $_.Exception.GetType().FullName
} finally {
    New-Item -ItemType Directory -Path (Split-Path $reportPath -Parent) -Force | Out-Null
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
}
if (-not $report.portableChecksPassed) { throw 'A beta startup check failed. See the report lastStep and failureType.' }
if ($ConfirmCleanMachine -and -not $report.cleanWindowsPassed) { throw 'Development tools were detected; a clean Windows pass was not recorded.' }
Write-Output 'Portable checks passed. The report distinguishes host testing from confirmed clean Windows testing.'
if ($ShowApplication) {
    $interactive = New-Object Diagnostics.ProcessStartInfo
    $interactive.FileName = $app.FullName
    $interactive.WorkingDirectory = $work
    $interactive.UseShellExecute = $false
    $interactive.CreateNoWindow = $true
    $interactive.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
    $interactive.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $work 'Interactive test state'
    [Diagnostics.Process]::Start($interactive) | Out-Null
}
