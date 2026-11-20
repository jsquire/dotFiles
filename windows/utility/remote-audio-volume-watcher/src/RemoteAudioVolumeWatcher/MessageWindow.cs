using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Squire.RemoteAudioVolumeWatcher;

/// <summary>
/// Hosts the native message loop used by the notification-area icon.
/// </summary>
internal sealed class MessageWindow : IDisposable
{
    private const string WindowClassName = "Squire.RemoteAudioVolumeWatcher.MessageWindow";

    private static readonly Native.WindowProcedure WindowProcedure = ProcessWindowMessage;
    private static MessageWindow? _current;

    private readonly FileLog Log;
    private readonly nint ModuleHandle;
    private readonly NativeTrayIcon TrayIcon;
    private nint _windowHandle;
    private nint _windowClassName;
    private bool _classRegistered;
    private bool _disposed;

    /// <summary>
    /// Initializes a new instance of the <see cref="MessageWindow"/> class.
    /// </summary>
    ///
    /// <param name="coordinator">The audio-volume coordinator.</param>
    /// <param name="log">The diagnostic log.</param>
    ///
    public MessageWindow(AudioVolumeCoordinator coordinator, FileLog log)
    {
        ArgumentNullException.ThrowIfNull(coordinator, nameof(coordinator));
        ArgumentNullException.ThrowIfNull(log, nameof(log));

        Log = log;
        TrayIcon = new NativeTrayIcon(coordinator, log);
        ModuleHandle = Native.GetModuleHandle(null);

        if (ModuleHandle == nint.Zero)
        {
            throw CreateWin32Exception("Unable to obtain the application module handle.");
        }
    }

    /// <summary>
    /// Runs the native message loop until Windows requests termination.
    /// </summary>
    ///
    /// <returns>The message-loop exit code.</returns>
    ///
    public int Run()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        CreateMessageWindow();
        TrayIcon.Initialize(_windowHandle, Exit);
        Log.Information("Remote Audio volume watcher message loop started.");

        while (true)
        {
            var result = Native.GetMessage(out var message, nint.Zero, 0, 0);

            if (result == 0)
            {
                return unchecked((int)message._wParam);
            }

            if (result == -1)
            {
                throw CreateWin32Exception("Unable to read the Windows message queue.");
            }

            Native.TranslateMessage(in message);
            Native.DispatchMessage(in message);
        }
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        TrayIcon.Dispose();

        if (_windowHandle != nint.Zero)
        {
            Native.DestroyWindow(_windowHandle);
            _windowHandle = nint.Zero;
        }

        if (_classRegistered)
        {
            Native.UnregisterClass(WindowClassName, ModuleHandle);
            _classRegistered = false;
        }

        if (_windowClassName != nint.Zero)
        {
            Marshal.FreeHGlobal(_windowClassName);
            _windowClassName = nint.Zero;
        }

        _current = null;
    }

    private void CreateMessageWindow()
    {
        _windowClassName = Marshal.StringToHGlobalUni(WindowClassName);

        var windowClass = new Native.WindowClass
        {
            _size = (uint)Marshal.SizeOf<Native.WindowClass>(),
            _windowProcedure = Marshal.GetFunctionPointerForDelegate(WindowProcedure),
            _instance = ModuleHandle,
            _className = _windowClassName
        };

        if (Native.RegisterClass(ref windowClass) == 0)
        {
            throw CreateWin32Exception("Unable to register the watcher window class.");
        }

        _classRegistered = true;
        _current = this;
        _windowHandle = Native.CreateWindow(
            0,
            WindowClassName,
            WindowClassName,
            0,
            0,
            0,
            0,
            0,
            Native.HwndMessage,
            nint.Zero,
            ModuleHandle,
            nint.Zero);

        if (_windowHandle == nint.Zero)
        {
            throw CreateWin32Exception("Unable to create the watcher message window.");
        }
    }

    private void Exit()
    {
        TrayIcon.Dispose();

        if (_windowHandle != nint.Zero)
        {
            Native.DestroyWindow(_windowHandle);
            _windowHandle = nint.Zero;
        }
    }

    private static nint ProcessWindowMessage(nint windowHandle, uint message, nuint wParam, nint lParam)
    {
        try
        {
            if (_current?.TrayIcon.TryHandleMessage(message, wParam, lParam) == true)
            {
                return nint.Zero;
            }

            if (message == Native.WmDestroy)
            {
                Native.PostQuitMessage(0);

                return nint.Zero;
            }
        }
        catch (Exception exception) when (
            exception is IOException or
            UnauthorizedAccessException or
            InvalidOperationException or
            ExternalException)
        {
            _current?.Log.Error("Unable to process a tray notification.", exception);
        }

        return Native.DefWindowProc(windowHandle, message, wParam, lParam);
    }

    private static Win32Exception CreateWin32Exception(string message) =>
        new(Marshal.GetLastWin32Error(), message);
}