using System.ComponentModel;
using System.Runtime.Versioning;

namespace Squire.PolychromeDisplayWatcher;

/// <summary>
/// Hosts the application entry point and composition root.
/// </summary>
internal static class Program
{
    /// <summary>The mutex name used to enforce a single running instance per user session.</summary>
    private const string SingleInstanceMutexName = "Local\\Squire.PolychromeDisplayWatcher";

    /// <summary>
    /// Runs the display watcher.
    /// </summary>
    ///
    /// <param name="args">The command-line arguments.</param>
    ///
    /// <returns>The process exit code.</returns>
    ///
    [SupportedOSPlatform("windows")]
    private static int Main(string[] args)
    {
        if ((args.Length > 0) && ((args[0] == "--version") || (args[0] == "-v")))
        {
            var version = typeof(Program).Assembly.GetName().Version;

            Console.WriteLine($"polychrome-display-watcher {version?.ToString(3) ?? "unknown"}");
            return 0;
        }

        var options = WatcherOptions.FromEnvironment();
        var log = new FileLog(options.LogPath);

        using var mutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out var created);

        if (!created)
        {
            log.Information("Another watcher instance is already running.");
            return 0;
        }

        try
        {
            var restarter = new PolychromeRestarter(options, log);

            using var coordinator = new DisplayWakeCoordinator(options, restarter, log);
            using var watcher = new DisplayPowerWatcher(coordinator, log);

            return watcher.Run();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or Win32Exception)
        {
            log.Error("The watcher stopped because of an unrecoverable error.", exception);
            return 1;
        }
    }
}
