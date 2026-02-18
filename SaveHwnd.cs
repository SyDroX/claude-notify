using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Automation;

class SaveHwnd
{
    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    static void Main()
    {
        string dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".claude", "hooks", "claude-notify"
        );

        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return;

        // Verify it's a WindowsTerminal window
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        try
        {
            var proc = System.Diagnostics.Process.GetProcessById((int)pid);
            if (proc.ProcessName != "WindowsTerminal") return;
        }
        catch { return; }

        // Save HWND
        File.WriteAllText(Path.Combine(dir, ".hwnd"), hwnd.ToInt64().ToString());

        // Find and save the currently selected tab's index (1-based)
        try
        {
            File.WriteAllText(Path.Combine(dir, ".savehwnd-debug"), "starting tab enum");

            var root = AutomationElement.FromHandle(hwnd);
            var tabs = root.FindAll(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem));

            int idx = 0;
            foreach (AutomationElement tab in tabs)
            {
                idx++;
                try
                {
                    var sel = (SelectionItemPattern)tab.GetCurrentPattern(SelectionItemPattern.Pattern);
                    if (sel.Current.IsSelected)
                    {
                        File.WriteAllText(Path.Combine(dir, ".tabindex"), idx.ToString());
                        // Also save name for display
                        string name = tab.Current.Name ?? "";
                        string clean = Regex.Replace(name, @"[^\x20-\x7E]", "").Trim();
                        File.WriteAllText(Path.Combine(dir, ".tabname"), clean);
                        break;
                    }
                }
                catch { }
            }
        }
        catch (Exception ex)
        {
            File.WriteAllText(Path.Combine(dir, ".savehwnd-debug"), "ERROR: " + ex.ToString());
        }
    }
}
