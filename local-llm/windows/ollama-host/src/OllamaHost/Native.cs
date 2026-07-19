using System.Runtime.InteropServices;

namespace Squire.OllamaHost;

/// <summary>
///   The Win32 P/Invoke entry points and interop structures needed by the tray application needs.  This
///   includes the shell notify icon, a hidden message window, menus, message boxes, and job objects.
/// </summary>
///
internal static unsafe class Native
{
    /// <summary>Sent when a window is being destroyed.</summary>
    public const int WM_DESTROY = 0x0002;

    /// <summary>Sent when the user selects a menu command.</summary>
    public const int WM_COMMAND = 0x0111;

    /// <summary>The base value for application-defined window messages.</summary>
    public const int WM_APP = 0x8000;

    /// <summary>Sent when the right mouse button is released.</summary>
    public const int WM_RBUTTONUP = 0x0205;

    /// <summary>Sent when the left mouse button is released.</summary>
    public const int WM_LBUTTONUP = 0x0202;

    /// <summary>Adds a tray icon.</summary>
    public const int NIM_ADD = 0;

    /// <summary>Modifies an existing tray icon (also used to raise a balloon).</summary>
    public const int NIM_MODIFY = 1;

    /// <summary>Removes a tray icon.</summary>
    public const int NIM_DELETE = 2;

    /// <summary>Indicates the callback message field is valid.</summary>
    public const int NIF_MESSAGE = 0x1;

    /// <summary>Indicates the icon field is valid.</summary>
    public const int NIF_ICON = 0x2;

    /// <summary>Indicates the tooltip field is valid.</summary>
    public const int NIF_TIP = 0x4;

    /// <summary>Indicates the balloon fields are valid.</summary>
    public const int NIF_INFO = 0x10;

    /// <summary>Shows an information icon on a balloon.</summary>
    public const int NIIF_INFO = 0x1;

    /// <summary>Shows a warning icon on a balloon.</summary>
    public const int NIIF_WARNING = 0x2;

    /// <summary>Shows an error icon on a balloon.</summary>
    public const int NIIF_ERROR = 0x3;

    /// <summary>Positions the context menu relative to the right mouse button.</summary>
    public const uint TPM_RIGHTBUTTON = 0x0002;

    /// <summary>Creates a message box with Yes and No buttons.</summary>
    public const uint MB_YESNO = 0x4;

    /// <summary>Shows a question-mark icon on a message box.</summary>
    public const uint MB_ICONQUESTION = 0x20;

    /// <summary>Shows a warning icon on a message box.</summary>
    public const uint MB_ICONWARNING = 0x30;

    /// <summary>Makes a message box system-modal so it surfaces above other windows.</summary>
    public const uint MB_SYSTEMMODAL = 0x1000;

    /// <summary>The command identifier returned when the user chooses Yes.</summary>
    public const int IDYES = 6;

    /// <summary>Appends a text item to a menu.</summary>
    public const uint MF_STRING = 0x0;

    /// <summary>Appends a separator to a menu.</summary>
    public const uint MF_SEPARATOR = 0x800;

    /// <summary>Disables (grays out) a menu item.</summary>
    public const uint MF_GRAYED = 0x1;

    /// <summary>The predefined application icon.</summary>
    public const int IDI_APPLICATION = 32512;

    /// <summary>Requests an icon image from LoadImage.</summary>
    public const uint IMAGE_ICON = 1;

    /// <summary>Loads an image from a file rather than a module resource.</summary>
    public const uint LR_LOADFROMFILE = 0x10;

    /// <summary>The system metric for the recommended small-icon width.</summary>
    public const int SM_CXSMICON = 49;

    /// <summary>The system metric for the recommended small-icon height.</summary>
    public const int SM_CYSMICON = 50;

    /// <summary>The information class used to set a job object's extended limits.</summary>
    public const int JobObjectExtendedLimitInformation = 9;

