using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;

using static Squire.OllamaHost.Native;

namespace Squire.OllamaHost;

/// <summary>
///   A framework-free system-tray presence built on raw Win32.  It owns a hidden message window,
///   the notify icon, the right-click menu, balloon notifications, and the Yes/No restart prompt.
///
///   <see cref="Run"/> pumps the message loop and blocks until the app exits. Background threads
///   communicate with the UI thread only through <c>PostMessage</c> (see the Signal and Notify methods),
///   which is thread-safe.
/// </summary>
///
internal sealed unsafe class NativeTrayIcon
{
    /// <summary>The callback message the shell posts for tray-icon mouse activity.</summary>
    private const int WM_TRAY = WM_APP + 1;

    /// <summary>The message posted from a background thread to report an unexpected Ollama exit.</summary>
    private const int WM_SIG_OLLAMA_EXITED = WM_APP + 2;

    /// <summary>The message posted from a background thread to report a proxy fault.</summary>
    private const int WM_SIG_PROXY_FAULT = WM_APP + 3;

    /// <summary>The message posted from a background thread to flush queued balloon notifications.</summary>
    private const int WM_SIG_BALLOON = WM_APP + 4;

    /// <summary>The status line command identifier.</summary>
    private const int ID_STATUS = 1001;

    /// <summary>The "Restart Ollama" command identifier.</summary>
    private const int ID_RESTART_OLLAMA = 1002;

    /// <summary>The "Restart Proxy" command identifier.</summary>
    private const int ID_RESTART_PROXY = 1003;

    /// <summary>The "Update Ollama" command identifier.</summary>
    private const int ID_UPDATE = 1004;

    /// <summary>The "Exit" command identifier.</summary>
    private const int ID_EXIT = 1005;

    /// <summary>The single live instance, so the static window procedure can dispatch to it.</summary>
    private static NativeTrayIcon? _instance;

    /// <summary>The logger used to report message-loop faults.</summary>
    private readonly ILogger<NativeTrayIcon> Logger;

    /// <summary>Balloon notifications queued from background threads, drained on the UI thread.</summary>
    private readonly ConcurrentQueue<(string Title, string Text)> Balloons = new();

    /// <summary>The path of Ollama's icon file (app.ico) shown in the tray, or <c>null</c>.</summary>
    private readonly string? OllamaIconPath;

    /// <summary>The hidden message window handle.</summary>
    private IntPtr _hwnd;

    /// <summary>The current context menu handle, rebuilt on each right-click.</summary>
    private IntPtr _hmenu;

    /// <summary>The notify-icon data used for add, modify, and delete calls.</summary>
    private NOTIFYICONDATAW _nid;

    /// <summary>The text shown on the menu's status line.</summary>
    private string _status = "starting";

    /// <summary>The tray icon extracted from this executable, or <see cref="IntPtr.Zero"/> when the shared icon is used.</summary>
    private IntPtr _iconSmall;

    /// <summary>Raised when the user selects "Restart Ollama".</summary>
    public event Action? RestartOllamaRequested;

    /// <summary>Raised when the user selects "Restart Proxy".</summary>
    public event Action? RestartProxyRequested;

    /// <summary>Raised when the user selects "Update Ollama".</summary>
    public event Action? UpdateOllamaRequested;

    /// <summary>Raised when the user selects "Exit".</summary>
    public event Action? ExitRequested;

    /// <summary>Raised on the UI thread after <see cref="SignalOllamaExited"/> is posted.</summary>
    public event Action? OllamaExitedSignaled;

    /// <summary>Raised on the UI thread after <see cref="SignalProxyFault"/> is posted.</summary>
    public event Action? ProxyFaultSignaled;

    /// <summary>
    ///   A balloon to display once the icon is created, or <c>null</c> for none.
    /// </summary>
    ///
    public (string Title, string Text)? StartupBalloon { get; set; }

