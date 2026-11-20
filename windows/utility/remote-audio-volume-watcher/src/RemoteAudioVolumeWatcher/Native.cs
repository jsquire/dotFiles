using System.Runtime.InteropServices;

namespace Squire.RemoteAudioVolumeWatcher;

/// <summary>
/// Contains the native Windows and Core Audio APIs used by the watcher.
/// </summary>
internal static unsafe partial class Native
{
    internal const uint WmDestroy = 0x0002;
    internal const uint WmCommand = 0x0111;
    internal const uint WmTimer = 0x0113;
    internal const uint WmApp = 0x8000;
    internal const uint WmTray = WmApp + 1;
    internal const int WmLeftButtonUp = 0x0202;
    internal const int WmRightButtonUp = 0x0205;
    internal const uint NotifyIconAdd = 0;
    internal const uint NotifyIconDelete = 2;
    internal const uint NotifyIconMessage = 0x1;
    internal const uint NotifyIconIcon = 0x2;
    internal const uint NotifyIconTip = 0x4;
    internal const uint MenuString = 0;
    internal const uint MenuChecked = 0x8;
    internal const uint MenuPopup = 0x10;
    internal const uint MenuSeparator = 0x800;
    internal const uint MenuGrayed = 0x1;
    internal const uint TrackPopupRightButton = 0x0002;
    internal const uint ImageIcon = 1;
    internal const uint LoadResourceFromFile = 0x10;
    internal const int ApplicationIcon = 32512;
    internal const int SmallIconWidth = 49;
    internal const int SmallIconHeight = 50;
    internal const uint CoinitMultithreaded = 0;
    internal const uint ClsContextAll = 23;
    internal const int AudioRender = 0;
    internal const int AudioRoleMultimedia = 1;
    internal const int WtsClientProtocolType = 16;
    internal const short WtsProtocolRdp = 2;
    internal const uint WtsCurrentSession = unchecked((uint)-1);

    internal static readonly nint HwndMessage = new(-3);
    internal static readonly Guid MmDeviceEnumeratorClass = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
    internal static readonly Guid MmDeviceEnumeratorInterface = new("A95664D2-9614-4F35-A746-DE8DB63617E6");
    internal static readonly Guid AudioEndpointVolumeInterface = new("5CDF2C82-841E-4546-9722-0CF74078229A");
    internal static readonly Guid AudioSessionManager2Interface = new("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");
    internal static readonly Guid AudioSessionControl2Interface = new("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D");
    internal static readonly Guid SimpleAudioVolumeInterface = new("87CE5498-68D6-44E5-9215-6DA47EF883D8");

    internal static void ThrowIfFailed(int result)
    {
        if (result < 0)
        {
            Marshal.ThrowExceptionForHR(result);
        }
    }

    internal static nint CreateDeviceEnumerator()
    {
        var classIdentifier = MmDeviceEnumeratorClass;
        var interfaceIdentifier = MmDeviceEnumeratorInterface;
        var result = CoCreateInstance(
            in classIdentifier,
            nint.Zero,
            ClsContextAll,
            in interfaceIdentifier,
            out var enumerator);

        ThrowIfFailed(result);

        return enumerator;
    }

    internal static nint GetDefaultAudioEndpoint(nint enumerator)
    {
        var vtable = *(nint**)enumerator;
        var endpoint = nint.Zero;
        var result = ((delegate* unmanaged[Stdcall]<nint, int, int, nint*, int>)vtable[4])(
            enumerator,
            AudioRender,
            AudioRoleMultimedia,
            &endpoint);

        ThrowIfFailed(result);

        return endpoint;
    }

    internal static string GetDeviceIdentifier(nint device)
    {
        var vtable = *(nint**)device;
        var value = nint.Zero;
        var result = ((delegate* unmanaged[Stdcall]<nint, nint*, int>)vtable[5])(device, &value);

        ThrowIfFailed(result);

        try
        {
            return Marshal.PtrToStringUni(value) ??
                throw new InvalidOperationException("The audio endpoint did not provide an identifier.");
        }
        finally
        {
            CoTaskMemFree(value);
        }
    }

    internal static nint ActivateAudioEndpointVolume(nint device) =>
        Activate(device, AudioEndpointVolumeInterface);

    internal static nint ActivateAudioSessionManager(nint device) =>
        Activate(device, AudioSessionManager2Interface);

    internal static float GetEndpointVolume(nint endpointVolume)
    {
        var vtable = *(nint**)endpointVolume;
        var value = 0f;
        var result = ((delegate* unmanaged[Stdcall]<nint, float*, int>)vtable[9])(endpointVolume, &value);

        ThrowIfFailed(result);

        return value;
    }

    internal static void SetEndpointVolume(nint endpointVolume, float value)
    {
        var vtable = *(nint**)endpointVolume;
        var result = ((delegate* unmanaged[Stdcall]<nint, float, nint, int>)vtable[7])(
            endpointVolume,
            value,
            nint.Zero);

        ThrowIfFailed(result);
    }

    internal static nint GetAudioSessionEnumerator(nint sessionManager)
    {
        var vtable = *(nint**)sessionManager;
        var enumerator = nint.Zero;
        var result = ((delegate* unmanaged[Stdcall]<nint, nint*, int>)vtable[5])(sessionManager, &enumerator);

        ThrowIfFailed(result);

        return enumerator;
    }

    internal static int GetAudioSessionCount(nint sessionEnumerator)
    {
        var vtable = *(nint**)sessionEnumerator;
        var count = 0;
        var result = ((delegate* unmanaged[Stdcall]<nint, int*, int>)vtable[3])(sessionEnumerator, &count);

        ThrowIfFailed(result);

        return count;
    }

