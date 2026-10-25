using NUnit.Framework;

namespace Squire.PolychromeDisplayWatcher.Tests;

/// <summary>
/// The suite of tests for the <see cref="WatcherOptions"/> class.
/// </summary>
[TestFixture]
public class WatcherOptionsTests
{
    /// <summary>
    /// Verifies functionality of the <see cref="WatcherOptions.FromEnvironment(Func{string, string?})"/> method.
    /// </summary>
    [Test]
    public void EnvironmentValuesOverrideDefaults()
    {
        var values = new Dictionary<string, string?>
        {
            [WatcherOptions.ExecutablePathEnvironmentVariable] = @"D:\Apps\Polychrome.exe",
            [WatcherOptions.RestartDelayEnvironmentVariable] = "15",
            [WatcherOptions.RestartCooldownEnvironmentVariable] = "90",
            [WatcherOptions.LogPathEnvironmentVariable] = @"D:\Logs\watcher.log"
        };

        var options = WatcherOptions.FromEnvironment(name => values.GetValueOrDefault(name));

        Assert.That(options.ExecutablePath, Is.EqualTo(@"D:\Apps\Polychrome.exe"), "The executable path should use the environment override.");
        Assert.That(options.RestartDelay, Is.EqualTo(TimeSpan.FromSeconds(15)), "The restart delay should use the environment override.");
        Assert.That(options.RestartCooldown, Is.EqualTo(TimeSpan.FromSeconds(90)), "The cooldown should use the environment override.");
        Assert.That(options.LogPath, Is.EqualTo(@"D:\Logs\watcher.log"), "The log path should use the environment override.");
    }

    /// <summary>
    /// Verifies functionality of the <see cref="WatcherOptions.FromEnvironment(Func{string, string?})"/> method.
    /// </summary>
    [TestCase(WatcherOptions.RestartDelayEnvironmentVariable, "0")]
    [TestCase(WatcherOptions.RestartCooldownEnvironmentVariable, "invalid")]
    public void NonPositiveOrInvalidDurationsAreRejected(string variableName, string value)
    {
        var values = new Dictionary<string, string?>
        {
            [variableName] = value
        };

        var exception = Assert.Throws<InvalidOperationException>(
            () => WatcherOptions.FromEnvironment(name => values.GetValueOrDefault(name)));

        Assert.That(exception!.Message, Does.Contain(variableName), "The validation message should identify the invalid environment variable.");
    }
}
