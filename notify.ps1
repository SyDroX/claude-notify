param(
    [Parameter(Position=0)]
    [string]$Action = "attention"
)

# Use WT_SESSION to isolate state between multiple Claude Code sessions
$sessionId = $env:WT_SESSION
if (-not $sessionId) { $sessionId = "default" }
$stateDir = "$env:USERPROFILE\.claude\hooks\claude-notify"
$pidFile = "$stateDir\.popup-$sessionId.pid"
$cooldownFile = "$stateDir\.cooldown-$sessionId"
$hwndFile = "$stateDir\.hwnd-$sessionId"
$tabIndexFile = "$stateDir\.tabindex-$sessionId"
$popupScript = "$stateDir\popup.ps1"

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class WinHelper {
    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }

    [DllImport("user32.dll")]
    public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    public const uint FLASHW_ALL = 3;
    public const uint FLASHW_TIMERNOFG = 12;
    public const uint FLASHW_STOP = 0;

    public static void Flash(IntPtr hwnd) {
        FLASHWINFO info = new FLASHWINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        info.hwnd = hwnd;
        info.dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG;
        info.uCount = 0;
        info.dwTimeout = 0;
        FlashWindowEx(ref info);
    }

    public static void StopFlash(IntPtr hwnd) {
        FLASHWINFO info = new FLASHWINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        info.hwnd = hwnd;
        info.dwFlags = FLASHW_STOP;
        info.uCount = 0;
        info.dwTimeout = 0;
        FlashWindowEx(ref info);
    }
}
"@ -ErrorAction SilentlyContinue

try {
    switch ($Action) {
        "resume" {
            # Stop flash on saved HWND
            if (Test-Path $hwndFile) {
                $savedHwnd = [IntPtr]::new([long](Get-Content $hwndFile -Raw -ErrorAction SilentlyContinue))
                if ([WinHelper]::IsWindow($savedHwnd)) {
                    [WinHelper]::StopFlash($savedHwnd)
                }
            }

            # Kill this session's popup
            if (Test-Path $pidFile) {
                $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
                if ($oldPid) { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue }
                Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
            }
        }
        "attention" {
            # Read saved HWND for this session
            $hwnd = [IntPtr]::Zero
            if (Test-Path $hwndFile) {
                $val = (Get-Content $hwndFile -Raw -ErrorAction SilentlyContinue)
                if ($val) { $hwnd = [IntPtr]::new([long]$val) }
            }
            if ($hwnd -eq [IntPtr]::Zero -or -not [WinHelper]::IsWindow($hwnd)) { exit 0 }

            [WinHelper]::Flash($hwnd)

            # Kill any existing popup for this session
            if (Test-Path $pidFile) {
                $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
                if ($oldPid) { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue }
                Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
            }

            # Launch popup with session-specific state files
            Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$popupScript`" -SessionId $sessionId" -WindowStyle Hidden
        }
    }
} catch {}
