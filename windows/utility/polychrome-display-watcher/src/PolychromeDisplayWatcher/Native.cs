using System.Runtime.InteropServices;

namespace Squire.PolychromeDisplayWatcher;

/// <summary>
/// Contains the native Windows APIs used by the display watcher.
/// </summary>
internal static partial class Native
{
    /// <summary>The window message that carries power notifications.</summary>
    internal const uint WmPowerBroadcast = 0x0218;

    /// <summary>The power event indicating a registered setting changed.</summary>
    internal const nuint PbtPowerSettingChange = 0x8013;

    /// <summary>The window message sent when a window is destroyed.</summary>
    internal const uint WmDestroy = 0x0002;

    /// <summary>The window message sent when a menu command is selected.</summary>
    internal const uint WmCommand = 0x0111;

    /// <summary>The window message sent when a window timer expires.</summary>
    internal const uint WmTimer = 0x0113;

    /// <summary>The base value for private application messages.</summary>
    internal const uint WmApp = 0x8000;

    /// <summary>The private message used for tray icon mouse activity.</summary>
    internal const uint WmTray = WmApp + 1;

    /// <summary>The mouse message sent when the left button is released.</summary>
    internal const int WmLeftButtonUp = 0x0202;

    /// <summary>The mouse message sent when the right button is released.</summary>
    internal const int WmRightButtonUp = 0x0205;

    /// <summary>The flag that directs power notifications to a window.</summary>
    internal const uint DeviceNotifyWindowHandle = 0;

    /// <summary>Adds a shell notification icon.</summary>
    internal const uint NotifyIconAdd = 0;

    /// <summary>Removes a shell notification icon.</summary>
    internal const uint NotifyIconDelete = 2;

    /// <summary>Indicates the tray callback message is valid.</summary>
    internal const uint NotifyIconMessage = 0x1;

    /// <summary>Indicates the tray icon handle is valid.</summary>
    internal const uint NotifyIconIcon = 0x2;

    /// <summary>Indicates the tray tooltip is valid.</summary>
    internal const uint NotifyIconTip = 0x4;

    /// <summary>Appends a text item to a native menu.</summary>
    internal const uint MenuString = 0;

    /// <summary>Appends a separator to a native menu.</summary>
    internal const uint MenuSeparator = 0x800;

    /// <summary>Disables a native menu item.</summary>
    internal const uint MenuGrayed = 0x1;

    /// <summary>Positions a context menu for right-button interaction.</summary>
    internal const uint TrackPopupRightButton = 0x0002;

    /// <summary>Requests an icon image from <see cref="LoadImage"/>.</summary>
    internal const uint ImageIcon = 1;

    /// <summary>Loads an image from a file.</summary>
    internal const uint LoadResourceFromFile = 0x10;

    /// <summary>The predefined shared application icon.</summary>
    internal const int ApplicationIcon = 32512;

    /// <summary>The small-icon width system metric.</summary>
    internal const int SmallIconWidth = 49;

    /// <summary>The small-icon height system metric.</summary>
    internal const int SmallIconHeight = 50;

    /// <summary>The handle value used to create a message-only window.</summary>
    internal static readonly nint HwndMessage = new(-3);

    /// <summary>The GUID for display-state changes in the interactive session.</summary>
    internal static readonly Guid SessionDisplayStatus = new("2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5");

    /// <summary>
    /// Defines the callback used by a native window.
    /// </summary>
    ///
    /// <param name="windowHandle">The target window.</param>
    /// <param name="message">The window message.</param>
    /// <param name="wParam">The first message parameter.</param>
    /// <param name="lParam">The second message parameter.</param>
    ///
    /// <returns>The message result.</returns>
    ///
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    internal delegate nint WindowProcedure(nint windowHandle, uint message, nuint wParam, nint lParam);

    /// <summary>
    /// Defines a registered window class.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct WindowClass
    {
        /// <summary>The structure size.</summary>
        internal uint _size;

        /// <summary>The class style.</summary>
        internal uint _style;

        /// <summary>The window procedure pointer.</summary>
        internal nint _windowProcedure;

        /// <summary>The extra class bytes.</summary>
        internal int _classExtraBytes;

        /// <summary>The extra window bytes.</summary>
        internal int _windowExtraBytes;

        /// <summary>The module instance.</summary>
        internal nint _instance;

        /// <summary>The class icon.</summary>
        internal nint _icon;

        /// <summary>The class cursor.</summary>
        internal nint _cursor;

        /// <summary>The background brush.</summary>
        internal nint _backgroundBrush;

        /// <summary>The menu resource name.</summary>
        internal nint _menuName;

        /// <summary>The class name.</summary>
        internal nint _className;

        /// <summary>The small class icon.</summary>
        internal nint _smallIcon;
    }

    /// <summary>
    /// Defines the header of a power-setting notification.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct PowerBroadcastSetting
    {
        /// <summary>The power setting that changed.</summary>
        internal Guid _powerSetting;

        /// <summary>The number of data bytes following the header.</summary>
        internal uint _dataLength;
    }

