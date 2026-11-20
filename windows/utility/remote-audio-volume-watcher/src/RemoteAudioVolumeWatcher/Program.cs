using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Squire.RemoteAudioVolumeWatcher;

/// <summary>
/// Hosts the application entry point and composition root.
/// </summary>
internal static class Program
{
    private const string SingleInstanceMutexName = "Local\\Squire.RemoteAudioVolumeWatcher";

    /// <summary>
    /// Runs the audio watcher.
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

            Console.WriteLine($"remote-audio-volume-watcher {version?.ToString(3) ?? "unknown"}");

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
            using var coordinator = new AudioVolumeCoordinator(options.BaseVolumePercent, log);
            using var window = new MessageWindow(coordinator, log);

            return window.Run();
        }
        catch (Exception exception) when (
            exception is IOException or
            UnauthorizedAccessException or
            InvalidOperationException or
            ExternalException)
        {
            log.Error("The watcher stopped because of an unrecoverable error.", exception);

            return 1;
        }
    }
}