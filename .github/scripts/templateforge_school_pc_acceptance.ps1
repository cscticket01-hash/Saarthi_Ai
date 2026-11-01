# TemplateForge 3 on-device test evidence; NO school data uploads.
[CmdletBinding()]
param(
  [ValidateSet('A4','Legal')][string]$Paper = 'A4',
  [ValidateRange(1,5)][int]$DeviceNumber = 1,
  [string]$PrinterName = '',
  [string]$CalibrationPdf = '',
  [double]$HorizontalMm = 0,
  [double]$VerticalMm = 0,
  [double]$TopMarginMm = 0,
  [double]$LeftMarginMm = 0,
  [string]$Output = 'templateforge_local_acceptance.json'
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 5) {
  throw 'Windows PowerShell 5 or newer is required.'
}
$measurements = @($HorizontalMm,$VerticalMm,$TopMarginMm,$LeftMarginMm)
$provided = @($measurements | Where-Object { $_ -gt 0 }).Count
if ($provided -ne 0 -and $provided -ne 4) {
  throw 'Supply all four ruler measurements in mm, or none.'
}
if ($provided -eq 4 -and -not $CalibrationPdf) {
  throw 'Specify the exact A4/Legal calibration PDF used for printing.'
}
$proof = $null
if ($CalibrationPdf) {
  if (-not (Test-Path -LiteralPath $CalibrationPdf -PathType Leaf)) {
    throw 'Calibration PDF not found. Download the PR #198 CI artifact.'
  }
  $file = (Resolve-Path -LiteralPath $CalibrationPdf).Path
  $header = [System.IO.File]::ReadAllBytes($file)
  if ($header.Length -lt 5 -or
      [Text.Encoding]::ASCII.GetString($header,0,5) -ne '%PDF-') {
    throw 'The calibration file is not a PDF.'
  }
  $proof = @{
    sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    paper = $Paper
  }
}
$printers = @()
try {
  $printers = @(Get-Printer -ErrorAction Stop | ForEach-Object {
    @{
      name = $_.Name
      driver = $_.DriverName
      status = [string]$_.PrinterStatus
      shared = [bool]$_.Shared
    }
  })
} catch {
  Write-Warning 'Windows print spooler did not return a printer list.'
}
if ($PrinterName -and
    @($printers | Where-Object { $_.name -eq $PrinterName }).Count -ne 1) {
  throw 'Requested printer is not installed. Use Windows Add Printer and retry.'
}
$programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
$libreOffice = (Test-Path "$env:ProgramFiles\LibreOffice\program\soffice.exe")
if ($programFilesX86) {
  $libreOffice = $libreOffice -or
    (Test-Path (Join-Path $programFilesX86 'LibreOffice\program\soffice.exe'))
}
$office = @{
  libreOfficeInstalled = [bool]$libreOffice
  wordComRegistered = [bool][type]::GetTypeFromProgID('Word.Application')
  excelComRegistered = [bool][type]::GetTypeFromProgID('Excel.Application')
}
$physicalPassed = $false
if ($provided -eq 4) {
  $physicalPassed = [math]::Abs($HorizontalMm-100) -le 1 -and
    [math]::Abs($VerticalMm-100) -le 1 -and
    [math]::Abs($TopMarginMm-10) -le 1 -and
    [math]::Abs($LeftMarginMm-10) -le 1 -and
    -not [string]::IsNullOrWhiteSpace($PrinterName)
}
$report = [ordered]@{
  schema = 'templateforge-local-print-evidence-v1'
  createdUtc = [DateTime]::UtcNow.ToString('o')
  deviceNumber = $DeviceNumber
  paper = $Paper
  installedPrinterCount = $printers.Count
  printers = $printers
  selectedPrinter = $PrinterName
  converterPrerequisites = $office
  proof = $proof
  measurementsMm = if ($provided -eq 4) {
    @{
      horizontal = $HorizontalMm
      vertical = $VerticalMm
      topMargin = $TopMarginMm
      leftMargin = $LeftMarginMm
    }
  } else { $null }
  physicalVerified = $physicalPassed
  physicalTestPerformed = ($provided -eq 4)
  realFivePcSyncVerified = $false
  sourceDocumentsUploaded = $false
  note = 'Local measured printer evidence; real school Drive ACK/rollback and OCR corpus require separate verified tests.'
}
$destination = [System.IO.Path]::GetFullPath($Output)
$report | ConvertTo-Json -Depth 7 |
  Set-Content -LiteralPath $destination -Encoding UTF8
Write-Host "Local hardware evidence: $destination"
Write-Host "Installed printers: $($printers.Count)"
Write-Host "Physical verification: $physicalPassed"
Write-Host 'No school documents or cloud credentials were uploaded.'
