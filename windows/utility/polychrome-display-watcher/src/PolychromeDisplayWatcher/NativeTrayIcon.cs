using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Squire.PolychromeDisplayWatcher;

/// <summary>
/// Provides the watcher's native system tray icon and context menu.
/// </summary>
internal sealed unsafe class NativeTrayIcon : IDisposable
{
    private const uint IconIdentifier = 1;
    private const int StatusCommand = 1000;
    private const int RestartCommand = 1001;
    private const int OpenLogCommand = 1002;
    private const int ExitCommand = 1003;
    private const string IconFileName = "security.ico";
    private const string Tooltip = "Polychrome Display Watcher";
    private const uint RetryIntervalMilliseconds = 2000;
    private const int MaximumRetryAttempts = 30;
    private const nuint RetryTimerIdentifier = 1;

    private readonly DisplayWakeCoordinator Coordinator;
    private readonly FileLog Log;
    private Action? _exitRequested;
    private nint _iconHandle;
    private nint _menuHandle;
    private nint _windowHandle;
    private Native.NotifyIconData _iconData;
    private uint _taskbarCreatedMessage;
    private bool _disposed;
    private bool _iconAdded;
    private bool _ownsIcon;
    private int _retryAttempts;
    private bool _retryTimerActive;

    /// <summary>
    /// Initializes a new instance of the <see cref="NativeTrayIcon"/> class.
    /// </summary>
    ///
    /// <param name="coordinator">The display-wake coordinator.</param>
    /// <param name="log">The diagnostic log.</param>
    ///
    public NativeTrayIcon(
        DisplayWakeCoordinator coordinator,
        FileLog log)
    {
        ArgumentNullException.ThrowIfNull(coordinator);
        ArgumentNullException.ThrowIfNull(log);

        Coordinator = coordinator;
        Log = log;
    }

    /// <summary>
    /// Creates the shell notification icon for the watcher window.
    /// </summary>
    ///
    /// <param name="windowHandle">The window that receives tray callbacks.</param>
    /// <param name="exitRequested">The callback that closes the watcher.</param>
    ///
    public void Initialize(nint windowHandle, Action exitRequested)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(exitRequested);

        _windowHandle = windowHandle;
        _exitRequested = exitRequested;
        _taskbarCreatedMessage = Native.RegisterWindowMessage("TaskbarCreated");
        _iconHandle = ResolveIcon();
        _iconData = new Native.NotifyIconData
        {
            _size = (uint)sizeof(Native.NotifyIconData),
            _windowHandle = windowHandle,
            _identifier = IconIdentifier,
            _flags = Native.NotifyIconMessage | Native.NotifyIconIcon | Native.NotifyIconTip,
            _callbackMessage = Native.WmTray,
            _iconHandle = _iconHandle
        };

        fixed (Native.NotifyIconData* data = &_iconData)
        {
            CopyInto(data->_tip, Tooltip, 127);
        }

