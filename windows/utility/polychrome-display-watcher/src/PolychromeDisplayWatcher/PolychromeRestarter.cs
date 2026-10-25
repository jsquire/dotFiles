using System.ComponentModel;
using System.Diagnostics;

namespace Squire.PolychromeDisplayWatcher;

/// <summary>
/// Restarts the complete Polychrome DISPLAY process tree.
/// </summary>
internal sealed class PolychromeRestarter
{
    private static readonly TimeSpan ExitTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan ExitPollInterval = TimeSpan.FromMilliseconds(100);

    private readonly FileLog Log;
    private readonly WatcherOptions Options;

    /// <summary>
    /// Initializes a new instance of the <see cref="PolychromeRestarter"/> class.
    /// </summary>
    ///
    /// <param name="options">The watcher options.</param>
    /// <param name="log">The diagnostic log.</param>
    ///
    public PolychromeRestarter(WatcherOptions options, FileLog log)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(log);

        Options = options;
        Log = log;
    }

    /// <summary>
    /// Terminates all Polychrome processes and starts a fresh minimized instance.
    /// </summary>
    ///
    /// <returns><see langword="true"/> when the application was relaunched successfully.</returns>
    ///
    public bool Restart()
    {
        if (!File.Exists(Options.ExecutablePath))
        {
            Log.Error(
                $"Polychrome executable was not found at '{Options.ExecutablePath}'.",
                new FileNotFoundException("The configured Polychrome executable does not exist.", Options.ExecutablePath));
            return false;
        }

        var processes = Process.GetProcessesByName(WatcherOptions.ProcessName);

        try
        {
            Log.Information($"Restarting Polychrome DISPLAY. Found {processes.Length} running process(es).");

            foreach (var process in processes)
            {
                KillProcessTree(process);
            }

            if (!WaitForProcessesToExit())
            {
                Log.Error(
                    "Polychrome processes remained after the exit timeout.",
                    new TimeoutException($"Processes did not exit within {ExitTimeout}."));
                return false;
            }
        }
        finally
        {
            foreach (var process in processes)
            {
                process.Dispose();
            }
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = Options.ExecutablePath,
            Arguments = WatcherOptions.LaunchArguments,
            UseShellExecute = true,
            WorkingDirectory = Path.GetDirectoryName(Options.ExecutablePath)
        };

        using var startedProcess = Process.Start(startInfo);

        if (startedProcess is null)
        {
            Log.Error(
                "Windows did not return a process after launching Polychrome.",
                new InvalidOperationException("Process.Start returned null."));
            return false;
        }

        Log.Information($"Polychrome DISPLAY relaunched as process {startedProcess.Id}.");
        return true;
    }

    private void KillProcessTree(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
            Log.Information($"Polychrome process {process.Id} exited before it could be terminated.");
        }
        catch (Win32Exception exception)
        {
            Log.Error($"Unable to terminate Polychrome process {process.Id}.", exception);
        }
        catch (AggregateException exception)
        {
            Log.Error($"Unable to terminate the complete tree for Polychrome process {process.Id}.", exception);
        }
    }

    private static bool WaitForProcessesToExit()
    {
        var deadline = DateTimeOffset.UtcNow + ExitTimeout;

        while (DateTimeOffset.UtcNow < deadline)
        {
            var remainingProcesses = Process.GetProcessesByName(WatcherOptions.ProcessName);

            try
            {
                if (remainingProcesses.Length == 0)
                {
                    return true;
                }
            }
            finally
            {
                foreach (var process in remainingProcesses)
                {
                    process.Dispose();
                }
            }

            Thread.Sleep(ExitPollInterval);
        }

        return false;
    }
}
