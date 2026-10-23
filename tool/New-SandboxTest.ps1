param(
    [Parameter(Mandatory = $true)][string]$PackageZip,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$package = (Resolve-Path -LiteralPath $PackageZip).Path
$destination = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $destination) { throw 'Choose a new output directory.' }
$inputFolder = Join-Path $destination 'input'
$resultsFolder = Join-Path $destination 'results'
New-Item -ItemType Directory -Path $inputFolder,$resultsFolder | Out-Null
Copy-Item -LiteralPath $package -Destination (Join-Path $inputFolder 'package.zip')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Invoke-CleanWindowsTest.ps1') -Destination $inputFolder
$inputXml = [Security.SecurityElement]::Escape($inputFolder)
$resultsXml = [Security.SecurityElement]::Escape($resultsFolder)
$command = [Security.SecurityElement]::Escape('powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\PrinterCare\Input\Invoke-CleanWindowsTest.ps1 -PackageZip C:\PrinterCare\Input\package.zip -OutputPath C:\PrinterCare\Results\result.json -ConfirmCleanMachine -ExpectOffline -ShowApplication')
@"
<Configuration>
  <vGPU>Disable</vGPU>
  <Networking>Disable</Networking>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <MappedFolders>
    <MappedFolder><HostFolder>$inputXml</HostFolder><SandboxFolder>C:\PrinterCare\Input</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$resultsXml</HostFolder><SandboxFolder>C:\PrinterCare\Results</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand><Command>$command</Command></LogonCommand>
</Configuration>
"@ | Set-Content -LiteralPath (Join-Path $destination 'PrinterCare-test.wsb') -Encoding UTF8
Write-Output 'Sandbox configuration prepared. Open PrinterCare-test.wsb on a machine with Windows Sandbox enabled.'
Write-Output 'The generated configuration contains local mapped paths. Keep it private; share only the sanitized result.json.'
