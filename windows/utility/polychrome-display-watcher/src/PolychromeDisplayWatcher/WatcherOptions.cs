namespace Squire.PolychromeDisplayWatcher;

/// <summary>
/// Defines operational settings for the watcher.
/// </summary>
internal sealed class WatcherOptions
{
    /// <summary>The environment variable that overrides the Polychrome executable path.</summary>
    internal const string ExecutablePathEnvironmentVariable = "POLYCHROME_WATCHER_EXECUTABLE_PATH";

    /// <summary>The environment variable that overrides the restart delay.</summary>
    internal const string RestartDelayEnvironmentVariable = "POLYCHROME_WATCHER_RESTART_DELAY_SECONDS";

    /// <summary>The environment variable that overrides the restart cooldown.</summary>
    internal const string RestartCooldownEnvironmentVariable = "POLYCHROME_WATCHER_COOLDOWN_SECONDS";

    /// <summary>The environment variable that overrides the log path.</summary>
    internal const string LogPathEnvironmentVariable = "POLYCHROME_WATCHER_LOG_PATH";

    /// <summary>The process name used by Polychrome DISPLAY.</summary>
    public const string ProcessName = "Polychrome DISPLAY";

    /// <summary>The arguments used to relaunch Polychrome in its normal tray state.</summary>
    public const string LaunchArguments = "--startupWithMinimize";

    /// <summary>
    /// Gets the full path to the Polychrome executable.
    /// </summary>
    public required string ExecutablePath { get; init; }

    /// <summary>
    /// Gets the delay between display wake and restart.
    /// </summary>
    public required TimeSpan RestartDelay { get; init; }

    /// <summary>
    /// Gets the minimum interval between restart attempts.
    /// </summary>
    public required TimeSpan RestartCooldown { get; init; }

    /// <summary>
    /// Gets the log file path.
    /// </summary>
    public required string LogPath { get; init; }

    /// <summary>
    /// Creates options from the current environment.
    /// </summary>
    ///
    /// <returns>The configured watcher options.</returns>
    ///
    public static WatcherOptions FromEnvironment() => FromEnvironment(Environment.GetEnvironmentVariable);

    /// <summary>
    /// Creates options using the supplied environment lookup.
    /// </summary>
    ///
    /// <param name="getEnvironmentVariable">The environment lookup function.</param>
    ///
    /// <returns>The configured watcher options.</returns>
    ///
    internal static WatcherOptions FromEnvironment(Func<string, string?> getEnvironmentVariable)
    {
        ArgumentNullException.ThrowIfNull(getEnvironmentVariable);

        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        return new WatcherOptions
        {
            ExecutablePath = GetValue(
                getEnvironmentVariable,
                ExecutablePathEnvironmentVariable,
                Path.Combine(programFiles, "Polychrome DISPLAY", "Polychrome DISPLAY.exe")),
            RestartDelay = TimeSpan.FromSeconds(GetPositiveNumber(
                getEnvironmentVariable,
                RestartDelayEnvironmentVariable,
                10)),
            RestartCooldown = TimeSpan.FromSeconds(GetPositiveNumber(
                getEnvironmentVariable,
                RestartCooldownEnvironmentVariable,
                60)),
            LogPath = GetValue(
                getEnvironmentVariable,
                LogPathEnvironmentVariable,
                Path.Combine(localApplicationData, "polychrome-display-watcher", "logs", "watcher.log"))
        };
    }

    private static double GetPositiveNumber(
        Func<string, string?> getEnvironmentVariable,
        string variableName,
        double defaultValue)
    {
        var value = getEnvironmentVariable(variableName);

        if (string.IsNullOrWhiteSpace(value))
        {
            return defaultValue;
        }

        if (!double.TryParse(value, out var parsed) || (parsed <= 0))
        {
            throw new InvalidOperationException(
                $"Environment variable {variableName} must contain a positive number.");
        }

        return parsed;
    }

    private static string GetValue(
        Func<string, string?> getEnvironmentVariable,
        string variableName,
        string defaultValue)
    {
        var value = getEnvironmentVariable(variableName);

        return string.IsNullOrWhiteSpace(value) ? defaultValue : value;
    }
}
