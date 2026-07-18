using Microsoft.Extensions.Logging;

namespace Squire.OllamaHost;

/// <summary>
///   The <see cref="ILogger"/> returned by <see cref="RollingFileLoggerProvider"/>; it formats entries
///   and forwards them to the provider, which buffers and writes them on a background thread.
/// </summary>
///
internal sealed class RollingFileLogger : ILogger
{
    /// <summary>The owning provider that buffers and writes entries.</summary>
    private readonly RollingFileLoggerProvider Provider;

    /// <summary>The category name for entries from this logger.</summary>
    private readonly string CategoryName;

    /// <summary>
    ///   Initializes a new instance of the <see cref="RollingFileLogger"/> class.
    /// </summary>
    ///
    /// <param name="provider">The owning provider that buffers and writes entries.</param>
    /// <param name="categoryName">The category name for entries from this logger.</param>
    ///
    public RollingFileLogger(RollingFileLoggerProvider provider,
                             string categoryName)
    {
        Provider = provider;
        CategoryName = categoryName;
    }

    /// <summary>
    ///   Begins a logical scope.  Scopes are not tracked by this logger.
    /// </summary>
    ///
    /// <typeparam name="TState">The type of the scope state.</typeparam>
    /// <param name="state">The scope state.</param>
    ///
    /// <returns>A no-op scope.</returns>
    ///
    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => NullScope.Instance;

    /// <summary>
    ///   Determines whether entries at the specified level are emitted.
    /// </summary>
    ///
    /// <param name="logLevel">The level to test.</param>
    ///
    /// <returns><c>true</c> when the level is enabled; otherwise, <c>false</c>.</returns>
    ///
    public bool IsEnabled(LogLevel logLevel) => (logLevel >= Provider.MinimumLevel) && (logLevel != LogLevel.None);

    /// <summary>
    ///   Formats an entry and forwards it to the provider for buffered writing.
    /// </summary>
    ///
    /// <typeparam name="TState">The type of the entry state.</typeparam>
    /// <param name="logLevel">The severity of the entry.</param>
    /// <param name="eventId">The event identifier.</param>
    /// <param name="state">The entry state.</param>
    /// <param name="exception">The exception associated with the entry, if any.</param>
    /// <param name="formatter">The function that formats the state and exception into a message.</param>
    ///
    /// <exception cref="ArgumentNullException">Occurs when <paramref name="formatter"/> is <c>null</c>.</exception>
    ///
    public void Log<TState>(LogLevel logLevel,
                            EventId eventId,
                            TState state,
                            Exception? exception,
                            Func<TState, Exception?, string> formatter)
    {
        if (!IsEnabled(logLevel))
        {
            return;
        }

        ArgumentNullException.ThrowIfNull(formatter, nameof(formatter));

        var message = formatter(state, exception);

        if (exception is not null)
        {
            message = $"{message} | {exception}";
        }

        Provider.Enqueue(CategoryName, logLevel, message);
    }

    /// <summary>
    ///   A scope that does nothing, returned by <see cref="BeginScope"/>.
    /// </summary>
    ///
    private sealed class NullScope : IDisposable
    {
        /// <summary>The shared, stateless instance.</summary>
        public static readonly NullScope Instance = new();

        /// <summary>
        ///   Prevents external construction.
        /// </summary>
        ///
        private NullScope()
        {
        }

        /// <summary>
        ///   Does nothing.
        /// </summary>
        ///
        public void Dispose()
        {
        }
    }
}
