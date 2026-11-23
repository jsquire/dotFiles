using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace RazerBatteryTray;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length > 0 && args[0].Equals("--diagnose", StringComparison.OrdinalIgnoreCase))
        {
            var reportPath = Path.Combine(AppContext.BaseDirectory, "razer-battery-diagnostics.txt");
            File.WriteAllText(reportPath, RazerBatteryDiagnostics.CreateReport());
            return;
        }

        ApplicationConfiguration.Initialize();
        Application.Run(new TrayContext());
    }
}

internal sealed class TrayContext : ApplicationContext
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromMinutes(5);
    private readonly NotifyIcon _tray;
    private readonly System.Windows.Forms.Timer _timer;
    private Icon? _currentIcon;

    public TrayContext()
    {
        _tray = new NotifyIcon
        {
            Visible = true,
            Text = "Razer battery: starting",
            ContextMenuStrip = BuildMenu()
        };

        SetIcon(BatteryIcon.Unknown());

        _timer = new System.Windows.Forms.Timer { Interval = (int)PollInterval.TotalMilliseconds };
        _timer.Tick += (_, _) => RefreshBattery();
        _timer.Start();

        RefreshBattery();
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Refresh now", null, (_, _) => RefreshBattery());
        menu.Items.Add("Quit", null, (_, _) => ExitThread());
        return menu;
    }

    private void RefreshBattery()
    {
        try
        {
            var reading = RazerBatteryReader.Read();
            if (reading is null)
            {
                _tray.Text = "Razer battery: device not found";
                SetIcon(BatteryIcon.Unknown());
                return;
            }

            if (reading.Percent is null)
            {
                _tray.Text = $"Razer battery: {reading.DeviceName} unsupported";
                SetIcon(BatteryIcon.Unknown());
                return;
            }

            _tray.Text = $"Razer battery: {reading.DeviceName} {reading.Percent:0}%";
            SetIcon(BatteryIcon.FromPercent(reading.Percent.Value));
        }
        catch (Exception ex)
        {
            _tray.Text = $"Razer battery: {TrimTooltip(ex.Message)}";
            SetIcon(BatteryIcon.Unknown());
        }
    }

    private void SetIcon(Icon icon)
    {
        _tray.Icon = icon;
        _currentIcon?.Dispose();
        _currentIcon = icon;
    }

    private static string TrimTooltip(string text)
    {
        const int max = 63;
        return text.Length <= max ? text : text[..max];
    }

    protected override void ExitThreadCore()
    {
        _timer.Stop();
        _timer.Dispose();
        _tray.Visible = false;
        _tray.Dispose();
        _currentIcon?.Dispose();
        base.ExitThreadCore();
    }
}

internal sealed record BatteryReading(string DeviceName, double? Percent);

internal static class RazerBatteryReader
{
    private const ushort RazerVendorId = 0x1532;

    private static readonly IReadOnlyDictionary<ushort, RazerProduct> Products = new Dictionary<ushort, RazerProduct>
    {
        [0x00A4] = new("Razer Mouse Dock Pro", 0x1f),
        [0x00AA] = new("Razer Basilisk V3 Pro Wired", 0x1f),
        [0x00AB] = new("Razer Basilisk V3 Pro Wireless", 0x1f),
        [0x00B9] = new("Razer Basilisk V3 X HyperSpeed", 0x1f),
        [0x007C] = new("Razer DeathAdder V2 Pro Wired", 0x3f),
        [0x007D] = new("Razer DeathAdder V2 Pro Wireless", 0x3f),
        [0x009C] = new("Razer DeathAdder V2 X HyperSpeed", 0x1f),
        [0x00B3] = new("Razer HyperPolling Wireless Dongle", 0x1f),
        [0x00B6] = new("Razer DeathAdder V3 Pro Wired", 0x1f),
        [0x00B7] = new("Razer DeathAdder V3 Pro Wireless", 0x1f),
        [0x0083] = new("Razer Basilisk X HyperSpeed", 0x1f),
        [0x0086] = new("Razer Basilisk Ultimate", 0x1f),
        [0x0088] = new("Razer Basilisk Ultimate Dongle", 0x1f),
        [0x008F] = new("Razer Naga V2 Pro Wired", 0x1f),
        [0x0090] = new("Razer Naga V2 Pro Wireless", 0x1f),
        [0x00A5] = new("Razer Viper V2 Pro Wired", 0x1f),
        [0x00A6] = new("Razer Viper V2 Pro Wireless", 0x1f),
        [0x007B] = new("Razer Viper Ultimate Wired", 0x3f),
        [0x0078] = new("Razer Viper Ultimate Wireless", 0x3f),
        [0x007A] = new("Razer Viper Ultimate Dongle", 0x3f),
        [0x0555] = new("Razer BlackShark V2 Pro RZ04-0453", 0x3f),
        [0x0528] = new("Razer BlackShark V2 Pro RZ04-0322", 0x3f),
        [0x00AF] = new("Razer Cobra Pro Wired", 0x1f),
        [0x00B0] = new("Razer Cobra Pro Wireless", 0x1f),
    };

