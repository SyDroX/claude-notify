param(
    [string]$SessionId = "default",
    [int]$ScreenIndex = 0
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

$labelFile = "$stateDir\.label-$SessionId"
$label = ""
if (Test-Path $labelFile) {
    $label = (Get-Content $labelFile -Raw -ErrorAction SilentlyContinue)
    if ($label) { $label = $label.Trim() }
}

# Count active popups to determine stack position (count PID files with live processes)
$activePopups = 0
Get-ChildItem "$stateDir\.popup-*.pid" -ErrorAction SilentlyContinue | ForEach-Object {
    $lines = Get-Content $_.FullName -ErrorAction SilentlyContinue
    if ($lines) {
        foreach ($pidLine in $lines) {
            if ($pidLine.Trim()) {
                $proc = Get-Process -Id $pidLine.Trim() -ErrorAction SilentlyContinue
                if ($proc -and -not $proc.HasExited) { $activePopups++ }
            }
        }
    }
}
# Each session spawns N popups (one per screen), so divide by screen count to get session count
$screenCount = ([System.Windows.Forms.Screen]::AllScreens).Count
if ($screenCount -gt 1) { $activePopups = [math]::Floor($activePopups / $screenCount) }

$popupHeight = 100

# Get target screen
$screens = [System.Windows.Forms.Screen]::AllScreens
if ($ScreenIndex -ge $screens.Count) { $ScreenIndex = 0 }
$targetScreen = $screens[$ScreenIndex]
$wa = $targetScreen.WorkingArea

# Build the popup window
$window = New-Object System.Windows.Window
$window.WindowStyle = "None"
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.SizeToContent = "WidthAndHeight"
$window.WindowStartupLocation = "Manual"

$window.Left = $wa.Right - 370
$baseTop = $wa.Bottom - 110
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
$titleBlock.Text = if ($label) { "Claude Code - $label" } else { "Claude Code" }
$titleBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#f0883e")
$titleBlock.FontSize = 16
$titleBlock.FontWeight = "Bold"
$titleBlock.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)

$body = New-Object System.Windows.Controls.TextBlock
$body.Text = "Waiting for your input"
$body.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#eaeaea")
$body.FontSize = 14

# Bottom row: hint left, dismiss right
$bottomRow = New-Object System.Windows.Controls.DockPanel
$bottomRow.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)

$closeBtn = New-Object System.Windows.Controls.TextBlock
$closeBtn.Text = "Dismiss"
$closeBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#555555")
$closeBtn.FontSize = 12
$closeBtn.Cursor = [System.Windows.Input.Cursors]::Hand
[System.Windows.Controls.DockPanel]::SetDock($closeBtn, "Right")
$closeBtn.Add_MouseEnter({ $closeBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#eaeaea") })
$closeBtn.Add_MouseLeave({ $closeBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#555555") })
$closeBtn.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    if (Test-Path $pidFile) {
        $pids = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($pids) {
            foreach ($p in $pids) {
                if ($p.Trim() -and $p.Trim() -ne "$PID") {
                    Stop-Process -Id $p.Trim() -Force -ErrorAction SilentlyContinue
                }
            }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    $window.Close()
})

$hint = New-Object System.Windows.Controls.TextBlock
$hint.Text = "Focus this tab"
$hint.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#888888")
$hint.FontSize = 12

$null = $bottomRow.Children.Add($closeBtn)
$null = $bottomRow.Children.Add($hint)

$null = $stack.Children.Add($titleBlock)
$null = $stack.Children.Add($body)
$null = $stack.Children.Add($bottomRow)
$border.Child = $stack
$window.Content = $border

# Click: kill sibling popups, bring WT window to front, switch tab, dismiss
$window.Add_MouseLeftButtonDown({
    # Kill all sibling popups for this session
    if (Test-Path $pidFile) {
        $pids = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($pids) {
            foreach ($p in $pids) {
                if ($p.Trim() -and $p.Trim() -ne "$PID") {
                    Stop-Process -Id $p.Trim() -Force -ErrorAction SilentlyContinue
                }
            }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    if ($savedHwnd -ne [IntPtr]::Zero -and [WinSwitch]::IsWindow($savedHwnd)) {
        [WinSwitch]::BringToFront($savedHwnd)
        $window.Close()
        if ($savedTabIndex -gt 0 -and $savedTabIndex -le 9) {
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.SendKeys]::SendWait("^(%$savedTabIndex)")
        }
    } else {
        $window.Close()
    }
})

# Auto-close after 30 seconds
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(30)
$timer.Add_Tick({ $window.Close() })
$timer.Start()

# Slide-in animation
$animTarget = $baseTop - ($activePopups * $popupHeight)
$animFrom = $wa.Bottom
$window.Add_Loaded({
    $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animation.From = $animFrom
    $animation.To = $animTarget
    $animation.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(300))
    $animation.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
    $window.BeginAnimation([System.Windows.Window]::TopProperty, $animation)
})

# Append PID to session pid file (multiple popups per session now)
$pidFile = "$stateDir\.popup-$SessionId.pid"
Add-Content -Path $pidFile -Value $PID

try {
    $null = $window.ShowDialog()
} catch {
    $_ | Out-File "$stateDir\popup-crash.log"
}
