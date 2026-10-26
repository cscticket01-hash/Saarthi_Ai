param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$env:WINDOWS_SIGNING_PFX_BASE64 -or !$env:WINDOWS_SIGNING_PASSWORD -or !$env:WINDOWS_SIGNING_THUMBPRINT) {
    throw 'Trusted Windows signing credentials missing. Configure WINDOWS_SIGNING_PFX_BASE64, WINDOWS_SIGNING_PASSWORD and WINDOWS_SIGNING_THUMBPRINT; unsigned public releases are blocked.'
}
$expected = $env:WINDOWS_SIGNING_THUMBPRINT.Replace(' ', '').ToUpperInvariant()
if ($expected -notmatch '^[A-F0-9]{40}$') { throw 'Invalid pinned signing certificate thumbprint.' }
$files = @(Get-ChildItem -LiteralPath $Path -Filter *.exe -File)
if ($files.Count -eq 0) { throw 'No executable found for signing.' }
$tool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe' | Sort-Object FullName -Descending | Select-Object -First 1
if (!$tool) { throw 'Windows SDK signtool not found.' }
$pfx = Join-Path $env:RUNNER_TEMP ('vidya-sign-' + [guid]::NewGuid() + '.pfx')
$cert = $null
try {
    [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:WINDOWS_SIGNING_PFX_BASE64))
    $password = ConvertTo-SecureString $env:WINDOWS_SIGNING_PASSWORD -AsPlainText -Force
    $certs = @(Import-PfxCertificate -FilePath $pfx -CertStoreLocation Cert:\CurrentUser\My -Password $password)
    $cert = $certs | Where-Object { $_.Thumbprint -eq $expected -and $_.HasPrivateKey } | Select-Object -First 1
    if (!$cert) { throw 'Signing certificate does not match pinned publisher identity.' }
    if ($cert.NotAfter -le (Get-Date) -or $cert.NotBefore -gt (Get-Date)) { throw 'Signing certificate is not currently valid.' }
    if (!($cert.EnhancedKeyUsageList | Where-Object { [string]$_.ObjectId -eq '1.3.6.1.5.5.7.3.3' })) { throw 'Certificate must permit code signing.' }
    foreach ($file in $files) {
        & $tool.FullName sign /sha1 $expected /s My /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $file.FullName
        if ($LASTEXITCODE -ne 0) { throw 'Authenticode signing or timestamping failed.' }
        & $tool.FullName verify /pa /all /v $file.FullName
        if ($LASTEXITCODE -ne 0) { throw 'Authenticode verification failed.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $expected -or !$signature.TimeStamperCertificate) {
            throw 'Trusted, timestamped publisher signature required.'
        }
    }
} finally {
    Remove-Item -LiteralPath $pfx -Force -ErrorAction SilentlyContinue
    if ($cert) { Remove-Item ('Cert:\CurrentUser\My\' + $cert.Thumbprint) -Force -ErrorAction SilentlyContinue }
}
