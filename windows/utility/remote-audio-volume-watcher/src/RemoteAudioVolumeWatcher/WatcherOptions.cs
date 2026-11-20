namespace Squire.RemoteAudioVolumeWatcher;

/// <summary>
/// Defines operational settings for the watcher.
/// </summary>
internal sealed class WatcherOptions
{
    internal const string BaseVolumeEnvironmentVariable = "REMOTE_AUDIO_VOLUME_WATCHER_BASE_VOLUME_PERCENT";
    internal const string LogPathEnvironmentVariable = "REMOTE_AUDIO_VOLUME_WATCHER_LOG_PATH";
    internal const int DefaultBaseVolumePercent = 40;

    /// <summary>
    /// Gets the startup base volume.
    /// </summary>
    public required int BaseVolumePercent { get; init; }

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
        ArgumentNullException.ThrowIfNull(getEnvironmentVariable, nameof(getEnvironmentVariable));

        var localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        return new WatcherOptions
        {
            BaseVolumePercent = GetVolume(getEnvironmentVariable),
            LogPath = GetValue(
                getEnvironmentVariable,
                LogPathEnvironmentVariable,
                Path.Combine(localApplicationData, "remote-audio-volume-watcher", "logs", "watcher.log"))
        };
    }

    internal static void ValidateVolume(int volumePercent, string parameterName)
    {
        if ((volumePercent < 1) || (volumePercent > 100))
        {
            throw new ArgumentOutOfRangeException(parameterName, volumePercent, "Volume must be from 1 through 100.");
        }
    }

    private static int GetVolume(Func<string, string?> getEnvironmentVariable)
    {
        var value = getEnvironmentVariable(BaseVolumeEnvironmentVariable);

        if (string.IsNullOrWhiteSpace(value))
        {
            return DefaultBaseVolumePercent;
        }

        if (!int.TryParse(value, out var parsed))
        {
            throw new InvalidOperationException(
                $"Environment variable {BaseVolumeEnvironmentVariable} must contain a whole number from 1 through 100.");
        }

        try
        {
            ValidateVolume(parsed, BaseVolumeEnvironmentVariable);
        }
        catch (ArgumentOutOfRangeException exception)
        {
            throw new InvalidOperationException(
                $"Environment variable {BaseVolumeEnvironmentVariable} must contain a whole number from 1 through 100.",
                exception);
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