        AddIcon();
    }

    /// <summary>
    /// Handles a tray-related window message.
    /// </summary>
    ///
    /// <param name="message">The window message identifier.</param>
    /// <param name="wParam">The first message parameter.</param>
    /// <param name="lParam">The second message parameter.</param>
    ///
    /// <returns><see langword="true"/> when the message was handled.</returns>
    ///
    public bool TryHandleMessage(uint message, nuint wParam, nint lParam)
    {
        if (message == Native.WmTray)
        {
            var mouseMessage = unchecked((int)((nuint)lParam & 0xFFFF));

            if ((mouseMessage == Native.WmRightButtonUp) || (mouseMessage == Native.WmLeftButtonUp))
            {
                ShowMenu();
            }

            return true;
        }

        if (message == Native.WmCommand)
        {
            HandleCommand(unchecked((int)(wParam & 0xFFFF)));
            return true;
        }

        if ((message == Native.WmTimer) && (wParam == RetryTimerIdentifier))
        {
            RetryAddIcon();
            return true;
        }

        if ((_taskbarCreatedMessage != 0) && (message == _taskbarCreatedMessage))
        {
            _iconAdded = false;
            _retryAttempts = 0;
            AddIcon();
            return true;
        }

        return false;
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        StopRetryTimer();
        RemoveIcon();

        if (_menuHandle != nint.Zero)
        {
            Native.DestroyMenu(_menuHandle);
            _menuHandle = nint.Zero;
        }

        if (_ownsIcon && (_iconHandle != nint.Zero))
        {
            Native.DestroyIcon(_iconHandle);
        }

        _iconHandle = nint.Zero;
        _ownsIcon = false;
    }

    private void AddIcon()
    {
        fixed (Native.NotifyIconData* data = &_iconData)
        {
            _iconAdded = Native.ShellNotifyIcon(Native.NotifyIconAdd, data);
        }

        if (_iconAdded)
        {
            StopRetryTimer();
            Log.Information("Tray icon added.");
        }
        else
        {
            StartRetryTimer();
        }
    }

    private void RetryAddIcon()
    {
        if (_iconAdded || _disposed)
        {
            StopRetryTimer();
            return;
        }

        _retryAttempts++;

        fixed (Native.NotifyIconData* data = &_iconData)
        {
            _iconAdded = Native.ShellNotifyIcon(Native.NotifyIconAdd, data);
        }

        if (_iconAdded)
        {
            StopRetryTimer();
            Log.Information($"Tray icon added after {_retryAttempts} retry attempt(s).");
            return;
        }

        if (_retryAttempts >= MaximumRetryAttempts)
        {
            StopRetryTimer();
            Log.Error(
                "Windows did not add the tray icon after 30 retry attempts.",
                new InvalidOperationException("The Windows notification area was not available."));
        }
    }

    private void StartRetryTimer()
    {
        if (_retryTimerActive)
        {
            return;
        }

        if (Native.SetTimer(_windowHandle, RetryTimerIdentifier, RetryIntervalMilliseconds, nint.Zero) == 0)
        {
            Log.Error("Windows did not create the tray icon retry timer.", CreateWin32Exception());
            return;
        }

        _retryTimerActive = true;
        Log.Information("The Windows notification area is not ready. Retrying the tray icon for up to 60 seconds.");
    }

    private void StopRetryTimer()
    {
        if (!_retryTimerActive)
        {
            return;
        }

        Native.KillTimer(_windowHandle, RetryTimerIdentifier);
        _retryTimerActive = false;
    }

    private void RemoveIcon()
    {
        if (!_iconAdded)
        {
            return;
        }

        fixed (Native.NotifyIconData* data = &_iconData)
        {
            Native.ShellNotifyIcon(Native.NotifyIconDelete, data);
        }

        _iconAdded = false;
    }

    private void ShowMenu()
    {
        if (_menuHandle != nint.Zero)
        {
            Native.DestroyMenu(_menuHandle);
        }

        _menuHandle = Native.CreatePopupMenu();

        if (_menuHandle == nint.Zero)
        {
            throw CreateWin32Exception();
        }

        AddMenuItem(StatusCommand, "Status: watching display wake", grayed: true);
        AddSeparator();
        AddMenuItem(RestartCommand, "Restart Polychrome");
        AddMenuItem(OpenLogCommand, "Open Log");
        AddSeparator();
        AddMenuItem(ExitCommand, "Exit Watcher");

        if (!Native.GetCursorPos(out var cursor))
        {
            throw CreateWin32Exception();
        }

        Native.SetForegroundWindow(_windowHandle);
        Native.TrackPopupMenu(
            _menuHandle,
            Native.TrackPopupRightButton,
            cursor._x,
            cursor._y,
            0,
            _windowHandle,
            nint.Zero);
        Native.PostMessage(_windowHandle, 0, 0, nint.Zero);
    }

    private void HandleCommand(int command)
    {
        switch (command)
        {
            case RestartCommand:
                Log.Information("Manual restart requested from the tray.");
                Coordinator.RestartNow();
                break;

            case OpenLogCommand:
                OpenLog();
                break;

            case ExitCommand:
                Log.Information("Exit requested from the tray.");
                _exitRequested?.Invoke();
                break;
        }
    }

    private void OpenLog()
    {
        var directory = Path.GetDirectoryName(Log.FullPath);

        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        if (!File.Exists(Log.FullPath))
        {
            File.WriteAllText(Log.FullPath, string.Empty);
        }

        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = Log.FullPath,
            UseShellExecute = true
        });

        if (process is null)
        {
            throw new InvalidOperationException("Windows did not open the watcher log.");
        }
    }

    private void AddMenuItem(int command, string text, bool grayed = false)
    {
        var flags = Native.MenuString | (grayed ? Native.MenuGrayed : 0);

        if (!Native.AppendMenu(_menuHandle, flags, (nuint)command, text))
        {
            throw CreateWin32Exception();
        }
    }

    private void AddSeparator()
    {
        if (!Native.AppendMenu(_menuHandle, Native.MenuSeparator, 0, null))
        {
            throw CreateWin32Exception();
        }
    }

    private nint ResolveIcon()
    {
        var iconPath = Path.Combine(AppContext.BaseDirectory, IconFileName);

        if (File.Exists(iconPath))
        {
            var icon = Native.LoadImage(
                nint.Zero,
                iconPath,
                Native.ImageIcon,
                Native.GetSystemMetrics(Native.SmallIconWidth),
                Native.GetSystemMetrics(Native.SmallIconHeight),
                Native.LoadResourceFromFile);

            if (icon != nint.Zero)
            {
                _ownsIcon = true;
                Log.Information($"Tray icon loaded from '{iconPath}'.");
                return icon;
            }

            Log.Error(
                $"Could not load the tray icon from '{iconPath}'. Using the Windows application icon.",
                CreateWin32Exception());
        }
        else
        {
            Log.Error(
                $"The tray icon was not found at '{iconPath}'. Using the Windows application icon.",
                new FileNotFoundException("The packaged tray icon was not found.", iconPath));
        }

        _ownsIcon = false;
        return Native.LoadIcon(nint.Zero, new nint(Native.ApplicationIcon));
    }

    private static void CopyInto(char* destination, string value, int maximumLength)
    {
        var length = Math.Min(value.Length, maximumLength);

        for (var index = 0; index < length; index++)
        {
            destination[index] = value[index];
        }

        destination[length] = '\0';
    }

    private static Win32Exception CreateWin32Exception() =>
        new(Marshal.GetLastWin32Error());
}