    /// <summary>
    /// Defines a native window message.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct Message
    {
        /// <summary>The target window.</summary>
        internal nint _windowHandle;

        /// <summary>The message identifier.</summary>
        internal uint _value;

        /// <summary>The first message parameter.</summary>
        internal nuint _wParam;

        /// <summary>The second message parameter.</summary>
        internal nint _lParam;

        /// <summary>The message timestamp.</summary>
        internal uint _time;

        /// <summary>The cursor X coordinate.</summary>
        internal int _pointX;

        /// <summary>The cursor Y coordinate.</summary>
        internal int _pointY;

        /// <summary>The private message value.</summary>
        internal uint _private;
    }

    /// <summary>
    /// Defines a native screen coordinate.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct Point
    {
        /// <summary>The horizontal coordinate.</summary>
        internal int _x;

        /// <summary>The vertical coordinate.</summary>
        internal int _y;
    }

    /// <summary>
    /// Defines the shell notification icon data.
    /// </summary>
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal unsafe struct NotifyIconData
    {
        /// <summary>The structure size.</summary>
        internal uint _size;

        /// <summary>The owner window.</summary>
        internal nint _windowHandle;

        /// <summary>The icon identifier.</summary>
        internal uint _identifier;

        /// <summary>The valid member flags.</summary>
        internal uint _flags;

        /// <summary>The tray callback message.</summary>
        internal uint _callbackMessage;

        /// <summary>The icon handle.</summary>
        internal nint _iconHandle;

        /// <summary>The hover tooltip.</summary>
        internal fixed char _tip[128];

        /// <summary>The icon state.</summary>
        internal uint _state;

        /// <summary>The valid icon state mask.</summary>
        internal uint _stateMask;

        /// <summary>The balloon body.</summary>
        internal fixed char _information[256];

        /// <summary>The balloon timeout or icon version.</summary>
        internal uint _timeoutOrVersion;

        /// <summary>The balloon title.</summary>
        internal fixed char _informationTitle[64];

        /// <summary>The balloon icon flags.</summary>
        internal uint _informationFlags;

        /// <summary>The registered icon GUID.</summary>
        internal Guid _itemGuid;

        /// <summary>The custom balloon icon.</summary>
        internal nint _balloonIcon;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "GetModuleHandleW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    internal static partial nint GetModuleHandle(string? moduleName);

    [LibraryImport("user32.dll", EntryPoint = "RegisterClassExW", SetLastError = true)]
    internal static partial ushort RegisterClass(ref WindowClass windowClass);

    [LibraryImport("user32.dll", EntryPoint = "UnregisterClassW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterClass(string className, nint instance);

    [LibraryImport("user32.dll", EntryPoint = "CreateWindowExW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    internal static partial nint CreateWindow(
        uint extendedStyle,
        string className,
        string windowName,
        uint style,
        int x,
        int y,
        int width,
        int height,
        nint parent,
        nint menu,
        nint instance,
        nint parameter);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DestroyWindow(nint windowHandle);

    [LibraryImport("user32.dll", EntryPoint = "DefWindowProcW")]
    internal static partial nint DefWindowProc(nint windowHandle, uint message, nuint wParam, nint lParam);

    [LibraryImport("user32.dll", SetLastError = true)]
    internal static partial nint RegisterPowerSettingNotification(
        nint recipient,
        in Guid powerSetting,
        uint flags);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnregisterPowerSettingNotification(nint handle);

    [LibraryImport("user32.dll", EntryPoint = "GetMessageW", SetLastError = true)]
    internal static partial int GetMessage(out Message message, nint windowHandle, uint minimumFilter, uint maximumFilter);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool TranslateMessage(in Message message);

    [LibraryImport("user32.dll", EntryPoint = "DispatchMessageW")]
    internal static partial nint DispatchMessage(in Message message);

    [LibraryImport("user32.dll")]
    internal static partial void PostQuitMessage(int exitCode);

    [LibraryImport("user32.dll", EntryPoint = "RegisterWindowMessageW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    internal static partial uint RegisterWindowMessage(string messageName);

    [LibraryImport("user32.dll", EntryPoint = "LoadImageW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    internal static partial nint LoadImage(
        nint instance,
        string name,
        uint type,
        int width,
        int height,
        uint loadFlags);

    [LibraryImport("user32.dll", EntryPoint = "LoadIconW", SetLastError = true)]
    internal static partial nint LoadIcon(nint instance, nint iconName);

    [LibraryImport("user32.dll")]
    internal static partial int GetSystemMetrics(int index);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DestroyIcon(nint icon);

    [LibraryImport("user32.dll", SetLastError = true)]
    internal static partial nint CreatePopupMenu();

    [LibraryImport("user32.dll", EntryPoint = "AppendMenuW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool AppendMenu(nint menu, uint flags, nuint identifier, string? item);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool TrackPopupMenu(
        nint menu,
        uint flags,
        int x,
        int y,
        int reserved,
        nint window,
        nint rectangle);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DestroyMenu(nint menu);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetCursorPos(out Point point);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetForegroundWindow(nint window);

    [LibraryImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool PostMessage(nint window, uint message, nuint wParam, nint lParam);

    [LibraryImport("user32.dll", SetLastError = true)]
    internal static partial nuint SetTimer(nint window, nuint identifier, uint intervalMilliseconds, nint callback);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool KillTimer(nint window, nuint identifier);

    [LibraryImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static unsafe partial bool ShellNotifyIcon(uint message, NotifyIconData* data);
}
