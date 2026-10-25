namespace Squire.PolychromeDisplayWatcher;

/// <summary>
/// Identifies the action caused by a display-state transition.
/// </summary>
internal enum DisplayTransitionAction
{
    None,
    ScheduleRestart,
    CancelRestart
}