    /// <summary>The limit flag that kills all assigned processes when the job handle closes.</summary>
    public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    /// <summary>Retrieves the module handle used when registering the window class.</summary>
    [DllImport("kernel32", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetModuleHandleW(char* name);

    /// <summary>Registers the hidden window class that receives tray callbacks.</summary>
    [DllImport("user32")]
    public static extern ushort RegisterClassExW(WNDCLASSEXW* windowClass);

    /// <summary>Creates the hidden message window that owns the tray icon and menu.</summary>
    [DllImport("user32", CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateWindowExW(uint exStyle,
                                                char* className,
                                                char* windowName,
                                                uint style,
                                                int x,
                                                int y,
                                                int width,
                                                int height,
                                                IntPtr parent,
                                                IntPtr menu,
                                                IntPtr instance,
                                                IntPtr param);

    /// <summary>Provides default processing for messages the window procedure does not handle.</summary>
    [DllImport("user32")]
    public static extern IntPtr DefWindowProcW(IntPtr window,
                                               uint message,
                                               IntPtr wParam,
                                               IntPtr lParam);

    /// <summary>Retrieves the next message from the thread's message queue (blocking).</summary>
    [DllImport("user32")]
    public static extern int GetMessageW(MSG* message,
                                         IntPtr window,
                                         uint filterMin,
                                         uint filterMax);

    /// <summary>Translates virtual-key messages; part of the standard message pump.</summary>
    [DllImport("user32")]
    public static extern int TranslateMessage(MSG* message);

    /// <summary>Dispatches a message to the window procedure.</summary>
    [DllImport("user32")]
    public static extern IntPtr DispatchMessageW(MSG* message);

    /// <summary>Posts a quit message, ending the message loop.</summary>
    [DllImport("user32")]
    public static extern void PostQuitMessage(int exitCode);

    /// <summary>Destroys the hidden window during shutdown.</summary>
    [DllImport("user32")]
    public static extern int DestroyWindow(IntPtr window);

    /// <summary>Loads the shared application icon used for the tray.</summary>
    [DllImport("user32", CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadIconW(IntPtr instance, char* name);

    /// <summary>Loads an icon from a file (Ollama's icon) at a requested size.</summary>
    [DllImport("user32", CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadImageW(IntPtr instance,
                                           char* name,
                                           uint type,
                                           int cx,
                                           int cy,
                                           uint load);

    /// <summary>Returns a system metric, used here for the DPI-aware small-icon size.</summary>
    [DllImport("user32")]
    public static extern int GetSystemMetrics(int index);

    /// <summary>Destroys an icon handle obtained from <see cref="LoadImageW"/>.</summary>
    [DllImport("user32")]
    public static extern int DestroyIcon(IntPtr icon);

    /// <summary>Creates the pop-up context menu shown on right-click.</summary>
    [DllImport("user32")]
    public static extern IntPtr CreatePopupMenu();

    /// <summary>Appends an item (or separator) to the context menu.</summary>
    [DllImport("user32", CharSet = CharSet.Unicode)]
    public static extern int AppendMenuW(IntPtr menu,
                                         uint flags,
                                         IntPtr id,
                                         char* item);

    /// <summary>Displays the context menu and reports the chosen command.</summary>
    [DllImport("user32")]
    public static extern int TrackPopupMenu(IntPtr menu,
                                            uint flags,
                                            int x,
                                            int y,
                                            int reserved,
                                            IntPtr window,
                                            IntPtr rectangle);

    /// <summary>Destroys the context menu when it is rebuilt or on shutdown.</summary>
    [DllImport("user32")]
    public static extern int DestroyMenu(IntPtr menu);

    /// <summary>Reads the cursor position so the menu appears where the user clicked.</summary>
    [DllImport("user32")]
    public static extern int GetCursorPos(POINT* point);

    /// <summary>Foregrounds the window so the context menu dismisses on click-away.</summary>
    [DllImport("user32")]
    public static extern int SetForegroundWindow(IntPtr window);

    /// <summary>Posts a message to the window; used for thread-safe cross-thread signals.</summary>
    [DllImport("user32")]
    public static extern int PostMessageW(IntPtr window,
                                          uint message,
                                          IntPtr wParam,
                                          IntPtr lParam);

    /// <summary>Shows the modal Yes/No restart prompt.</summary>
    [DllImport("user32", CharSet = CharSet.Unicode)]
    public static extern int MessageBoxW(IntPtr window,
                                         char* text,
                                         char* caption,
                                         uint type);

    /// <summary>Adds, modifies, or removes the shell tray icon and its balloon notifications.</summary>
    [DllImport("shell32", CharSet = CharSet.Unicode)]
    public static extern int Shell_NotifyIconW(int message, NOTIFYICONDATAW* data);

    /// <summary>Creates a job object used to bind Ollama's lifetime to the supervisor.</summary>
    [DllImport("kernel32", CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateJobObjectW(IntPtr securityAttributes, char* name);

    /// <summary>Applies the kill-on-close limit to a job object.</summary>
    [DllImport("kernel32")]
    public static extern bool SetInformationJobObject(IntPtr job,
                                                      int infoClass,
                                                      void* info,
                                                      uint length);

    /// <summary>Assigns a process to a job object so it cannot outlive the job.</summary>
    [DllImport("kernel32")]
    public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    /// <summary>Closes a native handle (job object).  Sets the last error on failure.</summary>
    [DllImport("kernel32", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
}

/// <summary>Mirrors the Win32 <c>WNDCLASSEXW</c> structure, field for field, to register a window class.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct WNDCLASSEXW
{
    public uint cbSize;
    public uint style;
    public IntPtr lpfnWndProc;
    public int cbClsExtra;
    public int cbWndExtra;
    public IntPtr hInstance;
    public IntPtr hIcon;
    public IntPtr hCursor;
    public IntPtr hbrBackground;
    public char* lpszMenuName;
    public char* lpszClassName;
    public IntPtr hIconSm;
}

/// <summary>Mirrors the Win32 <c>MSG</c> structure, field for field, dispatched by the message loop.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct MSG
{
    public IntPtr hwnd;
    public uint message;
    public IntPtr wParam;
    public IntPtr lParam;
    public uint time;
    public int ptx;
    public int pty;
}

/// <summary>Mirrors the Win32 <c>POINT</c> structure, field for field.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct POINT
{
    public int x;
    public int y;
}

/// <summary>Mirrors the Win32 <c>NOTIFYICONDATAW</c> structure, field for field, used by <c>Shell_NotifyIcon</c>.</summary>
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal unsafe struct NOTIFYICONDATAW
{
    public uint cbSize;
    public IntPtr hWnd;
    public uint uID;
    public uint uFlags;
    public uint uCallbackMessage;
    public IntPtr hIcon;
    public fixed char szTip[128];
    public uint dwState;
    public uint dwStateMask;
    public fixed char szInfo[256];
    public uint uTimeoutOrVersion;
    public fixed char szInfoTitle[64];
    public uint dwInfoFlags;
    public Guid guidItem;
    public IntPtr hBalloonIcon;
}

/// <summary>Mirrors the Win32 <c>JOBOBJECT_BASIC_LIMIT_INFORMATION</c> structure, field for field.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct JOBOBJECT_BASIC_LIMIT_INFORMATION
{
    public long PerProcessUserTimeLimit;
    public long PerJobUserTimeLimit;
    public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public uint ActiveProcessLimit;
    public UIntPtr Affinity;
    public uint PriorityClass;
    public uint SchedulingClass;
}

/// <summary>Mirrors the Win32 <c>IO_COUNTERS</c> structure, field for field.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct IO_COUNTERS
{
    public ulong ReadOperationCount;
    public ulong WriteOperationCount;
    public ulong OtherOperationCount;
    public ulong ReadTransferCount;
    public ulong WriteTransferCount;
    public ulong OtherTransferCount;
}

/// <summary>Mirrors the Win32 <c>JOBOBJECT_EXTENDED_LIMIT_INFORMATION</c> structure, field for field.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
{
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
}
