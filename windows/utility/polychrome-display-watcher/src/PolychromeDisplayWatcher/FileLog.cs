using System.Globalization;

namespace Squire.PolychromeDisplayWatcher;

/// <summary>
/// Writes bounded diagnostic output to a local file.
/// </summary>
internal sealed class FileLog
{
    private const long MaximumLogLength = 1024 * 1024;

    private readonly Lock Gate = new();
    private readonly string LogPath;

    /// <summary>
    /// Gets the destination log file path.
    /// </summary>
    public string FullPath => LogPath;

    /// <summary>
    /// Initializes a new instance of the <see cref="FileLog"/> class.
    /// </summary>
    ///
    /// <param name="logPath">The destination log file.</param>
    ///
    public FileLog(string logPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(logPath);

        LogPath = logPath;
    }

    /// <summary>
    /// Writes an informational event.
    /// </summary>
    ///
    /// <param name="message">The event detail.</param>
    ///
    public void Information(string message) => Write("INF", message);

    /// <summary>
    /// Writes an error event.
    /// </summary>
    ///
    /// <param name="message">The error detail.</param>
    /// <param name="exception">The exception associated with the error.</param>
    ///
    public void Error(string message, Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);

        Write("ERR", string.Create(
            CultureInfo.InvariantCulture,
            $"{message} {exception.GetType().Name}: {exception.Message}"));
    }

    private void Write(string level, string message)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(message);

        lock (Gate)
        {
            var directory = Path.GetDirectoryName(LogPath);

            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            RollIfNeeded();

            var line = string.Create(
                CultureInfo.InvariantCulture,
                $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff zzz} [{level}] {message}{Environment.NewLine}");

            File.AppendAllText(LogPath, line);
        }
    }

    private void RollIfNeeded()
    {
        var file = new FileInfo(LogPath);

        if (!file.Exists || (file.Length < MaximumLogLength))
        {
            return;
        }

        var archivePath = $"{LogPath}.1";
        File.Move(LogPath, archivePath, overwrite: true);
    }
}