    internal static nint GetAudioSession(nint sessionEnumerator, int index)
    {
        var vtable = *(nint**)sessionEnumerator;
        var session = nint.Zero;
        var result = ((delegate* unmanaged[Stdcall]<nint, int, nint*, int>)vtable[4])(
            sessionEnumerator,
            index,
            &session);

        ThrowIfFailed(result);

        return session;
    }

    internal static nint GetAudioSessionControl2(nint session) =>
        QueryInterface(session, AudioSessionControl2Interface);

    internal static string GetAudioSessionIdentifier(nint session)
    {
        var vtable = *(nint**)session;
        var value = nint.Zero;
        var result = ((delegate* unmanaged[Stdcall]<nint, nint*, int>)vtable[13])(session, &value);

        ThrowIfFailed(result);

        try
        {
            return Marshal.PtrToStringUni(value) ??
                throw new InvalidOperationException("The audio session did not provide an instance identifier.");
        }
        finally
        {
            CoTaskMemFree(value);
        }
    }

    internal static nint GetSimpleAudioVolume(nint session) =>
        QueryInterface(session, SimpleAudioVolumeInterface);

    internal static void SetSessionVolume(nint simpleAudioVolume, float value)
    {
        var vtable = *(nint**)simpleAudioVolume;
        var result = ((delegate* unmanaged[Stdcall]<nint, float, nint, int>)vtable[3])(
            simpleAudioVolume,
            value,
            nint.Zero);

        ThrowIfFailed(result);
    }

    internal static uint Release(nint instance)
    {
        if (instance == nint.Zero)
        {
            return 0;
        }

        var vtable = *(nint**)instance;

        return ((delegate* unmanaged[Stdcall]<nint, uint>)vtable[2])(instance);
    }

    [LibraryImport("ole32.dll")]
    internal static partial int CoInitializeEx(nint reserved, uint initialization);

    [LibraryImport("ole32.dll")]
    internal static partial void CoUninitialize();

    [LibraryImport("ole32.dll")]
    internal static partial void CoTaskMemFree(nint memory);

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

    [LibraryImport("user32.dll", EntryPoint = "LoadIconW", SetLastError = true)]
    internal static partial nint LoadIcon(nint instance, nint iconName);

    [LibraryImport("user32.dll", EntryPoint = "LoadImageW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    internal static partial nint LoadImage(
        nint instance,
        string name,
        uint type,
        int width,
        int height,
        uint loadFlags);

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
    internal static partial bool ShellNotifyIcon(uint message, NotifyIconData* data);

    [LibraryImport("wtsapi32.dll", EntryPoint = "WTSQuerySessionInformationW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool WtsQuerySessionInformation(
        nint server,
        uint sessionIdentifier,
        int informationClass,
        out nint buffer,
        out uint byteCount);

    [LibraryImport("wtsapi32.dll", EntryPoint = "WTSFreeMemory")]
    internal static partial void WtsFreeMemory(nint memory);

    private static nint Activate(nint device, Guid interfaceIdentifier)
    {
        var vtable = *(nint**)device;
        var instance = nint.Zero;
        var result = ((delegate* unmanaged[Stdcall]<nint, Guid*, uint, nint, nint*, int>)vtable[3])(
            device,
            &interfaceIdentifier,
            ClsContextAll,
            nint.Zero,
            &instance);

        ThrowIfFailed(result);

        return instance;
    }

    private static nint QueryInterface(nint instance, Guid interfaceIdentifier)
    {
        var vtable = *(nint**)instance;
        var resultInterface = nint.Zero;
        var result = ((delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)vtable[0])(
            instance,
            &interfaceIdentifier,
            &resultInterface);

        ThrowIfFailed(result);

        return resultInterface;
    }

    [LibraryImport("ole32.dll")]
    private static partial int CoCreateInstance(
        in Guid classIdentifier,
        nint outer,
        uint context,
        in Guid interfaceIdentifier,
        out nint instance);

    /// <summary>
    /// Defines the callback used by a native window.
    /// </summary>
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    internal delegate nint WindowProcedure(nint windowHandle, uint message, nuint wParam, nint lParam);

    /// <summary>
    /// Defines a registered window class.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct WindowClass
    {
        internal uint _size;
        internal uint _style;
        internal nint _windowProcedure;
        internal int _classExtraBytes;
        internal int _windowExtraBytes;
        internal nint _instance;
        internal nint _icon;
        internal nint _cursor;
        internal nint _backgroundBrush;
        internal nint _menuName;
        internal nint _className;
        internal nint _smallIcon;
    }

    /// <summary>
    /// Defines a native window message.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct Message
    {
        internal nint _windowHandle;
        internal uint _value;
        internal nuint _wParam;
        internal nint _lParam;
        internal uint _time;
        internal int _pointX;
        internal int _pointY;
        internal uint _private;
    }

    /// <summary>
    /// Defines a native screen coordinate.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct Point
    {
        internal int _x;
        internal int _y;
    }

    /// <summary>
    /// Defines the shell notification icon data.
    /// </summary>
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct NotifyIconData
    {
        internal uint _size;
        internal nint _windowHandle;
        internal uint _identifier;
        internal uint _flags;
        internal uint _callbackMessage;
        internal nint _iconHandle;
        internal fixed char _tip[128];
        internal uint _state;
        internal uint _stateMask;
        internal fixed char _information[256];
        internal uint _timeoutOrVersion;
        internal fixed char _informationTitle[64];
        internal uint _informationFlags;
        internal Guid _itemGuid;
        internal nint _balloonIcon;
    }
}