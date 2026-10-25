namespace Squire.PolychromeDisplayWatcher;

/// <summary>
/// Tracks display transitions and identifies when Polychrome should be restarted.
/// </summary>
internal sealed class DisplayTransitionTracker
{
    private readonly TimeSpan Cooldown;
    private readonly Lock Gate = new();
    private MonitorDisplayState? _previousState;
    private DateTimeOffset? _lastRestartAttempt;
    private bool _restartPending;

    /// <summary>
    /// Initializes a new instance of the <see cref="DisplayTransitionTracker"/> class.
    /// </summary>
    ///
    /// <param name="cooldown">The minimum interval between restart attempts.</param>
    ///
    public DisplayTransitionTracker(TimeSpan cooldown)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(cooldown, TimeSpan.Zero);

        Cooldown = cooldown;
    }

    /// <summary>
    /// Observes a display state and determines whether a pending restart should change.
    /// </summary>
    ///
    /// <param name="state">The current display state.</param>
    /// <param name="observedAt">The time at which Windows reported the state.</param>
    ///
    /// <returns>The action required for the pending restart.</returns>
    ///
    public DisplayTransitionAction Observe(MonitorDisplayState state, DateTimeOffset observedAt)
    {
        lock (Gate)
        {
            var previousState = _previousState;
            _previousState = state;

            if ((state == MonitorDisplayState.Off) && _restartPending)
            {
                _restartPending = false;
                return DisplayTransitionAction.CancelRestart;
            }

            if ((previousState != MonitorDisplayState.Off) || (state != MonitorDisplayState.On))
            {
                return DisplayTransitionAction.None;
            }

            if (_restartPending || !CooldownElapsed(observedAt))
            {
                return DisplayTransitionAction.None;
            }

            _restartPending = true;
            return DisplayTransitionAction.ScheduleRestart;
        }
    }

    /// <summary>
    /// Records completion of the pending restart attempt.
    /// </summary>
    ///
    /// <param name="completedAt">The time at which the attempt completed.</param>
    ///
    public void CompleteRestartAttempt(DateTimeOffset completedAt)
    {
        lock (Gate)
        {
            _lastRestartAttempt = completedAt;
            _restartPending = false;
        }
    }

    private bool CooldownElapsed(DateTimeOffset observedAt) =>
        (_lastRestartAttempt is null) || ((observedAt - _lastRestartAttempt.Value) >= Cooldown);
}
