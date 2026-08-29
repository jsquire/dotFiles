namespace __ROOT_NAMESPACE__;

/// <summary>
/// Performs the application's background work.
/// </summary>
public sealed partial class Worker : BackgroundService
{
    private readonly ILogger<Worker> Logger;

    /// <summary>
    /// Initializes a new instance of the <see cref="Worker"/> class.
    /// </summary>
    ///
    /// <param name="logger">The destination for worker status messages.</param>
    public Worker(ILogger<Worker> logger)
    {
        Logger = logger;
    }

    /// <inheritdoc />
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            LogWorkerRunning(Logger);

            await Task.Delay(TimeSpan.FromMinutes(1), stoppingToken);
        }
    }

    [LoggerMessage(Level = LogLevel.Information, Message = "Worker is running.")]
    private static partial void LogWorkerRunning(ILogger logger);
}
