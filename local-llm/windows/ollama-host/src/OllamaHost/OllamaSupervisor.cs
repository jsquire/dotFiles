using System.Diagnostics;
using Microsoft.Extensions.Logging;

namespace Squire.OllamaHost;

/// <summary>
///   Owns the Ollama server as a monitored child process.  The child is placed in a
///   <see cref="JobObject"/> so it cannot outlive this supervisor, and is told to serve on the
///   configured upstream port via <c>OLLAMA_HOST</c>.  <see cref="Exited"/> is raised only on an
///   unexpected exit, so the caller can prompt the user to restart.
/// </summary>
///
public sealed class OllamaSupervisor : IDisposable
{
    /// <summary>The logger used to report lifecycle and update activity.</summary>
    private readonly ILogger<OllamaSupervisor> Logger;

    /// <summary>The job object that binds Ollama's lifetime to this supervisor.</summary>
    private readonly JobObject Job;

    /// <summary>Serializes start, stop, and restart operations.</summary>
    private readonly object SyncRoot = new();

    /// <summary>The loopback port Ollama is told to serve on via <c>OLLAMA_HOST</c>.</summary>
    private readonly int UpstreamPort;

    /// <summary>An explicit Ollama executable path, or <c>null</c> to resolve one automatically.</summary>
    private readonly string? ExecutablePathOverride;

    /// <summary>The WinGet package identifier upgraded by <see cref="Update"/>.</summary>
    private readonly string WinGetPackageId;

    /// <summary>The running Ollama process, or <c>null</c> while stopped.</summary>
    private volatile Process? _process;

    /// <summary>Indicates that the current exit was requested, suppressing <see cref="Exited"/>.</summary>
    private volatile bool _stopping;

    /// <summary>
    ///   Raised on a background thread when Ollama exits unexpectedly (that is, not as the result of a
    ///   deliberate <see cref="Stop"/>, <see cref="Restart"/>, or <see cref="Update"/>).
    /// </summary>
    ///
    public event Action? Exited;

    /// <summary>
    ///   Indicates whether the Ollama process is currently running.
    /// </summary>
    ///
    public bool IsRunning => IsAlive(_process);

    /// <summary>
    ///   Initializes a new instance of the <see cref="OllamaSupervisor"/> class.
    /// </summary>
    ///
    /// <param name="options">The application options supplying the upstream port, executable path, and WinGet package identifier.</param>
    /// <param name="logger">The logger used to report lifecycle and update activity.</param>
    ///
    /// <exception cref="ArgumentNullException">Occurs when <paramref name="options"/> or <paramref name="logger"/> is <c>null</c>.</exception>
    ///
    public OllamaSupervisor(OllamaHostOptions options,
                            ILogger<OllamaSupervisor> logger)
    {
        ArgumentNullException.ThrowIfNull(options, nameof(options));
        ArgumentNullException.ThrowIfNull(logger, nameof(logger));

        Logger = logger;
        Job = new JobObject(logger);
        UpstreamPort = options.OllamaUpstreamPort;
        ExecutablePathOverride = options.OllamaExecutablePath;
        WinGetPackageId = options.OllamaWinGetPackageId;
    }

