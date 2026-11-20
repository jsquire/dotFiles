namespace Squire.RemoteAudioVolumeWatcher;

/// <summary>
/// Coordinates the selected base volume with the background Core Audio worker.
/// </summary>
internal sealed class AudioVolumeCoordinator : IDisposable
{
    private readonly AudioVolumeWorker Worker;
    private int _baseVolumePercent;
    private int _generation;
    private bool _disposed;

    /// <summary>
    /// Gets the selected base volume.
    /// </summary>
    public int BaseVolumePercent => Volatile.Read(ref _baseVolumePercent);

    /// <summary>
    /// Gets the current worker status.
    /// </summary>
    public string Status => Worker.Status;

    /// <summary>
    /// Gets the generation associated with the selected volume.
    /// </summary>
    internal int Generation => Volatile.Read(ref _generation);

    /// <summary>
    /// Initializes a new instance of the <see cref="AudioVolumeCoordinator"/> class.
    /// </summary>
    ///
    /// <param name="baseVolumePercent">The initial base volume.</param>
    /// <param name="log">The diagnostic log.</param>
    ///
    public AudioVolumeCoordinator(int baseVolumePercent, FileLog log)
    {
        WatcherOptions.ValidateVolume(baseVolumePercent, nameof(baseVolumePercent));
        ArgumentNullException.ThrowIfNull(log, nameof(log));

        _baseVolumePercent = baseVolumePercent;
        Worker = new AudioVolumeWorker(this, log);
        Worker.Start();
    }

    /// <summary>
    /// Selects and immediately applies a base volume.
    /// </summary>
    ///
    /// <param name="volumePercent">The volume from 1 through 100.</param>
    ///
    public void SetBaseVolume(int volumePercent)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        WatcherOptions.ValidateVolume(volumePercent, nameof(volumePercent));

        Volatile.Write(ref _baseVolumePercent, volumePercent);
        Interlocked.Increment(ref _generation);
        Worker.ApplyNow();
    }

    /// <summary>
    /// Reapplies the selected base volume to the endpoint and current sessions.
    /// </summary>
    public void ApplyNow()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        Interlocked.Increment(ref _generation);
        Worker.ApplyNow();
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Worker.Dispose();
    }
}