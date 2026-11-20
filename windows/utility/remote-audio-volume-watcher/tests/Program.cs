namespace Squire.RemoteAudioVolumeWatcher.Tests;

/// <summary>
/// Runs deterministic tests without external test packages.
/// </summary>
internal static class Program
{
    private static readonly List<string> Failures = [];

    /// <summary>
    /// Runs the test suite.
    /// </summary>
    ///
    /// <returns>Zero when all tests pass.</returns>
    ///
    private static int Main()
    {
        Run(nameof(DefaultVolumeIsFortyPercent), DefaultVolumeIsFortyPercent);
        Run(nameof(EnvironmentOverridesDefaults), EnvironmentOverridesDefaults);
        Run(nameof(InvalidEnvironmentVolumeIsRejected), InvalidEnvironmentVolumeIsRejected);
        Run(nameof(NewSessionReceivesFourApplications), NewSessionReceivesFourApplications);
        Run(nameof(EndpointChangeRestartsApplications), EndpointChangeRestartsApplications);
        Run(nameof(GenerationChangeRestartsApplications), GenerationChangeRestartsApplications);
        Run(nameof(DisappearedSessionCanBeReapplied), DisappearedSessionCanBeReapplied);

        if (Failures.Count == 0)
        {
            Console.WriteLine("All Remote Audio Volume Watcher tests passed.");
            return 0;
        }

        foreach (var failure in Failures)
        {
            Console.Error.WriteLine(failure);
        }

        return 1;
    }

    private static void DefaultVolumeIsFortyPercent()
    {
        var options = WatcherOptions.FromEnvironment(_ => null);

        Equal(40, options.BaseVolumePercent, "The default base volume should be 40%.");
    }

    private static void EnvironmentOverridesDefaults()
    {
        var values = new Dictionary<string, string?>
        {
            [WatcherOptions.BaseVolumeEnvironmentVariable] = "60",
            [WatcherOptions.LogPathEnvironmentVariable] = @"D:\Logs\remote-audio.log"
        };

        var options = WatcherOptions.FromEnvironment(name => values.GetValueOrDefault(name));

        Equal(60, options.BaseVolumePercent, "The environment should override the base volume.");
        Equal(@"D:\Logs\remote-audio.log", options.LogPath, "The environment should override the log path.");
    }

    private static void InvalidEnvironmentVolumeIsRejected()
    {
        Throws<InvalidOperationException>(
            () => WatcherOptions.FromEnvironment(
                name => name == WatcherOptions.BaseVolumeEnvironmentVariable ? "101" : null),
            WatcherOptions.BaseVolumeEnvironmentVariable);
    }

    private static void NewSessionReceivesFourApplications()
    {
        var tracker = new AudioSessionTracker();

        for (var index = 0; index < AudioSessionTracker.InitialApplicationCount; index++)
        {
            tracker.BeginScan("endpoint", 0);
            True(tracker.ShouldApply("session"), "The initialization window should apply the volume.");
            tracker.CompleteScan();
        }

        tracker.BeginScan("endpoint", 0);
        False(tracker.ShouldApply("session"), "The session should stop receiving automatic changes.");
        tracker.CompleteScan();
    }

    private static void EndpointChangeRestartsApplications()
    {
        var tracker = ExhaustSession();

        tracker.BeginScan("new-endpoint", 0);
        True(tracker.ShouldApply("session"), "A replacement endpoint should restart session initialization.");
    }

    private static void GenerationChangeRestartsApplications()
    {
        var tracker = ExhaustSession();

        tracker.BeginScan("endpoint", 1);
        True(tracker.ShouldApply("session"), "A new base-volume generation should reapply current sessions.");
    }

    private static void DisappearedSessionCanBeReapplied()
    {
        var tracker = ExhaustSession();

        tracker.BeginScan("endpoint", 0);
        tracker.CompleteScan();
        tracker.BeginScan("endpoint", 0);

        True(tracker.ShouldApply("session"), "A recreated session should receive the base volume.");
    }

    private static AudioSessionTracker ExhaustSession()
    {
        var tracker = new AudioSessionTracker();

        for (var index = 0; index < AudioSessionTracker.InitialApplicationCount; index++)
        {
            tracker.BeginScan("endpoint", 0);
            tracker.ShouldApply("session");
            tracker.CompleteScan();
        }

        return tracker;
    }

    private static void Run(string name, Action test)
    {
        try
        {
            test();
            Console.WriteLine($"PASS {name}");
        }
        catch (Exception exception)
        {
            Failures.Add($"FAIL {name}: {exception.Message}");
        }
    }

    private static void True(bool value, string message)
    {
        if (!value)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void False(bool value, string message) => True(!value, message);

    private static void Equal<T>(T expected, T actual, string message)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"{message} Expected '{expected}' and found '{actual}'.");
        }
    }

    private static void Throws<TException>(Action action, string messageFragment)
        where TException : Exception
    {
        try
        {
            action();
        }
        catch (TException exception)
        {
            if (!exception.Message.Contains(messageFragment, StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    $"The exception message did not contain '{messageFragment}'.",
                    exception);
            }

            return;
        }

        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }
}