    /// <summary>
    ///   Starts <c>ollama serve</c> as a monitored child if it is not already running.
    /// </summary>
    ///
    public void Start()
    {
        if (IsRunning)
        {
            return;
        }

        lock (SyncRoot)
        {
            if (IsRunning)
            {
                return;
            }

            _stopping = false;

            var startInfo = new ProcessStartInfo
            {
                FileName = ResolveExecutable(),
                Arguments = "serve",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            startInfo.Environment["OLLAMA_HOST"] = $"127.0.0.1:{UpstreamPort}";

            var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            process.OutputDataReceived += OnOutputDataReceived;
            process.ErrorDataReceived += OnErrorDataReceived;
            process.Exited += OnProcessExited;

            try
            {
                process.Start();
            }
            catch (Exception ex)
            {
                Logger.LogError(ex, "Failed to start ollama serve.");
                DetachProcessHandlers(process);
                process.Dispose();
                return;
            }

            if (!Job.Assign(process.Handle))
            {
                Logger.LogWarning("Failed to assign ollama to the job object; kill-on-close is not guaranteed.");
            }

            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            _process = process;

            Logger.LogInformation("ollama serve started (pid={ProcessId}) on 127.0.0.1:{UpstreamPort}.", process.Id, UpstreamPort);
        }
    }

    /// <summary>
    ///   Stops the Ollama process, detaching its event handlers and suppressing the unexpected-exit
    ///   notification.
    /// </summary>
    ///
    public void Stop()
    {
        lock (SyncRoot)
        {
            _stopping = true;

            var process = _process;
            _process = null;

            if (process is null)
            {
                return;
            }

            DetachProcessHandlers(process);

            if (IsAlive(process))
            {
                try
                {
                    process.Kill(entireProcessTree: true);
                }
                catch (Exception ex)
                {
                    Logger.LogWarning(ex, "Failed to kill ollama.");
                }
            }

            process.Dispose();
        }
    }

    /// <summary>
    ///   Stops and then starts the Ollama process.
    /// </summary>
    ///
    public void Restart()
    {
        Stop();
        Start();
    }

    /// <summary>
    ///   Stops Ollama, upgrades it through WinGet, and starts it again.
    /// </summary>
    ///
    /// <returns>A short, human-readable description of the update result.</returns>
    ///
    public string Update()
    {
        Logger.LogInformation("Stopping ollama and invoking winget upgrade.");
        Stop();

        var result = RunWinGetUpgrade();

        Start();
        return result;
    }

    /// <summary>
    ///   Stops Ollama and disposes the job object, which reaps any straggler process.
    /// </summary>
    ///
    public void Dispose()
    {
        Stop();
        Job.Dispose();
    }

    /// <summary>
    ///   Handles the child process exit, raising <see cref="Exited"/> for unexpected exits only.
    /// </summary>
    ///
    /// <param name="sender">The process that exited.</param>
    /// <param name="e">The event arguments.</param>
    ///
    private void OnProcessExited(object? sender,
                                EventArgs e)
    {
        var code = -1;

        try
        {
            code = ((Process)sender!).ExitCode;
        }
        catch (InvalidOperationException)
        {
            // The exit code is unavailable; leave the sentinel.
        }

        Logger.LogInformation("ollama serve exited (code={ExitCode}, intentional={Intentional}).", code, _stopping);

        if (!_stopping)
        {
            Exited?.Invoke();
        }
    }

    /// <summary>
    ///   Forwards a line of Ollama's standard output to the log.
    /// </summary>
    ///
    /// <param name="sender">The process that produced the output.</param>
    /// <param name="e">The output line, or a <c>null</c> data at end of stream.</param>
    ///
    private void OnOutputDataReceived(object? sender,
                                     DataReceivedEventArgs e) => LogChild(e.Data);

    /// <summary>
    ///   Forwards a line of Ollama's standard error to the log.
    /// </summary>
    ///
    /// <param name="sender">The process that produced the output.</param>
    /// <param name="e">The output line, or a <c>null</c> data at end of stream.</param>
    ///
    private void OnErrorDataReceived(object? sender,
                                    DataReceivedEventArgs e) => LogChild(e.Data);

    /// <summary>
    ///   Unsubscribes this supervisor's handlers from a process so it can be collected.
    /// </summary>
    ///
    /// <param name="process">The process to detach from.</param>
    ///
    private void DetachProcessHandlers(Process process)
    {
        process.OutputDataReceived -= OnOutputDataReceived;
        process.ErrorDataReceived -= OnErrorDataReceived;
        process.Exited -= OnProcessExited;
    }

    /// <summary>
    ///   Runs <c>winget upgrade</c> for the configured package and summarizes the outcome.
    /// </summary>
    ///
    /// <returns>A short, human-readable description of the update result.</returns>
    ///
    private string RunWinGetUpgrade()
    {
        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "winget",
                Arguments = $"upgrade --id {WinGetPackageId} --silent --accept-source-agreements --accept-package-agreements",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            using var winget = Process.Start(startInfo);

            if (winget is null)
            {
                return "Update failed: could not launch winget.";
            }

            var standardOutput = winget.StandardOutput.ReadToEnd();
            var standardError = winget.StandardError.ReadToEnd();

            winget.WaitForExit();
            Logger.LogInformation("winget exited {ExitCode}.\n{StandardOutput}\n{StandardError}", winget.ExitCode, standardOutput, standardError);

            return (winget.ExitCode == 0)
                ? "Ollama is up to date (or was updated)."
                : $"winget returned {winget.ExitCode} (see log).";
        }
        catch (Exception ex)
        {
            Logger.LogError(ex, "winget invocation failed.");
            return "Update failed: " + ex.Message;
        }
    }

    /// <summary>
    ///   Forwards a line of Ollama's output to the log.
    /// </summary>
    ///
    /// <param name="data">The output line, or <c>null</c> at end of stream.</param>
    ///
    private void LogChild(string? data)
    {
        if (data is { Length: > 0 })
        {
            Logger.LogInformation("[ollama] {Line}", data);
        }
    }

    /// <summary>
    ///   Resolves the Ollama executable from the configured override, the default install location, or
    ///   the <c>PATH</c>.
    /// </summary>
    ///
    /// <returns>The executable path or command to launch.</returns>
    ///
    private string ResolveExecutable()
    {
        if (!string.IsNullOrWhiteSpace(ExecutablePathOverride))
        {
            return ExecutablePathOverride;
        }

        return File.Exists(OllamaExecutable.DefaultInstalledPath) ? OllamaExecutable.DefaultInstalledPath : "ollama";
    }

    /// <summary>
    ///   Determines whether a process reference represents a live process.
    /// </summary>
    ///
    /// <param name="process">The process to test, or <c>null</c>.</param>
    ///
    /// <returns><c>true</c> when the process is non-null and has not exited; otherwise, <c>false</c>.</returns>
    ///
    private static bool IsAlive(Process? process)
    {
        try
        {
            return process is { HasExited: false };
        }
        catch (InvalidOperationException)
        {
            // The process reference was disposed by a concurrent stop; treat it as not alive.

            return false;
        }
    }
}
