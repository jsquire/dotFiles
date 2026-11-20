namespace Squire.RemoteAudioVolumeWatcher;

/// <summary>
/// Owns one reference to a native COM interface.
/// </summary>
internal sealed class ComReference : IDisposable
{
    private nint _handle;

    /// <summary>
    /// Gets the native interface pointer.
    /// </summary>
    public nint Handle => _handle;

    /// <summary>
    /// Initializes a new instance of the <see cref="ComReference"/> class.
    /// </summary>
    ///
    /// <param name="handle">The owned interface pointer.</param>
    ///
    public ComReference(nint handle)
    {
        if (handle == nint.Zero)
        {
            throw new ArgumentException("A COM interface pointer is required.", nameof(handle));
        }

        _handle = handle;
    }

    /// <inheritdoc />
    public void Dispose()
    {
        var handle = Interlocked.Exchange(ref _handle, nint.Zero);

        if (handle != nint.Zero)
        {
            Native.Release(handle);
        }
    }
}