using System.ComponentModel;

namespace Squire.PolychromeDisplayWatcher;

/// <summary>
/// Coordinates delayed Polychrome restarts with display-state transitions.
/// </summary>
internal sealed class DisplayWakeCoordinator : IDisposable
{
    private readonly FileLog Log;
    private readonly WatcherOptions Options;
    private readonly PolychromeRestarter Restarter;
    private readonly DisplayTransitionTracker Tracker;
    private readonly Timer RestartTimer;
    private bool _disposed;
    private int _restartInProgress;

    /// <summary>
    /// Initializes a new instance of the <see cref="DisplayWakeCoordinator"/> class.
    /// </summary>
    ///
    /// <param name="options">The watcher options.</param>
    /// <param name="restarter">The Polychrome process restarter.</param>
    /// <param name="log">The diagnostic log.</param>
    ///
    public DisplayWakeCoordinator(
        WatcherOptions options,
        PolychromeRestarter restarter,
        FileLog log)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(restarter);
        ArgumentNullException.ThrowIfNull(log);

        Options = options;
        Restarter = restarter;
        Log = log;
        Tracker = new DisplayTransitionTracker(options.RestartCooldown);
        RestartTimer = new Timer(RestartPolychrome, null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <summary>
    /// Processes a display-state notification.
    /// </summary>
    ///
    /// <param name="state">The display state reported by Windows.</param>
    ///
    public void Observe(MonitorDisplayState state)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        Log.Information($"Display state changed to {state}.");

        switch (Tracker.Observe(state, DateTimeOffset.UtcNow))
        {
            case DisplayTransitionAction.ScheduleRestart:
                Log.Information($"Scheduling Polychrome restart in {Options.RestartDelay.TotalSeconds:0.###} second(s).");
                RestartTimer.Change(Options.RestartDelay, Timeout.InfiniteTimeSpan);
                break;

            case DisplayTransitionAction.CancelRestart:
                Log.Information("Display turned off before the restart delay elapsed. Canceling the pending restart.");
                RestartTimer.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
                break;

            case DisplayTransitionAction.None:
                break;

            default:
                throw new InvalidOperationException("The display transition action is not supported.");
        }
    }

    /// <summary>
    /// Restarts Polychrome immediately and applies the normal restart cooldown.
    /// </summary>
    ///
    /// <returns><see langword="true"/> when the restart completed successfully.</returns>
    ///
    public bool RestartNow()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        RestartTimer.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);

        if (Interlocked.Exchange(ref _restartInProgress, 1) != 0)
        {
            Log.Information("A Polychrome restart is already in progress.");
            return false;
        }

        try
        {
            return Restarter.Restart();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or Win32Exception)
        {
            Log.Error("Polychrome restart failed.", exception);
            return false;
        }
        finally
        {
            Tracker.CompleteRestartAttempt(DateTimeOffset.UtcNow);
            Volatile.Write(ref _restartInProgress, 0);
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
        RestartTimer.Dispose();
    }

    private void RestartPolychrome(object? state)
    {
        RestartNow();
    }
}
