namespace Squire.RemoteAudioVolumeWatcher;

/// <summary>
/// Tracks application audio sessions through a bounded initialization window.
/// </summary>
internal sealed class AudioSessionTracker
{
    internal const int InitialApplicationCount = 4;

    private readonly Dictionary<string, int> RemainingApplications = new(StringComparer.Ordinal);
    private readonly HashSet<string> ObservedSessions = new(StringComparer.Ordinal);
    private string? _endpointIdentifier;
    private int _generation = -1;

    /// <summary>
    /// Starts a scan for an endpoint and configuration generation.
    /// </summary>
    ///
    /// <param name="endpointIdentifier">The active endpoint identifier.</param>
    /// <param name="generation">The active base-volume generation.</param>
    ///
    public void BeginScan(string endpointIdentifier, int generation)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(endpointIdentifier);

        if (!string.Equals(_endpointIdentifier, endpointIdentifier, StringComparison.Ordinal) ||
            (_generation != generation))
        {
            RemainingApplications.Clear();
            _endpointIdentifier = endpointIdentifier;
            _generation = generation;
        }

        ObservedSessions.Clear();
    }

    /// <summary>
    /// Determines whether the base volume should be applied to an observed session.
    /// </summary>
    ///
    /// <param name="sessionIdentifier">The audio-session instance identifier.</param>
    ///
    /// <returns><see langword="true"/> during the session's initialization window.</returns>
    ///
    public bool ShouldApply(string sessionIdentifier)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionIdentifier);

        ObservedSessions.Add(sessionIdentifier);

        if (!RemainingApplications.TryGetValue(sessionIdentifier, out var remaining))
        {
            remaining = InitialApplicationCount;
        }

        if (remaining <= 0)
        {
            return false;
        }

        RemainingApplications[sessionIdentifier] = remaining - 1;

        return true;
    }

    /// <summary>
    /// Removes sessions that disappeared during the current scan.
    /// </summary>
    public void CompleteScan()
    {
        foreach (var identifier in RemainingApplications.Keys.ToArray())
        {
            if (!ObservedSessions.Contains(identifier))
            {
                RemainingApplications.Remove(identifier);
            }
        }
    }

    /// <summary>
    /// Clears endpoint and session history.
    /// </summary>
    public void Reset()
    {
        RemainingApplications.Clear();
        ObservedSessions.Clear();
        _endpointIdentifier = null;
        _generation = -1;
    }
}