$ErrorActionPreference = 'Stop'
$app = (Resolve-Path 'build/windows/x64/runner/Release/saarthi_ai.exe').Path
$sandbox = Join-Path $env:RUNNER_TEMP ('saarthi-executable-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $sandbox | Out-Null
$children = @()

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SaarthiWindowsNative {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr handle);
}
'@

function Start-IsolatedApp {
    param([string]$Arguments = '')
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.Arguments = $Arguments
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
    $restart.Kill()
    if (-not $restart.WaitForExit(10000)) { throw 'Unable to close restarted test app.' }

    # Hidden at-logon instance runs the same engine, never another SQLite owner.
    $hidden = Start-IsolatedApp '--saarthi-background'
    $children += $hidden
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $handle = [IntPtr]::Zero
    do {
        $hidden.Refresh()
        if ($hidden.HasExited) { throw 'Background process exited unexpectedly.' }
        $handle = [SaarthiWindowsNative]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW','saarthi_ai')
        if ($handle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($handle -eq [IntPtr]::Zero) { throw 'Background Flutter engine did not create its hidden window.' }
    if ([SaarthiWindowsNative]::IsWindowVisible($handle)) {
        throw 'At-logon background mode showed its window unexpectedly.'
    }
    $reveal = Start-IsolatedApp
    $children += $reveal
    if (-not $reveal.WaitForExit(10000) -or $reveal.ExitCode -ne 0) {
        throw 'A foreground launch must reuse the hidden app process.'
    }
    $hidden.Refresh()
    if ($hidden.HasExited) { throw 'Foreground reveal terminated the background sync process.' }
    if (-not [SaarthiWindowsNative]::IsWindowVisible($handle)) {
        throw 'Foreground launch did not reveal the existing hidden window.'
    }
    Write-Host 'PASS: hidden at-logon Flutter process runs, never duplicates SQLite, and reveals on user launch'
    Write-Host 'Scope: isolated unconfigured profile. Signed online school session, real Drive ACK, 24-hour expiry and physical Windows sleep/wake remain separate acceptance requirements.'
} finally {
    foreach ($child in $children) {
        $child.Refresh()
        if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit(10000) | Out-Null }
        $child.Dispose()
    }
}