    public static BatteryReading? Read()
    {
        string? matchedDeviceName = null;

        foreach (var devicePath in HidDeviceEnumerator.GetRazerDevicePaths(RazerVendorId, Products.Keys))
        {
            if (!Products.TryGetValue(devicePath.ProductId, out var product))
            {
                continue;
            }

            matchedDeviceName = product.Name;

            using var handle = NativeMethods.CreateFile(
                devicePath.Path,
                NativeMethods.QueryOnly,
                NativeMethods.FileShareRead | NativeMethods.FileShareWrite,
                IntPtr.Zero,
                NativeMethods.OpenExisting,
                0,
                IntPtr.Zero);

            if (handle.IsInvalid)
            {
                continue;
            }

            foreach (var transactionId in product.TransactionIds)
            {
                if (TryReadBattery(handle, transactionId, out var percent))
                {
                    return new BatteryReading(product.Name, percent);
                }
            }
        }

        var synapseReading = SynapseBatteryReader.ReadLatest();
        if (synapseReading is not null)
        {
            return synapseReading;
        }

        return matchedDeviceName is null ? null : new BatteryReading(matchedDeviceName, null);
    }

    // Razer feature reports come in two flavours: a 91-byte report whose first byte is the HID
    // report id (the 90-byte Razer message then starts at base=1), or a flat 90-byte report
    // (base=0). Try both; the collection that owns the battery answers with status 0x02 at [base].
    private static readonly int[] ReportSizes = { 91, 90 };

    private static bool TryReadBattery(SafeFileHandle handle, byte transactionId, out double percent)
    {
        percent = 0;

        foreach (var size in ReportSizes)
        {
            var @base = size - 90;
            var request = BuildBatteryRequest(size, @base, transactionId);
            if (!NativeMethods.HidD_SetFeature(handle, request, request.Length))
            {
                continue;
            }

            Thread.Sleep(500);

            var reply = new byte[size];
            if (!NativeMethods.HidD_GetFeature(handle, reply, reply.Length))
            {
                continue;
            }

            if (reply[@base] != 0x02)
            {
                continue;
            }

            var rawBattery = reply[@base + 9];
            if (rawBattery == 0)
            {
                continue;
            }

            percent = rawBattery / 255.0 * 100.0;
            return true;
        }

        return false;
    }

    private static byte[] BuildBatteryRequest(int size, int @base, byte transactionId)
    {
        var report = new byte[size];
        report[0] = 0x00;                 // HID report id (0) when size == 91; harmless when size == 90
        report[@base + 1] = transactionId;
        report[@base + 5] = 0x02;
        report[@base + 6] = 0x07;
        report[@base + 7] = 0x80;

        byte crc = 0;
        for (var i = @base + 2; i < @base + 8; i++)
        {
            crc ^= report[i];
        }

        report[@base + 88] = crc;
        return report;
    }

    private sealed record RazerProduct(string Name, params byte[] TransactionIds);
}

internal static partial class SynapseBatteryReader
{
    private static readonly string[] PreferredLogNames =
    [
        "systray_systrayv2.log",
        "profiles.log"
    ];

    public static BatteryReading? ReadLatest()
    {
        var logDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Razer",
            "RazerAppEngine",
            "User Data",
            "Logs");

        if (!Directory.Exists(logDirectory))
        {
            return null;
        }