    /// <summary>
    ///   Initializes a new instance of the <see cref="NativeTrayIcon"/> class.
    /// </summary>
    ///
    /// <param name="logger">The logger used to report message-loop faults.</param>
    /// <param name="ollamaIconPath">The path of Ollama's icon file, or <c>null</c> to use the shared application icon.</param>
    ///
    /// <exception cref="ArgumentNullException">Occurs when <paramref name="logger"/> is <c>null</c>.</exception>
    ///
    public NativeTrayIcon(ILogger<NativeTrayIcon> logger,
                    string? ollamaIconPath)
    {
        ArgumentNullException.ThrowIfNull(logger, nameof(logger));

        Logger = logger;
        OllamaIconPath = ollamaIconPath;
    }

    /// <summary>
    ///   Updates the text shown on the menu's status line.
    /// </summary>
    ///
    /// <param name="status">The status text to display.</param>
    ///
    public void SetStatus(string status) => _status = status;

    /// <summary>
    ///   Creates the tray icon and runs the Win32 message loop, blocking until the app quits.
    /// </summary>
    ///
    public void Run()
    {
        if (Interlocked.CompareExchange(ref _instance, this, null) != null)
        {
            throw new InvalidOperationException("Only one instance of TrayIcon is allowed.");
        }

        var instance = GetModuleHandleW(null);

        fixed (char* className = "OllamaHostTrayClass")
        {
            var windowClass = new WNDCLASSEXW
            {
                cbSize = (uint)sizeof(WNDCLASSEXW),
                lpfnWndProc = (IntPtr)(delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, IntPtr, IntPtr>)&WndProcThunk,
                hInstance = instance,
                lpszClassName = className
            };

            RegisterClassExW(&windowClass);
            _hwnd = CreateWindowExW(0, className, className, 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        }

        var icon = ResolveIcon();

        _nid = new NOTIFYICONDATAW
        {
            cbSize = (uint)sizeof(NOTIFYICONDATAW),
            hWnd = _hwnd,
            uID = 1,
            uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage = WM_TRAY,
            hIcon = icon
        };

        SetTip("Ollama Host");

        fixed (NOTIFYICONDATAW* data = &_nid)
        {
            Shell_NotifyIconW(NIM_ADD, data);
        }

        if (StartupBalloon is { } balloon)
        {
            ShowBalloon(balloon.Title, balloon.Text);
        }

        MSG message;

        while (GetMessageW(&message, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }

    /// <summary>
    ///   Signals from any thread that Ollama exited; the notification is raised on the UI thread.
    /// </summary>
    ///
    public void SignalOllamaExited() => PostMessageW(_hwnd, WM_SIG_OLLAMA_EXITED, IntPtr.Zero, IntPtr.Zero);

    /// <summary>
    ///   Signals from any thread that the proxy faulted; the notification is raised on the UI thread.
    /// </summary>
    ///
    public void SignalProxyFault() => PostMessageW(_hwnd, WM_SIG_PROXY_FAULT, IntPtr.Zero, IntPtr.Zero);

    /// <summary>
    ///   Queues a balloon notification to be shown on the UI thread.  Safe to call from any thread.
    /// </summary>
    ///
    /// <param name="title">The notification title.</param>
    /// <param name="text">The notification body.</param>
    ///
    public void NotifyAsync(string title,
                            string text)
    {
        Balloons.Enqueue((title, text));
        PostMessageW(_hwnd, WM_SIG_BALLOON, IntPtr.Zero, IntPtr.Zero);
    }

    /// <summary>
    ///   Shows a modal Yes/No prompt.  Must be called on the UI thread (that is, from a signal handler).
    /// </summary>
    ///
    /// <param name="caption">The dialog caption.</param>
    /// <param name="text">The prompt text.</param>
    ///
    /// <returns><c>true</c> when the user chooses Yes; otherwise, <c>false</c>.</returns>
    ///
    public bool PromptYesNo(string caption,
                            string text)
    {
        fixed (char* body = text, title = caption)
        {
            return MessageBoxW(_hwnd, body, title, MB_YESNO | MB_ICONQUESTION | MB_SYSTEMMODAL) == IDYES;
        }
    }

    /// <summary>
    ///   Removes the tray icon and destroys the window, ending the message loop.
    /// </summary>
    ///
    public void Quit()
    {
        fixed (NOTIFYICONDATAW* data = &_nid)
        {
            Shell_NotifyIconW(NIM_DELETE, data);
        }

        if (_iconSmall != IntPtr.Zero)
        {
            DestroyIcon(_iconSmall);
            _iconSmall = IntPtr.Zero;
        }

        if (_hmenu != IntPtr.Zero)
        {
            DestroyMenu(_hmenu);
        }

        DestroyWindow(_hwnd);
    }

    /// <summary>
    ///   The instance window procedure that handles tray, command, and cross-thread signal messages.
    /// </summary>
    ///
    /// <param name="hwnd">The window handle.</param>
    /// <param name="message">The message identifier.</param>
    /// <param name="wParam">The message's first parameter.</param>
    /// <param name="lParam">The message's second parameter.</param>
    ///
    /// <returns>The message result.</returns>
    ///
    private IntPtr WndProc(IntPtr hwnd,
                           uint message,
                           IntPtr wParam,
                           IntPtr lParam)
    {
        switch (message)
        {
            case WM_TRAY:
                if ((int)(lParam & 0xFFFF) == WM_RBUTTONUP)
                {
                    ShowMenu();
                }

                return IntPtr.Zero;

            case WM_COMMAND:
                OnCommand((int)(wParam & 0xFFFF));
                return IntPtr.Zero;

            case WM_SIG_OLLAMA_EXITED:
                OllamaExitedSignaled?.Invoke();
                return IntPtr.Zero;

            case WM_SIG_PROXY_FAULT:
                ProxyFaultSignaled?.Invoke();
                return IntPtr.Zero;

            case WM_SIG_BALLOON:
                while (Balloons.TryDequeue(out var balloon))
                {
                    ShowBalloon(balloon.Title, balloon.Text);
                }

                return IntPtr.Zero;

            case WM_DESTROY:
                PostQuitMessage(0);
                return IntPtr.Zero;
        }

        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    /// <summary>
    ///   Routes a menu command to the corresponding event.
    /// </summary>
    ///
    /// <param name="id">The selected menu command identifier.</param>
    ///
    private void OnCommand(int id)
    {
        switch (id)
        {
            case ID_RESTART_OLLAMA:
                RestartOllamaRequested?.Invoke();
                break;

            case ID_RESTART_PROXY:
                RestartProxyRequested?.Invoke();
                break;

            case ID_UPDATE:
                UpdateOllamaRequested?.Invoke();
                break;

            case ID_EXIT:
                ExitRequested?.Invoke();
                break;
        }
    }

    /// <summary>
    ///   Rebuilds and displays the context menu at the cursor.
    /// </summary>
    ///
    private void ShowMenu()
    {
        if (_hmenu != IntPtr.Zero)
        {
            DestroyMenu(_hmenu);
        }

        _hmenu = CreatePopupMenu();
        AddItem(ID_STATUS, "Status: " + _status, grayed: true);
        AddSeparator();
        AddItem(ID_RESTART_OLLAMA, "Restart Ollama");
        AddItem(ID_RESTART_PROXY, "Restart Proxy");
        AddItem(ID_UPDATE, "Update Ollama (WinGet)");
        AddSeparator();
        AddItem(ID_EXIT, "Exit");

        POINT cursor;
        GetCursorPos(&cursor);

        // Foreground the window so the menu dismisses when the user clicks elsewhere.

        SetForegroundWindow(_hwnd);
        TrackPopupMenu(_hmenu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, _hwnd, IntPtr.Zero);
        PostMessageW(_hwnd, 0, IntPtr.Zero, IntPtr.Zero);
    }

    /// <summary>
    ///   Appends a text item to the current context menu.
    /// </summary>
    ///
    /// <param name="id">The command identifier for the item.</param>
    /// <param name="text">The item caption.</param>
    /// <param name="grayed">Whether the item is disabled (for example, the status line).</param>
    ///
    private void AddItem(int id,
                         string text,
                         bool grayed = false)
    {
        var flags = MF_STRING | (grayed ? MF_GRAYED : 0u);

        fixed (char* item = text)
        {
            AppendMenuW(_hmenu, flags, (IntPtr)id, item);
        }
    }

    /// <summary>
    ///   Appends a separator to the current context menu.
    /// </summary>
    ///
    private void AddSeparator() => AppendMenuW(_hmenu, MF_SEPARATOR, IntPtr.Zero, null);

    /// <summary>
    ///   Displays a balloon notification from the tray icon.
    /// </summary>
    ///
    /// <param name="title">The notification title.</param>
    /// <param name="text">The notification body.</param>
    ///
    private void ShowBalloon(string title,
                             string text)
    {
        _nid.uFlags = NIF_INFO;

        fixed (NOTIFYICONDATAW* data = &_nid)
        {
            CopyInto(data->szInfoTitle, title, 60);
            CopyInto(data->szInfo, text, 250);
        }

        _nid.dwInfoFlags = NIIF_INFO;

        fixed (NOTIFYICONDATAW* data = &_nid)
        {
            Shell_NotifyIconW(NIM_MODIFY, data);
        }

        // Restore the standard flags so later modifications do not re-trigger a balloon.

        _nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    }

    /// <summary>
    ///   Sets the tray icon's hover tooltip.
    /// </summary>
    ///
    /// <param name="tip">The tooltip text.</param>
    ///
    private void SetTip(string tip)
    {
        fixed (NOTIFYICONDATAW* data = &_nid)
        {
            CopyInto(data->szTip, tip, 120);
        }
    }

    /// <summary>
    ///   Loads the tray icon from Ollama's icon file (<see cref="OllamaIconPath"/>) at the DPI-aware
    ///   small-icon size, falling back to the shared application icon if it cannot be loaded.  A loaded
    ///   handle is owned by this instance and destroyed in <see cref="Quit"/>.
    /// </summary>
    ///
    /// <returns>The icon handle to display in the tray.</returns>
    ///
    private IntPtr ResolveIcon()
    {
        if (OllamaIconPath is not null)
        {
            var width = GetSystemMetrics(SM_CXSMICON);
            var height = GetSystemMetrics(SM_CYSMICON);
            IntPtr icon;

            fixed (char* file = OllamaIconPath)
            {
                icon = LoadImageW(IntPtr.Zero, file, IMAGE_ICON, width, height, LR_LOADFROMFILE);
            }

            if (icon != IntPtr.Zero)
            {
                _iconSmall = icon;
                return icon;
            }
        }

        return LoadIconW(IntPtr.Zero, (char*)IDI_APPLICATION);
    }

    /// <summary>
    ///   The native window procedure.  It is a static, unmanaged callback (required for NativeAOT) that
    ///   forwards to the single live instance.
    /// </summary>
    ///
    /// <param name="hwnd">The window handle.</param>
    /// <param name="message">The message identifier.</param>
    /// <param name="wParam">The message's first parameter.</param>
    /// <param name="lParam">The message's second parameter.</param>
    ///
    /// <returns>The message result.</returns>
    ///
    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static IntPtr WndProcThunk(IntPtr hwnd,
                                       uint message,
                                       IntPtr wParam,
                                       IntPtr lParam)
    {
        var instance = Volatile.Read(ref _instance);

        if (instance is null)
        {
            return DefWindowProcW(hwnd, message, wParam, lParam);
        }

        try
        {
            return instance.WndProc(hwnd, message, wParam, lParam);
        }
        catch (Exception ex)
        {
            instance.Logger.LogError(ex, "Tray message handler failed.");
            return IntPtr.Zero;
        }
    }

    /// <summary>
    ///   Copies a string into a fixed-size native buffer, truncating and null-terminating as needed.
    /// </summary>
    ///
    /// <param name="destination">The destination buffer.</param>
    /// <param name="value">The string to copy.</param>
    /// <param name="maxLength">The maximum number of characters to copy before the terminator.</param>
    ///
    private static void CopyInto(char* destination,
                                 string value,
                                 int maxLength)
    {
        var length = Math.Min(value.Length, maxLength);

        for (var index = 0; index < length; ++index)
        {
            destination[index] = value[index];
        }

        destination[length] = '\0';
    }
}
