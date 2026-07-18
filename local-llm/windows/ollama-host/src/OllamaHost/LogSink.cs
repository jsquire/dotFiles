namespace Squire.OllamaHost;

/// <summary>
///   Selects where log output is written.
/// </summary>
///
public enum LogSink
{
    /// <summary>A rolling file; the default for a windowless tray app.</summary>
    File,

    /// <summary>The process console; useful when launched from a terminal.</summary>
    Console
}
