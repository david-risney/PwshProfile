<#
.SYNOPSIS
    Brings a window to the foreground. Invoked when the turn-toast notification's
    "Focus terminal" button is clicked.

.DESCRIPTION
    Registered as the handler for the custom `turntoast:` URL protocol by
    Turn-Toast.ps1. Windows launches it as:

        Focus-Window.ps1 "turntoast:<hwnd>"

    where <hwnd> is the terminal window handle captured (via the hook's parent
    process tree) when the toast was shown. The script parses the handle and
    forces that window to the foreground, restoring it if minimized.

    Uses the AttachThreadInput trick so the activation succeeds even though the
    calling process did not own the previous foreground window. If the target is
    on a different virtual desktop, it is first pulled onto the desktop the user
    is currently viewing (via IVirtualDesktopManager) so the window reliably
    appears where the toast was clicked.

    Like the rest of the plugin it swallows all failures and writes nothing to
    stdout so it can never surface an error to the user.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Uri
)

$ErrorActionPreference = 'SilentlyContinue'

try {
    if (-not $Uri) { return }

    # Extract the window handle (first run of >=2 digits) from the URI, e.g.
    # "turntoast:8981218" or "turntoast:8981218/".
    $hwnd = [int64]0
    if ($Uri -match '(\d{2,})') {
        [void][int64]::TryParse($Matches[1], [ref]$hwnd)
    }
    if ($hwnd -le 0) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace TurnToast {
    // Documented shell interface for querying/moving windows across virtual desktops.
    [ComImport, Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a")]
    internal class CVirtualDesktopManager { }

    [ComImport, Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IVirtualDesktopManager {
        [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow, out int onCurrentDesktop);
        [PreserveSig] int GetWindowDesktopId(IntPtr topLevelWindow, out Guid desktopId);
        [PreserveSig] int MoveWindowToDesktop(IntPtr topLevelWindow, ref Guid desktopId);
    }

    public static class Native {
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

        const int SW_RESTORE = 9;
        const int SW_SHOW = 5;

        // If the target is on a different virtual desktop, pull it onto the
        // desktop the user is currently viewing so activation reliably lands
        // there (SetForegroundWindow alone can just flash the taskbar for an
        // off-desktop window on some Windows builds).
        static void PullToCurrentDesktop(IntPtr hWnd) {
            try {
                var mgr = (IVirtualDesktopManager)(new CVirtualDesktopManager());
                int onCurrent;
                if (mgr.IsWindowOnCurrentVirtualDesktop(hWnd, out onCurrent) == 0 && onCurrent == 0) {
                    IntPtr fg = GetForegroundWindow();
                    Guid currentDesktop;
                    if (fg != IntPtr.Zero && mgr.GetWindowDesktopId(fg, out currentDesktop) == 0) {
                        mgr.MoveWindowToDesktop(hWnd, ref currentDesktop);
                    }
                }
            } catch { }
        }

        public static void Focus(IntPtr hWnd) {
            if (IsIconic(hWnd)) { ShowWindow(hWnd, SW_RESTORE); }
            PullToCurrentDesktop(hWnd);

            IntPtr fg = GetForegroundWindow();
            uint pid;
            uint fgThread = GetWindowThreadProcessId(fg, out pid);
            uint thisThread = GetCurrentThreadId();

            if (fgThread != thisThread) { AttachThreadInput(thisThread, fgThread, true); }
            BringWindowToTop(hWnd);
            ShowWindow(hWnd, SW_SHOW);
            SetForegroundWindow(hWnd);
            if (fgThread != thisThread) { AttachThreadInput(thisThread, fgThread, false); }
        }
    }
}
'@

    [TurnToast.Native]::Focus([IntPtr]$hwnd)
} catch { }
