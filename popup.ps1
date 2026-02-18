param(
    [string]$SessionId = "default"
)

$stateDir = "$env:USERPROFILE\.claude\hooks\claude-notify"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class WinSwitch {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_SHOWWINDOW = 0x0040;

    public static void BringToFront(IntPtr hwnd) {
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);

        IntPtr fgWnd = GetForegroundWindow();
        uint fgPid;
        uint fgThread = GetWindowThreadProcessId(fgWnd, out fgPid);
        uint ourThread = GetCurrentThreadId();
        if (fgThread != ourThread)
            AttachThreadInput(ourThread, fgThread, true);

        SetForegroundWindow(hwnd);

        if (fgThread != ourThread)
            AttachThreadInput(ourThread, fgThread, false);
    }
}
"@

# Read session-specific state
$savedHwnd = [IntPtr]::Zero
$savedTabIndex = 0

$hwndFile = "$stateDir\.hwnd-$SessionId"
$tabIndexFile = "$stateDir\.tabindex-$SessionId"

if (Test-Path $hwndFile) {
    $val = (Get-Content $hwndFile -Raw -ErrorAction SilentlyContinue)
    if ($val) { $savedHwnd = [IntPtr]::new([long]$val) }
}
if (Test-Path $tabIndexFile) {
    $idx = (Get-Content $tabIndexFile -Raw -ErrorAction SilentlyContinue)
    if ($idx) { $savedTabIndex = [int]$idx }
}

# Count active popups to determine stack position
$activePopups = 0
Get-ChildItem "$stateDir\.popup-*.pid" -ErrorAction SilentlyContinue | ForEach-Object {
    $pidVal = Get-Content $_.FullName -ErrorAction SilentlyContinue
    if ($pidVal) {
        $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
        if ($proc -and -not $proc.HasExited) { $activePopups++ }
    }
}

$popupHeight = 100

# Collect all windows so any click handler can close them all
$allWindows = @()

# Get DPI scaling factor (WPF uses device-independent pixels)
$dpiScale = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width / [System.Windows.SystemParameters]::PrimaryScreenWidth

# Create a popup on each screen
$screens = [System.Windows.Forms.Screen]::AllScreens
foreach ($scr in $screens) {
    # Convert screen bounds from physical pixels to WPF DIPs
    $scrLeft   = $scr.WorkingArea.Left   / $dpiScale
    $scrTop    = $scr.WorkingArea.Top    / $dpiScale
    $scrWidth  = $scr.WorkingArea.Width  / $dpiScale
    $scrHeight = $scr.WorkingArea.Height / $dpiScale
    $scrRight  = $scrLeft + $scrWidth
    $scrBottom = $scrTop + $scrHeight

    $window = New-Object System.Windows.Window
    $window.WindowStyle = "None"
    $window.AllowsTransparency = $true
    $window.Background = [System.Windows.Media.Brushes]::Transparent
    $window.Topmost = $true
    $window.ShowInTaskbar = $false
    $window.SizeToContent = "WidthAndHeight"
    $window.WindowStartupLocation = "Manual"

    $window.Left = $scrRight - 370
    $baseTop = $scrBottom - 110
    $window.Top = $baseTop - ($activePopups * $popupHeight)

    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#1a1a2e")
    $border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#f0883e")
    $border.BorderThickness = [System.Windows.Thickness]::new(2)
    $border.Padding = [System.Windows.Thickness]::new(20, 16, 20, 16)
    $border.Cursor = [System.Windows.Input.Cursors]::Hand

    $stack = New-Object System.Windows.Controls.StackPanel

    $titleBlock = New-Object System.Windows.Controls.TextBlock
    $titleBlock.Text = "Claude Code"
    $titleBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#f0883e")
    $titleBlock.FontSize = 16
    $titleBlock.FontWeight = "Bold"
    $titleBlock.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)

    $body = New-Object System.Windows.Controls.TextBlock
    $body.Text = "Waiting for your input"
    $body.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#eaeaea")
    $body.FontSize = 14

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = "Click to switch"
    $hint.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#888888")
    $hint.FontSize = 11
    $hint.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)

    $null = $stack.Children.Add($titleBlock)
    $null = $stack.Children.Add($body)
    $null = $stack.Children.Add($hint)
    $border.Child = $stack
    $window.Content = $border

    # Click: bring WT window to front, switch tab, dismiss all popups
    $window.Add_MouseLeftButtonDown({
        if ($savedHwnd -ne [IntPtr]::Zero -and [WinSwitch]::IsWindow($savedHwnd)) {
            [WinSwitch]::BringToFront($savedHwnd)
            foreach ($w in $allWindows) { $w.Close() }
            if ($savedTabIndex -gt 0 -and $savedTabIndex -le 9) {
                Start-Sleep -Milliseconds 200
                [System.Windows.Forms.SendKeys]::SendWait("^(%$savedTabIndex)")
            }
        } else {
            foreach ($w in $allWindows) { $w.Close() }
        }
    })

    # Slide-in animation
    $animTarget = $baseTop - ($activePopups * $popupHeight)
    $animFrom = $scrBottom
    $window.Add_Loaded({
        $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
        $animation.From = $animFrom
        $animation.To = $animTarget
        $animation.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(300))
        $animation.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
        $window.BeginAnimation([System.Windows.Window]::TopProperty, $animation)
    })

    # When this window closes, check if all windows are closed -> shut down dispatcher
    $window.Add_Closed({
        $anyOpen = $false
        foreach ($w in $allWindows) {
            if ($w.IsVisible) { $anyOpen = $true; break }
        }
        if (-not $anyOpen) {
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
        }
    })

    $allWindows += $window
}

# Auto-close all after 30 seconds
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(30)
$timer.Add_Tick({ foreach ($w in $allWindows) { $w.Close() } })
$timer.Start()

# Write PID so resume can kill us (and other popups can count us)
$pidFile = "$stateDir\.popup-$SessionId.pid"
Set-Content -Path $pidFile -Value $PID -NoNewline

# Show all windows (non-blocking), then run the dispatcher
try {
    foreach ($w in $allWindows) { $w.Show() }
    [System.Windows.Threading.Dispatcher]::Run()
} catch {
    $_ | Out-File "$stateDir\popup-crash.log"
}
