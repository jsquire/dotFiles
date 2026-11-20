using System.Runtime.InteropServices;

namespace Squire.RemoteAudioVolumeWatcher;

/// <summary>
/// Applies the selected base volume through the Windows Core Audio interfaces.
/// </summary>
internal sealed class AudioVolumeWorker : IDisposable
{
    private const float VolumeComparisonTolerance = 0.005f;

    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(500);

    private readonly AudioVolumeCoordinator Coordinator;
    private readonly FileLog Log;
    private readonly AutoResetEvent WakeSignal = new(initialState: false);
    private readonly Lock StatusGate = new();
    private readonly Thread WorkerThread;
    private int _disposeRequested;
    private bool _disposed;
    private string _status = "Starting";

    /// <summary>
    /// Gets the current worker status.
    /// </summary>
    public string Status
    {
        get
        {
            lock (StatusGate)
            {
                return _status;
            }
        }
    }

    /// <summary>
    /// Initializes a new instance of the <see cref="AudioVolumeWorker"/> class.
    /// </summary>
    ///
    /// <param name="coordinator">The selected-volume coordinator.</param>
    /// <param name="log">The diagnostic log.</param>
    ///
    public AudioVolumeWorker(AudioVolumeCoordinator coordinator, FileLog log)
    {
        ArgumentNullException.ThrowIfNull(coordinator, nameof(coordinator));
        ArgumentNullException.ThrowIfNull(log, nameof(log));

        Coordinator = coordinator;
        Log = log;
        WorkerThread = new Thread(Run)
        {
            IsBackground = true,
            Name = "Remote Audio Volume Worker"
        };
    }

    /// <summary>
    /// Starts the Core Audio worker.
    /// </summary>
    public void Start()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        WorkerThread.Start();
    }

    /// <summary>
    /// Wakes the worker to immediately reapply the selected volume.
    /// </summary>
    public void ApplyNow()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        WakeSignal.Set();
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Volatile.Write(ref _disposeRequested, 1);
        WakeSignal.Set();

        if (WorkerThread.IsAlive && !WorkerThread.Join(TimeSpan.FromSeconds(5)))
        {
            Log.Error(
                "The Core Audio worker did not stop within five seconds.",
                new TimeoutException("The worker shutdown timed out."));
        }

        WakeSignal.Dispose();
    }

    private void Run()
    {
        var initializeResult = Native.CoInitializeEx(nint.Zero, Native.CoinitMultithreaded);

        try
        {
            Native.ThrowIfFailed(initializeResult);

            using var deviceEnumerator = new ComReference(Native.CreateDeviceEnumerator());
            var tracker = new AudioSessionTracker();
            var lastError = string.Empty;

            Log.Information($"Audio watcher started with a base volume of {Coordinator.BaseVolumePercent}%.");

            while (Volatile.Read(ref _disposeRequested) == 0)
            {
                try
                {
                    Scan(deviceEnumerator.Handle, tracker);
                    lastError = string.Empty;
                }
                catch (Exception exception) when (
                    exception is ExternalException or
                    InvalidOperationException)
                {
                    tracker.Reset();
                    SetStatus("Waiting for Remote Audio");

                    var error = $"{exception.GetType().Name}: {exception.Message}";

                    if (!string.Equals(error, lastError, StringComparison.Ordinal))
                    {
                        Log.Error("Unable to apply the Remote Audio base volume.", exception);
                        lastError = error;
                    }
                }

                WakeSignal.WaitOne(PollInterval);
            }
        }
        catch (Exception exception) when (
            exception is ExternalException or
            InvalidOperationException)
        {
            SetStatus("Stopped: Core Audio initialization failed");
            Log.Error("The Core Audio worker stopped because initialization failed.", exception);
        }
        finally
        {
            if (initializeResult >= 0)
            {
                Native.CoUninitialize();
            }

            SetStatus("Stopped");
            Log.Information("Audio watcher stopped.");
        }
    }

    private void Scan(nint deviceEnumerator, AudioSessionTracker tracker)
    {
        if (!RemoteSessionDetector.IsRemoteDesktopSession())
        {
            tracker.Reset();
            SetStatus("Idle: not a Remote Desktop session");

            return;
        }

        using var device = new ComReference(Native.GetDefaultAudioEndpoint(deviceEnumerator));
        var endpointIdentifier = Native.GetDeviceIdentifier(device.Handle);
        var targetVolume = Coordinator.BaseVolumePercent / 100f;
        var generation = Coordinator.Generation;

        using (var endpointVolume = new ComReference(Native.ActivateAudioEndpointVolume(device.Handle)))
        {
            var currentVolume = Native.GetEndpointVolume(endpointVolume.Handle);

            if (Math.Abs(currentVolume - targetVolume) > VolumeComparisonTolerance)
            {
                Native.SetEndpointVolume(endpointVolume.Handle, targetVolume);
            }
        }

        tracker.BeginScan(endpointIdentifier, generation);

        using var sessionManager = new ComReference(Native.ActivateAudioSessionManager(device.Handle));
        using var sessionEnumerator = new ComReference(Native.GetAudioSessionEnumerator(sessionManager.Handle));
        var sessionCount = Native.GetAudioSessionCount(sessionEnumerator.Handle);

        for (var index = 0; index < sessionCount; index++)
        {
            using var session = new ComReference(Native.GetAudioSession(sessionEnumerator.Handle, index));
            using var sessionControl = new ComReference(Native.GetAudioSessionControl2(session.Handle));
            var sessionIdentifier = Native.GetAudioSessionIdentifier(sessionControl.Handle);

            if (!tracker.ShouldApply(sessionIdentifier))
            {
                continue;
            }

            using var sessionVolume = new ComReference(Native.GetSimpleAudioVolume(sessionControl.Handle));
            Native.SetSessionVolume(sessionVolume.Handle, targetVolume);
        }

        tracker.CompleteScan();
        SetStatus($"Watching Remote Audio at {Coordinator.BaseVolumePercent}%");
    }

    private void SetStatus(string status)
    {
        lock (StatusGate)
        {
            if (string.Equals(_status, status, StringComparison.Ordinal))
            {
                return;
            }

            _status = status;
        }

        Log.Information(status);
    }
}