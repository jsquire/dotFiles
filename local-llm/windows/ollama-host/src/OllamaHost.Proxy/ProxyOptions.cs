namespace Squire.OllamaHost.Proxy;

/// <summary>
///   The network configuration for the <see cref="ReverseProxy"/>:  the local port it listens on, the
///   Ollama port it forwards to, and how many requests it services at once.  The defaults match a
///   standard local Ollama installation.
/// </summary>
///
public class ProxyOptions
{
    /// <summary>
    ///   The loopback port the proxy listens on.  Clients target this port instead of Ollama's, so
    ///   their <c>content: null</c> turns are sanitized in transit.
    /// </summary>
    ///
    /// <value>Defaults to <c>11435</c>.</value>
    ///
    public int ListenPort { get; set; } = 11435;

    /// <summary>
    ///   The loopback port that Ollama serves on and to which every request is forwarded.
    /// </summary>
    ///
    /// <value>Defaults to <c>11434</c>.</value>
    ///
    public int UpstreamPort { get; set; } = 11434;

    /// <summary>
    ///   The maximum number of requests handled concurrently.  Once every slot is in use the accept loop
    ///   stops pulling new connections, letting them queue at the socket rather than pile up in memory.
    /// </summary>
    ///
    /// <value>Defaults to <c>64</c>.</value>
    ///
    public int MaxConcurrentRequests { get; set; } = 64;
}
