using NUnit.Framework;

namespace Squire.PolychromeDisplayWatcher.Tests;

/// <summary>
/// The suite of tests for the <see cref="DisplayTransitionTracker"/> class.
/// </summary>
[TestFixture]
public class DisplayTransitionTrackerTests
{
    /// <summary>
    /// Verifies functionality of the <see cref="DisplayTransitionTracker.Observe"/> method.
    /// </summary>
    [Test]
    public void OffToOnSchedulesRestart()
    {
        var now = new DateTimeOffset(2026, 10, 25, 12, 0, 0, TimeSpan.Zero);
        var tracker = new DisplayTransitionTracker(TimeSpan.FromMinutes(1));

        var offAction = tracker.Observe(MonitorDisplayState.Off, now);
        var onAction = tracker.Observe(MonitorDisplayState.On, now.AddSeconds(1));

        Assert.That(offAction, Is.EqualTo(DisplayTransitionAction.None), "The initial off state should only establish transition history.");
        Assert.That(onAction, Is.EqualTo(DisplayTransitionAction.ScheduleRestart), "An off-to-on transition should schedule a restart.");
    }

    /// <summary>
    /// Verifies functionality of the <see cref="DisplayTransitionTracker.Observe"/> method.
    /// </summary>
    [Test]
    public void DimmedToOnDoesNotScheduleRestart()
    {
        var now = new DateTimeOffset(2026, 10, 25, 12, 0, 0, TimeSpan.Zero);
        var tracker = new DisplayTransitionTracker(TimeSpan.FromMinutes(1));

        tracker.Observe(MonitorDisplayState.Dimmed, now);
        var action = tracker.Observe(MonitorDisplayState.On, now.AddSeconds(1));

        Assert.That(action, Is.EqualTo(DisplayTransitionAction.None), "A dimmed-to-on transition should not restart Polychrome.");
    }

    /// <summary>
    /// Verifies functionality of the <see cref="DisplayTransitionTracker.Observe"/> method.
    /// </summary>
    [Test]
    public void DisplayOffCancelsPendingRestart()
    {
        var now = new DateTimeOffset(2026, 10, 25, 12, 0, 0, TimeSpan.Zero);
        var tracker = new DisplayTransitionTracker(TimeSpan.FromMinutes(1));

        tracker.Observe(MonitorDisplayState.Off, now);
        tracker.Observe(MonitorDisplayState.On, now.AddSeconds(1));
        var action = tracker.Observe(MonitorDisplayState.Off, now.AddSeconds(2));

        Assert.That(action, Is.EqualTo(DisplayTransitionAction.CancelRestart), "A second display-off transition should cancel the pending restart.");
    }

    /// <summary>
    /// Verifies functionality of the <see cref="DisplayTransitionTracker.Observe"/> method.
    /// </summary>
    [Test]
    public void CompletedRestartEnforcesCooldown()
    {
        var now = new DateTimeOffset(2026, 10, 25, 12, 0, 0, TimeSpan.Zero);
        var tracker = new DisplayTransitionTracker(TimeSpan.FromMinutes(1));

        tracker.Observe(MonitorDisplayState.Off, now);
        tracker.Observe(MonitorDisplayState.On, now.AddSeconds(1));
        tracker.CompleteRestartAttempt(now.AddSeconds(11));
        tracker.Observe(MonitorDisplayState.Off, now.AddSeconds(20));

        var action = tracker.Observe(MonitorDisplayState.On, now.AddSeconds(21));

        Assert.That(action, Is.EqualTo(DisplayTransitionAction.None), "A transition inside the cooldown should not schedule another restart.");
    }

    /// <summary>
    /// Verifies functionality of the <see cref="DisplayTransitionTracker.Observe"/> method.
    /// </summary>
    [Test]
    public void TransitionAfterCooldownSchedulesRestart()
    {
        var now = new DateTimeOffset(2026, 10, 25, 12, 0, 0, TimeSpan.Zero);
        var tracker = new DisplayTransitionTracker(TimeSpan.FromMinutes(1));

        tracker.Observe(MonitorDisplayState.Off, now);
        tracker.Observe(MonitorDisplayState.On, now.AddSeconds(1));
        tracker.CompleteRestartAttempt(now.AddSeconds(11));
        tracker.Observe(MonitorDisplayState.Off, now.AddMinutes(2));

        var action = tracker.Observe(MonitorDisplayState.On, now.AddMinutes(2).AddSeconds(1));

        Assert.That(action, Is.EqualTo(DisplayTransitionAction.ScheduleRestart), "A transition after the cooldown should schedule another restart.");
    }

    /// <summary>
    /// Verifies functionality of the <see cref="DisplayTransitionTracker.ScheduleInitialRestart"/> method.
    /// </summary>
    [Test]
    public void InitialRestartCanBeScheduledOnce()
    {
        var now = new DateTimeOffset(2026, 10, 26, 10, 0, 0, TimeSpan.Zero);
        var tracker = new DisplayTransitionTracker(TimeSpan.FromMinutes(1));

        var firstResult = tracker.ScheduleInitialRestart(now);
        var secondResult = tracker.ScheduleInitialRestart(now.AddSeconds(1));

        Assert.That(firstResult, Is.True, "The initial restart should be scheduled.");
        Assert.That(secondResult, Is.False, "A second restart should not be scheduled while the first is pending.");
    }

    /// <summary>
    /// Verifies functionality of the <see cref="DisplayTransitionTracker.ScheduleInitialRestart"/> method.
    /// </summary>
    [Test]
    public void DisplayOffCancelsInitialRestart()
    {
        var now = new DateTimeOffset(2026, 10, 26, 10, 0, 0, TimeSpan.Zero);
        var tracker = new DisplayTransitionTracker(TimeSpan.FromMinutes(1));

        tracker.ScheduleInitialRestart(now);
        var action = tracker.Observe(MonitorDisplayState.Off, now.AddSeconds(1));

        Assert.That(action, Is.EqualTo(DisplayTransitionAction.CancelRestart), "Display-off should cancel the pending initial restart.");
    }
}
