using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace Squire.OllamaHost;

/// <summary>
///   The logging configuration:  sink selection, minimum level, and rolling-file behavior.
/// </summary>
///
public class LoggingOptions
{
    /// <summary>The size, in bytes, at which the active log file is rolled by default (1 MB).</summary>
    private const long DefaultRollSizeBytes = 1024 * 1024;

    /// <summary>The default number of rolled archive files to retain.</summary>
    private const int DefaultRetainedFileCountLimit = 2;

    /// <summary>
    ///   Where log output is written.
    /// </summary>
    ///
    /// <value>Defaults to <see cref="LogSink.File"/>.</value>
    ///
    public LogSink Sink { get; set; } = LogSink.File;

    /// <summary>
    ///   The minimum level that is emitted.
    /// </summary>
    ///
    /// <value>Defaults to <see cref="LogLevel.Information"/>.</value>
    ///
    public LogLevel MinimumLevel { get; set; } = LogLevel.Information;

    /// <summary>
    ///   The active log file path when <see cref="Sink"/> is <see cref="LogSink.File"/>.
    /// </summary>
    ///
    public string FilePath
    {
        get => field ??= DefaultFilePath();
        set => field = value is { Length: > 0 } ? value : DefaultFilePath();
    }

    /// <summary>
    ///   The size, in bytes, at which the active log file is rolled to an archive.
    /// </summary>
    ///
    /// <value>Defaults to 1 MB.</value>
    ///
    public long RollSizeBytes { get; set; } = DefaultRollSizeBytes;

    /// <summary>
    ///   The maximum number of rolled archive files to retain; older archives are pruned.
    /// </summary>
    ///
    public int RetainedFileCountLimit { get; set; } = DefaultRetainedFileCountLimit;

    /// <summary>
    ///   Computes the default log file path under the user's local application data.
    /// </summary>
    ///
    /// <returns>The default fully-qualified log file path.</returns>
    ///
    public static string DefaultFilePath() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ollama-host", "logs", "ollama-host.log");

    /// <summary>
    ///   Builds the logging options from the supplied configuration section, applying defaults for any
    ///   absent keys.
    /// </summary>
    ///
    /// <param name="section">The <c>Logging</c> configuration section.</param>
    ///
    /// <returns>A fully populated <see cref="LoggingOptions"/> instance.</returns>
    ///
    /// <exception cref="ArgumentNullException">Occurs when <paramref name="section"/> is <c>null</c>.</exception>
    ///
    public static LoggingOptions FromConfiguration(IConfiguration section)
    {
        ArgumentNullException.ThrowIfNull(section, nameof(section));

        var path = section["File:Path"];

        return new LoggingOptions
        {
            Sink = Enum.TryParse<LogSink>(section["Sink"], ignoreCase: true, out var sink) ? sink : LogSink.File,
            MinimumLevel = Enum.TryParse<LogLevel>(section["MinimumLevel"], ignoreCase: true, out var level) ? level : LogLevel.Information,
            FilePath = string.IsNullOrWhiteSpace(path) ? DefaultFilePath() : path,
            RollSizeBytes = ((long.TryParse(section["File:RollSizeBytes"], out var size)) && (size > 0)) ? size : DefaultRollSizeBytes,
            RetainedFileCountLimit = int.TryParse(section["File:RetainedFileCountLimit"], out var retained) ? retained : DefaultRetainedFileCountLimit
        };
    }
}
