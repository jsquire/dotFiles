using Microsoft.Extensions.Configuration;
using Squire.OllamaHost.Proxy;

namespace Squire.OllamaHost;

/// <summary>
///   The strongly-typed application configuration, loaded from JSON and environment variables.  It
///   drives the proxy and Ollama ports, the Ollama executable location, the WinGet package to update,
///   and logging behavior so that nothing operationally significant is hard-coded.
/// </summary>
///
public class OllamaHostOptions
{
    /// <summary>The default port the proxy listens on.</summary>
    private const int DefaultProxyListenPort = 11435;

    /// <summary>The default port Ollama serves on.</summary>
    private const int DefaultOllamaUpstreamPort = 11434;

    /// <summary>The default ceiling on requests the proxy services concurrently.</summary>
    private const int DefaultProxyMaxConcurrentRequests = 64;

    /// <summary>The default WinGet package identifier used by the "Update Ollama" action.</summary>
    private const string DefaultWinGetPackageId = "Ollama.Ollama";

    /// <summary>
    ///   The loopback port the proxy listens on; every client should target this port.
    /// </summary>
    ///
    public int ProxyListenPort { get; set; } = DefaultProxyListenPort;

    /// <summary>
    ///   The loopback port Ollama serves on and to which the proxy forwards.  The supervisor also
    ///   serves Ollama on this port via <c>OLLAMA_HOST</c>.
    /// </summary>
    ///
    public int OllamaUpstreamPort { get; set; } = DefaultOllamaUpstreamPort;

    /// <summary>
    ///   The maximum number of requests the proxy services concurrently before it applies backpressure at
    ///   the accept loop.
    /// </summary>
    ///
    /// <value>Defaults to <c>64</c>.</value>
    ///
    public int ProxyMaxConcurrentRequests { get; set; } = DefaultProxyMaxConcurrentRequests;

    /// <summary>
    ///   An explicit path to <c>ollama.exe</c>.  When <c>null</c>, the supervisor resolves it from the
    ///   default install location or the <c>PATH</c>.
    /// </summary>
    ///
    public string? OllamaExecutablePath { get; set; }

    /// <summary>
    ///   The WinGet package identifier upgraded by the tray's "Update Ollama" action.
    /// </summary>
    ///
    /// <value>Defaults to <c>Ollama.Ollama</c>.</value>
    ///
    public string OllamaWinGetPackageId { get; set; } = DefaultWinGetPackageId;

    /// <summary>
    ///   The logging configuration (sink selection, file path, and roll size).
    /// </summary>
    ///
    public LoggingOptions Logging { get; set; } = new();

    /// <summary>
    ///   Projects the subset of options relevant to the reverse proxy.
    /// </summary>
    ///
    /// <returns>A <see cref="ProxyOptions"/> populated from this instance.</returns>
    ///
    public ProxyOptions ToProxyOptions() => new()
    {
        ListenPort = ProxyListenPort,
        UpstreamPort = OllamaUpstreamPort,
        MaxConcurrentRequests = ProxyMaxConcurrentRequests
    };

    /// <summary>
    ///   Loads the options from the supplied configuration, applying defaults for any absent keys.
    /// </summary>
    ///
    /// <param name="configuration">The composed application configuration.</param>
    ///
    /// <returns>A fully populated <see cref="OllamaHostOptions"/> instance.</returns>
    ///
    /// <exception cref="ArgumentNullException">Occurs when <paramref name="configuration"/> is <c>null</c>.</exception>
    ///
    public static OllamaHostOptions FromConfiguration(IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration, nameof(configuration));

        var executablePath = configuration["Ollama:ExecutablePath"];
        var packageId = configuration["Ollama:WinGetPackageId"];

        return new OllamaHostOptions
        {
            ProxyListenPort = int.TryParse(configuration["Proxy:ListenPort"], out var listenPort) ? listenPort : DefaultProxyListenPort,
            ProxyMaxConcurrentRequests = (int.TryParse(configuration["Proxy:MaxConcurrentRequests"], out var maxConcurrent) && (maxConcurrent > 0)) ? maxConcurrent : DefaultProxyMaxConcurrentRequests,
            OllamaUpstreamPort = int.TryParse(configuration["Ollama:UpstreamPort"], out var upstreamPort) ? upstreamPort : DefaultOllamaUpstreamPort,
            OllamaExecutablePath = string.IsNullOrWhiteSpace(executablePath) ? null : executablePath,
            OllamaWinGetPackageId = string.IsNullOrWhiteSpace(packageId) ? DefaultWinGetPackageId : packageId,
            Logging = LoggingOptions.FromConfiguration(configuration.GetSection("Logging"))
        };
    }
}