        foreach (var file in GetCandidateLogs(logDirectory))
        {
            var text = ReadSharedText(file.FullName);
            if (string.IsNullOrWhiteSpace(text))
            {
                continue;
            }

            var match = LastLevelMatch(text);
            if (match is null)
            {
                continue;
            }

            return new BatteryReading("Razer Basilisk X HyperSpeed", match.Value);
        }

        return null;
    }

    private static IEnumerable<FileInfo> GetCandidateLogs(string logDirectory)
    {
        var files = new DirectoryInfo(logDirectory)
            .EnumerateFiles("*.log", SearchOption.TopDirectoryOnly)
            .Where(file =>
                PreferredLogNames.Contains(file.Name, StringComparer.OrdinalIgnoreCase) ||
                file.Name.Contains("products_131", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(file => file.LastWriteTimeUtc);

        return files;
    }

    private static double? LastLevelMatch(string text)
    {
        double? lastLevel = null;

        foreach (Match match in PowerStatusLevelRegex().Matches(text))
        {
            lastLevel = ParseLevel(match.Groups["level"].Value);
        }

        foreach (Match match in BatteryStateLevelRegex().Matches(text))
        {
            lastLevel = ParseLevel(match.Groups["level"].Value);
        }

        return lastLevel;
    }

    private static double? ParseLevel(string value)
    {
        return double.TryParse(value, NumberStyles.Number, CultureInfo.InvariantCulture, out var level)
            ? Math.Clamp(level, 0, 100)
            : null;
    }

    private static string? ReadSharedText(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd();
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    [GeneratedRegex("""powerStatus"\s*:\s*\{[^}]*"level"\s*:\s*(?<level>\d+(?:\.\d+)?)""", RegexOptions.IgnoreCase)]
    private static partial Regex PowerStatusLevelRegex();

    [GeneratedRegex("""setBatteryState\s+GET_BATTERY_STATE\s+\{[^}]*"level"\s*:\s*(?<level>\d+(?:\.\d+)?)""", RegexOptions.IgnoreCase)]
    private static partial Regex BatteryStateLevelRegex();
}

internal static class RazerBatteryDiagnostics
{
    public static string CreateReport()
    {
        var lines = new List<string>
        {
            $"Razer Battery Tray diagnostics",
            $"Created: {DateTimeOffset.Now:O}",
            ""
        };

        var devicePaths = HidDeviceEnumerator.GetRazerDevicePaths(0x1532, GetKnownProductIds()).ToList();
        lines.Add($"Matched Razer HID paths: {devicePaths.Count}");
        lines.Add("");

        foreach (var devicePath in devicePaths)
        {
            lines.Add($"PID_{devicePath.ProductId:X4}");
            lines.Add(devicePath.Path);

            using var handle = NativeMethods.CreateFile(
                devicePath.Path,
                NativeMethods.QueryOnly,
                NativeMethods.FileShareRead | NativeMethods.FileShareWrite,
                IntPtr.Zero,
                NativeMethods.OpenExisting,
                0,
                IntPtr.Zero);

            if (handle.IsInvalid)
            {
                lines.Add($"  open: failed Win32={Marshal.GetLastWin32Error()}");
                lines.Add("");
                continue;
            }

            lines.Add("  open: ok");

            foreach (var transactionId in new byte[] { 0x1f, 0x3f })
            {
                foreach (var size in new[] { 91, 90 })
                {
                    var @base = size - 90;
                    var request = BuildDiagnosticBatteryRequest(size, @base, transactionId);
                    var setOk = NativeMethods.HidD_SetFeature(handle, request, request.Length);
                    lines.Add($"  tx 0x{transactionId:X2} size {size} set-feature: {setOk} Win32={Marshal.GetLastWin32Error()}");

                    Thread.Sleep(500);

                    var reply = new byte[size];
                    var getOk = NativeMethods.HidD_GetFeature(handle, reply, reply.Length);
                    var status = getOk ? reply[@base] : (byte)0;
                    var rawBattery = getOk ? reply[@base + 9] : 0;
                    lines.Add($"  tx 0x{transactionId:X2} size {size} get-feature: {getOk} Win32={Marshal.GetLastWin32Error()} status=0x{status:X2} raw={rawBattery} percent={rawBattery / 255.0 * 100.0:0.0}");
                }
            }

            lines.Add("");
        }

        var reading = RazerBatteryReader.Read();
        lines.Add(reading is null
            ? "Final reader result: no battery reading"
            : reading.Percent is null
                ? $"Final reader result: {reading.DeviceName} found, but no supported battery report"
                : $"Final reader result: {reading.DeviceName} {reading.Percent:0.0}%");

        return string.Join(Environment.NewLine, lines);
    }

    private static IEnumerable<ushort> GetKnownProductIds() =>
    [
        0x00A4, 0x00AA, 0x00AB, 0x00B9, 0x007C, 0x007D, 0x009C, 0x00B3, 0x00B6, 0x00B7,
        0x0083, 0x0086, 0x0088, 0x008F, 0x0090, 0x00A5, 0x00A6, 0x007B, 0x0078, 0x007A,
        0x0555, 0x0528, 0x00AF, 0x00B0
    ];

    private static byte[] BuildDiagnosticBatteryRequest(int size, int @base, byte transactionId)
    {
        var report = new byte[size];
        report[0] = 0x00;
        report[@base + 1] = transactionId;
        report[@base + 5] = 0x02;
        report[@base + 6] = 0x07;
        report[@base + 7] = 0x80;

        byte crc = 0;
        for (var i = @base + 2; i < @base + 8; i++)
        {
            crc ^= report[i];
        }

        report[@base + 88] = crc;
        return report;
    }
}

internal readonly record struct HidDevicePath(string Path, ushort ProductId);

internal static class HidDeviceEnumerator
{
    public static IEnumerable<HidDevicePath> GetRazerDevicePaths(ushort vendorId, IEnumerable<ushort> productIds)
    {
        var productSet = new HashSet<ushort>(productIds);
        NativeMethods.HidD_GetHidGuid(out var hidGuid);

        var info = NativeMethods.SetupDiGetClassDevs(
            ref hidGuid,
            null,
            IntPtr.Zero,
            NativeMethods.DigcfPresent | NativeMethods.DigcfDeviceInterface);

        if (info == NativeMethods.InvalidHandleValue)
        {
            yield break;
        }

        try
        {
            var interfaceData = new NativeMethods.SpDeviceInterfaceData();
            interfaceData.CbSize = Marshal.SizeOf<NativeMethods.SpDeviceInterfaceData>();

            for (uint index = 0; NativeMethods.SetupDiEnumDeviceInterfaces(info, IntPtr.Zero, ref hidGuid, index, ref interfaceData); index++)
            {
                NativeMethods.SetupDiGetDeviceInterfaceDetail(info, ref interfaceData, IntPtr.Zero, 0, out var requiredSize, IntPtr.Zero);

                var detailData = Marshal.AllocHGlobal((int)requiredSize);
                try
                {
                    Marshal.WriteInt32(detailData, IntPtr.Size == 8 ? 8 : 6);

                    if (!NativeMethods.SetupDiGetDeviceInterfaceDetail(info, ref interfaceData, detailData, requiredSize, out _, IntPtr.Zero))
                    {
                        continue;
                    }

                    var path = ExtractDevicePath(detailData);
                    if (path is null)
                    {
                        continue;
                    }

                    var productId = ParseMatchingProductId(path, vendorId, productSet);
                    if (productId is not null)
                    {
                        yield return new HidDevicePath(path, productId.Value);
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(detailData);
                }
            }
        }
        finally
        {
            NativeMethods.SetupDiDestroyDeviceInfoList(info);
        }
    }

    private static string? ExtractDevicePath(IntPtr detailData)
    {
        foreach (var offset in new[] { 4, 8 })
        {
            var path = Marshal.PtrToStringUni(IntPtr.Add(detailData, offset));
            if (path?.Contains("vid_", StringComparison.OrdinalIgnoreCase) == true)
            {
                return path;
            }
        }

        return null;
    }

    private static ushort? ParseMatchingProductId(string path, ushort vendorId, HashSet<ushort> productIds)
    {
        var lower = path.ToLowerInvariant();
        var vidNeedle = $"vid_{vendorId:x4}";
        var pidIndex = lower.IndexOf("pid_", StringComparison.Ordinal);

        if (!lower.Contains(vidNeedle, StringComparison.Ordinal) || pidIndex < 0 || pidIndex + 8 > lower.Length)
        {
            return null;
        }

        var pidText = lower.Substring(pidIndex + 4, 4);
        if (!ushort.TryParse(pidText, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var productId))
        {
            return null;
        }

        return productIds.Contains(productId) ? productId : null;
    }
}

internal static class BatteryIcon
{
    public static Icon FromPercent(double percent)
    {
        var rounded = Math.Clamp((int)Math.Round(percent), 0, 100);
        var fill = rounded >= 50 ? Color.FromArgb(34, 197, 94) :
            rounded >= 20 ? Color.FromArgb(234, 179, 8) :
            Color.FromArgb(239, 68, 68);

        return Draw(rounded.ToString(CultureInfo.InvariantCulture), fill);
    }

    public static Icon Unknown() => Draw("?", Color.FromArgb(148, 163, 184));

    private static Icon Draw(string label, Color fill)
    {
        using var bitmap = new Bitmap(64, 64);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.Clear(Color.Transparent);

        using var outlinePen = new Pen(Color.FromArgb(30, 41, 59), 5);
        using var fillBrush = new SolidBrush(fill);
        using var textBrush = new SolidBrush(Color.White);
        using var font = new Font("Segoe UI", label.Length >= 3 ? 17 : 22, FontStyle.Bold, GraphicsUnit.Pixel);
        using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };

        var battery = new Rectangle(6, 14, 48, 36);
        graphics.DrawRoundedRectangle(outlinePen, battery, 7);
        graphics.FillRoundedRectangle(fillBrush, new Rectangle(10, 18, 40, 28), 5);
        graphics.FillRectangle(fillBrush, 54, 26, 5, 12);
        graphics.DrawString(label, font, textBrush, new RectangleF(5, 14, 50, 36), format);

        var iconHandle = bitmap.GetHicon();
        try
        {
            using var temp = Icon.FromHandle(iconHandle);
            return (Icon)temp.Clone();
        }
        finally
        {
            NativeMethods.DestroyIcon(iconHandle);
        }
    }
}

internal static class GraphicsExtensions
{
    public static void DrawRoundedRectangle(this Graphics graphics, Pen pen, Rectangle bounds, int radius)
    {
        using var path = RoundedPath(bounds, radius);
        graphics.DrawPath(pen, path);
    }

    public static void FillRoundedRectangle(this Graphics graphics, Brush brush, Rectangle bounds, int radius)
    {
        using var path = RoundedPath(bounds, radius);
        graphics.FillPath(brush, path);
    }

    private static GraphicsPath RoundedPath(Rectangle bounds, int radius)
    {
        var diameter = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

internal static class NativeMethods
{
    public const uint QueryOnly = 0x00000000;
    public const uint GenericRead = 0x80000000;
    public const uint GenericWrite = 0x40000000;
    public const uint FileShareRead = 0x00000001;
    public const uint FileShareWrite = 0x00000002;
    public const uint OpenExisting = 3;
    public const uint DigcfPresent = 0x00000002;
    public const uint DigcfDeviceInterface = 0x00000010;
    public static readonly IntPtr InvalidHandleValue = new(-1);

    [StructLayout(LayoutKind.Sequential)]
    public struct SpDeviceInterfaceData
    {
        public int CbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [DllImport("hid.dll")]
    public static extern void HidD_GetHidGuid(out Guid hidGuid);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_SetFeature(SafeFileHandle hidDeviceObject, byte[] reportBuffer, int reportBufferLength);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetFeature(SafeFileHandle hidDeviceObject, byte[] reportBuffer, int reportBufferLength);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, string? enumerator, IntPtr hwndParent, uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiEnumDeviceInterfaces(
        IntPtr deviceInfoSet,
        IntPtr deviceInfoData,
        ref Guid interfaceClassGuid,
        uint memberIndex,
        ref SpDeviceInterfaceData deviceInterfaceData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SetupDiGetDeviceInterfaceDetail(
        IntPtr deviceInfoSet,
        ref SpDeviceInterfaceData deviceInterfaceData,
        IntPtr deviceInterfaceDetailData,
        uint deviceInterfaceDetailDataSize,
        out uint requiredSize,
        IntPtr deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
