$ErrorActionPreference = 'Stop'
$app = (Resolve-Path 'build/windows/x64/runner/Release/saarthi_ai.exe').Path
$sandbox = Join-Path $env:RUNNER_TEMP ('saarthi-executable-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $sandbox | Out-Null
$children = @()

function Start-IsolatedApp {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $app
    $info.WorkingDirectory = Split-Path $app
    $info.UseShellExecute = $false
    foreach ($key in @('APPDATA', 'LOCALAPPDATA', 'USERPROFILE')) {
        $folder = Join-Path $sandbox $key
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $info.EnvironmentVariables[$key] = $folder
    }
    return [System.Diagnostics.Process]::Start($info)
}

function Assert-AppWindow($process) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "App exited during startup: $($process.ExitCode)" }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) {
        throw 'No Windows app window observed. Desktop execution is unverified.'
    }
    Start-Sleep -Seconds 3
    $process.Refresh()
    if ($process.HasExited) { throw 'App crashed after creating its window.' }
    Write-Host "PASS: live Windows app window, process $($process.Id)"
}

try {
    $first = Start-IsolatedApp
    $children += $first
    Assert-AppWindow $first
    $second = Start-IsolatedApp
    $children += $second
    if (-not $second.WaitForExit(10000)) { throw 'Second instance did not exit.' }
    if ($second.ExitCode -ne 0) { throw "Second instance failed: $($second.ExitCode)" }
    $first.Refresh()
    if ($first.HasExited) { throw 'Original app exited when launching a second instance.' }
    Write-Host 'PASS: duplicate launch exits successfully and original app survives'
    $first.Kill()
    if (-not $first.WaitForExit(10000)) { throw 'Unable to close isolated test app.' }
    $restart = Start-IsolatedApp
    $children += $restart
    Assert-AppWindow $restart
    Write-Host 'PASS: app restarts after the previous process closes'
    Write-Host 'Scope: isolated unconfigured profile. Configured login/lock visual behavior and real Drive sync are not certified by this smoke test.'
} finally {
    foreach ($child in $children) {
        $child.Refresh()
        if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit(10000) | Out-Null }
        $child.Dispose()
    }
}
