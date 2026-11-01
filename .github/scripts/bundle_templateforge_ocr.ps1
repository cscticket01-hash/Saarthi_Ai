param(
  [Parameter(Mandatory=$true)][string]$ReleaseDirectory
)
$ErrorActionPreference = 'Stop'
$release = (Resolve-Path $ReleaseDirectory).Path
$source = Join-Path $env:ProgramFiles 'Tesseract-OCR'
if (!(Test-Path (Join-Path $source 'tesseract.exe'))) {
  choco install tesseract --version=5.5.3.20260724 -y --no-progress
  if ($LASTEXITCODE -ne 0) { throw 'Pinned Tesseract OCR installation failed.' }
}
if (!(Test-Path (Join-Path $source 'tesseract.exe'))) {
  throw 'Tesseract executable was not installed at the expected location.'
}
$target = Join-Path $release 'ocr\tesseract'
New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item (Join-Path $source 'tesseract.exe') $target -Force
Get-ChildItem $source -File -Filter '*.dll' | ForEach-Object { Copy-Item $_.FullName $target -Force }
Copy-Item (Join-Path $source 'tessdata') $target -Recurse -Force

# Official tessdata_fast snapshot, pinned by immutable Git commit and Git blob SHA-1.
$revision = '87416418657359cb625c412a48b6e1d6d41c29bd'
$models = @{
  asm = '086035c6eacd5788c1f06d58c250023cee2aeb28'
  ben = '7e9054d1de309714009a85555f5276168d41af9c'
  eng = 'bbef4675053b5b468cdb477053e28b1c698ba08e'
  hin = 'a8f0aaec09378115b12a2c6287c57695d082aea2'
}
$data = Join-Path $target 'tessdata'
New-Item -ItemType Directory -Path $data -Force | Out-Null
foreach ($language in $models.Keys) {
  $destination = Join-Path $data "$language.traineddata"
  $url = "https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/$revision/$language.traineddata"
  Invoke-WebRequest -Uri $url -OutFile $destination -UseBasicParsing
  $bytes = [System.IO.File]::ReadAllBytes($destination)
  $headerText = "blob $($bytes.Length)" + [char]0
  $header = [System.Text.Encoding]::UTF8.GetBytes($headerText)
  $payload = New-Object 'System.Byte[]' ($header.Length + $bytes.Length)
  [Array]::Copy($header, 0, $payload, 0, $header.Length)
  [Array]::Copy($bytes, 0, $payload, $header.Length, $bytes.Length)
  $sha = [System.Security.Cryptography.SHA1]::Create()
  try {
    $actual = [BitConverter]::ToString($sha.ComputeHash($payload)).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
  if ($actual -ne $models[$language]) {
    throw "Tesseract $language traineddata integrity check failed."
  }
}
$license = Get-ChildItem $source -File -Filter 'LICENSE*' | Select-Object -First 1
if (!$license) {
  $chocoLicense = Join-Path $env:ProgramData 'chocolatey\lib\tesseract\legal\LICENSE.txt'
  if (Test-Path $chocoLicense) { $license = Get-Item $chocoLicense }
}
if ($license) {
  Copy-Item $license.FullName (Join-Path $release 'ocr\TESSERACT-LICENSE.txt') -Force
} else {
  throw 'Tesseract Apache 2.0 licence file was not available for redistribution.'
}
$exe = Join-Path $target 'tesseract.exe'
$list = & $exe --tessdata-dir $target --list-langs 2>&1
$listText = $list | Out-String
if ($LASTEXITCODE -ne 0) { throw 'Bundled Tesseract could not load its traineddata.' }
foreach ($language in $models.Keys) {
  if ($listText -notmatch "(?m)^\s*$language\s*$") {
    throw "Bundled OCR is missing required language: $language"
  }
}
$version = (& $exe --version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $version -notmatch '(?i)tesseract\s+v?5\.') {
  throw 'Bundled Tesseract version verification failed.'
}
Write-Host "TemplateForge OCR bundled: $version"
Write-Host "Languages verified: $($models.Keys -join ', ')"
Write-Host "Runtime directory: $target"
