using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;

namespace Squire.OllamaHost;

/// <summary>
///   Wraps a Windows job object configured with <c>KILL_ON_JOB_CLOSE</c>.  Any process assigned to it
///   is terminated automatically when this object's handle closes, so a crash of the supervisor can
///   never orphan Ollama and leave it holding the GPU.  Because it owns an unmanaged handle it
///   implements the full dispose pattern, including a finalizer as a safety net.
/// </summary>
///
internal sealed unsafe class JobObject : IDisposable
{
    /// <summary>The logger used to report a failed handle close.</summary>
    private readonly ILogger Logger;

    /// <summary>The native job-object handle, or <see cref="IntPtr.Zero"/> once released.</summary>
    private IntPtr _handle;

    /// <summary>
    ///   Initializes a new instance of the <see cref="JobObject"/> class and applies the
    ///   kill-on-close limit.
    /// </summary>
    ///
    /// <param name="logger">The logger used to report a failed handle close.</param>
    ///
    /// <exception cref="ArgumentNullException">Occurs when <paramref name="logger"/> is <c>null</c>.</exception>
    ///
    public JobObject(ILogger logger)
    {
        ArgumentNullException.ThrowIfNull(logger, nameof(logger));

        Logger = logger;
        _handle = Native.CreateJobObjectW(IntPtr.Zero, null);

        if (_handle == IntPtr.Zero)
        {
            return;
        }

        var info = default(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        info.BasicLimitInformation.LimitFlags = Native.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

        Native.SetInformationJobObject(_handle, Native.JobObjectExtendedLimitInformation, &info, (uint)sizeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
    }

    /// <summary>
    ///   Finalizes the instance, releasing the native handle if <see cref="Dispose()"/> was not called.
    /// </summary>
    ///
    ~JobObject() => ReleaseHandle(disposing: false);

    /// <summary>
    ///   Assigns a process to the job so its lifetime is bound to this object.
    /// </summary>
    ///
    /// <param name="processHandle">The native handle of the process to assign.</param>
    ///
    /// <returns><c>true</c> when the assignment succeeded; otherwise, <c>false</c>.</returns>
    ///
    public bool Assign(IntPtr processHandle) => (_handle != IntPtr.Zero) && (Native.AssignProcessToJobObject(_handle, processHandle));

    /// <summary>
    ///   Releases the native handle (terminating any still-assigned process) and suppresses
    ///   finalization.
    /// </summary>
    ///
    public void Dispose()
    {
        ReleaseHandle(disposing: true);
        GC.SuppressFinalize(this);
    }

    /// <summary>
    ///   Closes the job-object handle.  The close is idempotent and safe under a race:  a double close
    ///   is prevented rather than caught, because closing an already-closed handle can corrupt an
    ///   unrelated handle.  The logger is touched only on the dispose path, since during finalization it
    ///   may already have been collected.
    /// </summary>
    ///
    /// <param name="disposing"><c>true</c> when called from <see cref="Dispose()"/>; <c>false</c> from the finalizer.</param>
    ///
    private void ReleaseHandle(bool disposing)
    {
        // Atomically take ownership of the handle so a concurrent release cannot close it twice.

        var handle = Interlocked.Exchange(ref _handle, IntPtr.Zero);

        if (handle == IntPtr.Zero)
        {
            return;
        }

        if ((!Native.CloseHandle(handle)) && disposing)
        {
            Logger.LogWarning("Failed to close the job object handle (error {ErrorCode}).", Marshal.GetLastPInvokeError());
        }
    }
}
