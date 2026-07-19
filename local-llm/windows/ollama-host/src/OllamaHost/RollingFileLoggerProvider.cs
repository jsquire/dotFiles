using System.Collections.Concurrent;
using System.Text;
using Microsoft.Extensions.Logging;

namespace Squire.OllamaHost;

/// <summary>
///   An <see cref="ILoggerProvider"/> that writes to a single active log file and rolls it to a
///   timestamped archive once it reaches the configured size (1 MB by default), retaining a bounded
///   number of archives.  Entries are enqueued and a single background task performs the file writes, so
///   the heavy I/O stays off the caller's critical path.  This is the file sink for
///   <c>Microsoft.Extensions.Logging</c>, which ships no first-party file provider.
/// </summary>
///
public sealed class RollingFileLoggerProvider : ILoggerProvider
{
    /// <summary>The rolling-file configuration (path, roll size, retention).</summary>
    private readonly LoggingOptions Options;

    /// <summary>The buffer of formatted entries awaiting the background writer.</summary>
    private readonly BlockingCollection<string> Queue = new();

    /// <summary>The background task that drains <see cref="Queue"/> and writes to the file.</summary>
    private readonly Task Writer;

    /// <summary>The running size of the active log file in bytes, maintained by the writer to avoid a per-batch file stat.</summary>
    private long _currentFileBytes;

    /// <summary>
    ///   Initializes a new instance of the <see cref="RollingFileLoggerProvider"/> class, ensures the
    ///   target directory exists, and starts the background writer.
    /// </summary>
    ///
    /// <param name="options">The rolling-file configuration (path, roll size, retention).</param>
    ///
    /// <exception cref="ArgumentNullException">Occurs when <paramref name="options"/> is <c>null</c>.</exception>
    ///
    public RollingFileLoggerProvider(LoggingOptions options)
    {
        ArgumentNullException.ThrowIfNull(options, nameof(options));

        Options = options;

        var directory = Path.GetDirectoryName(options.FilePath);

        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var existing = new FileInfo(options.FilePath);
        _currentFileBytes = existing.Exists ? existing.Length : 0;

        Writer = Task.Run(DrainQueue);
    }

    /// <summary>
    ///   The minimum level below which entries are discarded.
    /// </summary>
    ///
    internal LogLevel MinimumLevel => Options.MinimumLevel;

    /// <summary>
    ///   Creates a logger for the specified category.
    /// </summary>
    ///
    /// <param name="categoryName">The category name for entries produced by the logger.</param>
    ///
    /// <returns>A logger that writes through this provider.</returns>
    ///
    public ILogger CreateLogger(string categoryName) => new RollingFileLogger(this, categoryName);

    /// <summary>
    ///   Stops accepting entries, flushes those already queued, and releases the buffer.
    /// </summary>
    ///
    public void Dispose()
    {
        Queue.CompleteAdding();

        try
        {
            Writer.Wait(TimeSpan.FromSeconds(5));
        }
        catch (AggregateException)
        {
            // The writer faulted; nothing further can be flushed.
        }

        // The writer is given a bounded time to flush; if a large backlog outlasts it, disposing the queue
        // here can surface an ObjectDisposedException on the still-draining writer task.  That is accepted:
        // it occurs only at shutdown, the exception is unobserved and harmless, and exit must not block.

        Queue.Dispose();
    }

    /// <summary>
    ///   Formats an entry (capturing the timestamp now) and enqueues it for the background writer.
    /// </summary>
    ///
    /// <param name="categoryName">The logger category that produced the entry.</param>
    /// <param name="logLevel">The severity of the entry.</param>
    /// <param name="message">The already-formatted message text.</param>
    ///
    internal void Enqueue(string categoryName,
                          LogLevel logLevel,
                          string message)
    {
        var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff} [{Abbreviate(logLevel)}] {categoryName}: {message}";

        try
        {
            Queue.Add(line);
        }
        catch (InvalidOperationException)
        {
            // The provider is disposing and no longer accepts entries.
        }
    }

    /// <summary>
    ///   Drains the queue on a background thread, writing batched entries to the active file and rolling
    ///   it when it reaches the configured size.
    /// </summary>
    ///
    private void DrainQueue()
    {
        foreach (var line in Queue.GetConsumingEnumerable())
        {
            var builder = new StringBuilder(line).Append(Environment.NewLine);

            // Drain any entries already waiting so a burst becomes a single file write.

            while (Queue.TryTake(out var next))
            {
                builder.Append(next).Append(Environment.NewLine);
            }

            var text = builder.ToString();
            var pending = Encoding.UTF8.GetByteCount(text);

            RollIfNeeded(pending);

            try
            {
                File.AppendAllText(Options.FilePath, text);
                _currentFileBytes += pending;
            }
            catch (IOException)
            {
                // Logging must never take down the application.
            }
        }
    }

    /// <summary>
    ///   Rolls the active log file to a timestamped archive when the pending write would push it past the
    ///   configured size, tracked by an in-process byte count seeded at startup rather than a per-batch stat.
    /// </summary>
    ///
    /// <param name="pendingBytes">The number of bytes about to be appended.</param>
    ///
    private void RollIfNeeded(long pendingBytes)
    {
        if ((_currentFileBytes == 0) || ((_currentFileBytes + pendingBytes) <= Options.RollSizeBytes))
        {
            return;
        }

        try
        {
            var archive = $"{Options.FilePath}.{DateTime.Now:yyyyMMdd-HHmmss}";

            File.Move(Options.FilePath, archive, overwrite: true);
            PruneArchives();

            _currentFileBytes = 0;
        }
        catch (IOException)
        {
            // A failed roll is non-fatal; keep appending to the current file.
        }
    }

    /// <summary>
    ///   Deletes the oldest archives beyond the configured retention limit.
    /// </summary>
    ///
    private void PruneArchives()
    {
        var directory = Path.GetDirectoryName(Options.FilePath);

        if (string.IsNullOrEmpty(directory))
        {
            return;
        }

        var prefix = Path.GetFileName(Options.FilePath) + ".";

        var archives = new DirectoryInfo(directory)
            .GetFiles(prefix + "*")
            .OrderByDescending(file => file.LastWriteTimeUtc)
            .Skip(Options.RetainedFileCountLimit);

        foreach (var archive in archives)
        {
            try
            {
                archive.Delete();
            }
            catch (IOException)
            {
                // Best effort; a locked archive is left in place.
            }
        }
    }

    /// <summary>
    ///   Produces a fixed-width abbreviation for a log level.
    /// </summary>
    ///
    /// <param name="logLevel">The level to abbreviate.</param>
    ///
    /// <returns>A five-character abbreviation.</returns>
    ///
    private static string Abbreviate(LogLevel logLevel) => logLevel switch
    {
        LogLevel.Trace => "TRACE",
        LogLevel.Debug => "DEBUG",
        LogLevel.Information => "INFO",
        LogLevel.Warning => "WARN",
        LogLevel.Error => "ERROR",
        LogLevel.Critical => "CRIT",
        _ => "?????"
    };
}
