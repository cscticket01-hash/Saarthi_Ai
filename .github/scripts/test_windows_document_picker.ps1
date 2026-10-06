$ErrorActionPreference = 'Stop'
$app = (Resolve-Path 'build/windows/x64/runner/Release/saarthi_ai.exe').Path
$folder = Join-Path $env:RUNNER_TEMP ('native-picker-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $folder | Out-Null
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PickerWindows {
 public delegate bool Callback(IntPtr hwnd, IntPtr param);
 [DllImport("user32.dll")] public static extern bool EnumWindows(Callback cb, IntPtr param);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
 [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int size);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 public static IntPtr Dialog(int processId) {
   IntPtr result = IntPtr.Zero;
   EnumWindows((h,p) => { uint id; GetWindowThreadProcessId(h,out id); var name=new StringBuilder(256); GetClassName(h,name,256);
     if(id==processId && name.ToString()=="#32770") result=h; return true; },IntPtr.Zero); return result;
 }
}
'@
$info = New-Object System.Diagnostics.ProcessStartInfo
$info.FileName = $app
$info.WorkingDirectory = Split-Path $app
$info.UseShellExecute = $false
$info.EnvironmentVariables['SAARTHI_PICKER_REVIEW'] = $folder
foreach ($key in @('APPDATA','LOCALAPPDATA','USERPROFILE')) {
 $profile = Join-Path $folder $key
 New-Item -ItemType Directory -Path $profile -Force | Out-Null
 $info.EnvironmentVariables[$key] = $profile
}
$process = [System.Diagnostics.Process]::Start($info)
$shell = New-Object -ComObject WScript.Shell
$handled = ''
$deadline = [DateTime]::UtcNow.AddMinutes(4)
try {
 while ([DateTime]::UtcNow -lt $deadline) {
   $statePath = Join-Path $folder 'state.json'
   $state = $null
   if(Test-Path $statePath) { try { $state = Get-Content $statePath -Raw | ConvertFrom-Json } catch { } }
   if($state -and $state.stage -eq 'done') { break }
   $process.Refresh()
   if($process.HasExited) { throw 'Picker harness exited before recording results.' }
   if($state) {
     $key = "$($state.stage):$($state.file)"
     if($key -ne $handled) {
       $dialog = [PickerWindows]::Dialog($process.Id)
       if($dialog -ne [IntPtr]::Zero) {
         [PickerWindows]::SetForegroundWindow($dialog) | Out-Null
         Start-Sleep -Milliseconds 300
         if($state.stage -eq 'cancel') { $shell.SendKeys('{ESC}') }
         elseif($state.stage -eq 'select') {
           $shell.SendKeys('%n'); Start-Sleep -Milliseconds 100
           $shell.SendKeys('^a'); $shell.SendKeys($state.file); $shell.SendKeys('{ENTER}')
         }
         $handled = $key
         Start-Sleep -Milliseconds 500
       }
     }
   }
   Start-Sleep -Milliseconds 100
 }
 if(!$state -or $state.stage -ne 'done') { throw 'Native picker automation timed out; actual Windows picker is unverified.' }
 if(!$state.passed) { throw "Native picker failed: $($state.error)" }
 if($state.results.Count -ne 4 -or !$state.cancelledWithoutSelection -or !$state.processingFailureRetainedOriginal) { throw 'Missing native file selection/cancellation/failure results.' }
 foreach($result in $state.results) {
   if(!$result.previewBeforeSave -or !$result.localSaveAndPendingQueue -or !$result.originalRetained) { throw 'Incomplete production upload flow' }
   Write-Host "PASS: production Documents name -> native picker -> $($result.file) -> preview -> Save -> local pending queue; optimized $($result.optimizedBytes) bytes, original retained"
 }
 Write-Host 'PASS: actual native Windows picker cancellation returns no document'
 Write-Host 'PASS: native truncated-file selection blocks Save and preserves original'
 Copy-Item (Join-Path $folder 'state.json') 'build/windows-review/native-picker-results.json'
} finally {
 $process.Refresh()
 if(!$process.HasExited) { $process.Kill(); $process.WaitForExit(10000) | Out-Null }
 $process.Dispose()
}
