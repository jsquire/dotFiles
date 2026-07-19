using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Squire.OllamaHost.Proxy;

namespace Squire.OllamaHost;

/// <summary>
///   The application entry point and composition root.  It loads configuration, builds logging, wires
///   the proxy, supervisor, and tray together with their lifetime rules, and runs the tray message loop.
/// </summary>
///
internal static class Program
{
    /// <summary>The mutex name used to enforce a single running instance.</summary>
    private const string SingleInstanceMutexName = "OllamaHostSingleInstance";

    /// <summary>The prefix for environment variables that override configuration.</summary>
    private const string EnvironmentVariablePrefix = "OLLAMAHOST_";

    /// <summary>
    ///   Runs the application.
    /// </summary>
    ///
    /// <param name="args">The command-line arguments; <c>--version</c> prints the version and exits.</param>
    ///
    /// <returns>The process exit code.</returns>
    ///
    private static int Main(string[] args)
    {
        if ((args.Length > 0) && ((args[0] == "--version") || (args[0] == "-v")))
        {
            var version = typeof(Program).Assembly.GetName().Version;

            Console.WriteLine($"ollama-host {version?.ToString(3) ?? "unknown"}");
            return 0;
        }

        using var mutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out var created);

        if (!created)
        {
            // Another instance already owns the tray.

            return 0;
        }

        var options = OllamaHostOptions.FromConfiguration(BuildConfiguration());

        using var loggerFactory = BuildLoggerFactory(options);

        var logger = loggerFactory.CreateLogger("Squire.OllamaHost");
        logger.LogInformation("ollama-host starting.");

        using var supervisor = new OllamaSupervisor(options, loggerFactory.CreateLogger<OllamaSupervisor>());
        using var proxy = new ReverseProxy(options.ToProxyOptions(), loggerFactory.CreateLogger<ReverseProxy>());

        var tray = new NativeTrayIcon(loggerFactory.CreateLogger<NativeTrayIcon>(), OllamaExecutable.FindIconPath(options.OllamaExecutablePath));

        WireLifetime(tray, supervisor, proxy, logger);
        supervisor.Start();

        try
        {
            proxy.Start();
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "The proxy failed to start.");
        }

        tray.SetStatus(supervisor.IsRunning ? "running" : "stopped");
        tray.StartupBalloon = ("Ollama Host", $"Ollama + proxy running (clients use :{options.ProxyListenPort}).");

        tray.Run();

        logger.LogInformation("ollama-host exited.");
        return 0;
    }

    /// <summary>
    ///   Builds the application configuration from the optional JSON file and environment variables.
    /// </summary>
    ///
    /// <returns>The composed configuration.</returns>
    ///
    private static IConfiguration BuildConfiguration() =>
        new ConfigurationBuilder()
            .SetBasePath(AppContext.BaseDirectory)
            .AddJsonFile("appsettings.json", optional: true, reloadOnChange: false)
            .AddEnvironmentVariables(EnvironmentVariablePrefix)
            .Build();

    /// <summary>
    ///   Builds the logger factory for the configured sink (console or rolling file).
    /// </summary>
    ///
    /// <param name="options">The application options describing logging behavior.</param>
    ///
    /// <returns>A configured logger factory.</returns>
    ///
    private static ILoggerFactory BuildLoggerFactory(OllamaHostOptions options) =>
        LoggerFactory.Create(builder =>
        {
            builder.SetMinimumLevel(options.Logging.MinimumLevel);

            if (options.Logging.Sink == LogSink.Console)
            {
                builder.AddConsole();
            }
            else
            {
                builder.AddProvider(new RollingFileLoggerProvider(options.Logging));
            }
        });

    /// <summary>
    ///   Wires the tray, supervisor, and proxy together so their lifetimes stay matched and failures
    ///   prompt the user to restart.
    /// </summary>
    ///
    /// <param name="tray">The tray presence that raises menu and signal events.</param>
    /// <param name="supervisor">The Ollama supervisor.</param>
    /// <param name="proxy">The reverse proxy.</param>
    /// <param name="logger">The composition-root logger.</param>
    ///
    private static void WireLifetime(NativeTrayIcon tray,
                                     OllamaSupervisor supervisor,
                                     ReverseProxy proxy,
                                     ILogger logger)
    {
        supervisor.Exited += tray.SignalOllamaExited;
        proxy.Faulted += _ => tray.SignalProxyFault();

        tray.OllamaExitedSignaled += () =>
        {
            tray.SetStatus("Ollama stopped");

            if (tray.PromptYesNo("Ollama Host", "Ollama stopped unexpectedly.\n\nRestart it?"))
            {
                supervisor.Start();
                tray.SetStatus(supervisor.IsRunning ? "running" : "stopped");
                tray.NotifyAsync("Ollama Host", supervisor.IsRunning ? "Ollama restarted." : "Ollama failed to restart (see log).");
            }
            else
            {
                tray.NotifyAsync("Ollama Host", "Ollama left stopped. The proxy will return 502 until it is restarted.");
            }
        };

        tray.ProxyFaultSignaled += () =>
        {
            if (tray.PromptYesNo("Ollama Host", "The local proxy stopped.\n\nRestart it?"))
            {
                proxy.Stop();
                proxy.Start();
                tray.NotifyAsync("Ollama Host", "Proxy restarted.");
            }
        };

        tray.RestartOllamaRequested += () =>
        {
            supervisor.Restart();
            tray.SetStatus(supervisor.IsRunning ? "running" : "stopped");
            tray.NotifyAsync("Ollama Host", "Ollama restarted.");
        };

        tray.RestartProxyRequested += () =>
        {
            proxy.Stop();
            proxy.Start();
            tray.NotifyAsync("Ollama Host", "Proxy restarted.");
        };

        tray.UpdateOllamaRequested += () => Task.Run(() =>
        {
            var result = supervisor.Update();
            tray.SetStatus(supervisor.IsRunning ? "running" : "stopped");
            tray.NotifyAsync("Ollama Host", result);
        });

        tray.ExitRequested += () =>
        {
            logger.LogInformation("Exit requested; tearing down proxy and ollama.");
            proxy.Dispose();
            supervisor.Dispose();
            tray.Quit();
        };
    }
}
