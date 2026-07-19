using System.Buffers;
using System.Net;
using Microsoft.Extensions.Logging;

namespace Squire.OllamaHost.Proxy;

/// <summary>
///   A minimal, dependency-free reverse proxy:  it listens on <c>127.0.0.1:{ListenPort}</c> and
///   forwards every request to Ollama on <c>127.0.0.1:{UpstreamPort}</c>, rewriting <c>content: null</c>
///   on chat requests (see <see cref="Sanitizer"/>).  Responses stream through unchanged (SSE or JSON).
///   If Ollama is unreachable the proxy returns <c>502</c> rather than dropping the connection.
/// </summary>
///
public sealed class ReverseProxy : IDisposable
{
    /// <summary>The size of the transient buffer rented for streaming each response.</summary>
    private const int RelayBufferSize = 64 * 1024;

    /// <summary>The body returned when Ollama cannot be reached.</summary>
    private static readonly byte[] UpstreamUnavailableBody = """{"error":{"message":"ollama upstream unavailable","type":"upstream_error"}}"""u8.ToArray();

    /// <summary>The listen and upstream port configuration.</summary>
    private readonly ProxyOptions Options;

    /// <summary>The logger used to report faults and upstream failures.</summary>
    private readonly ILogger<ReverseProxy> Logger;

    /// <summary>The client used to forward requests to Ollama, with a pooled, never-timing-out connection.</summary>
    private readonly HttpClient Http;

    /// <summary>The base address of the Ollama upstream, pre-computed from the configured port.</summary>
    private readonly string UpstreamBase;

    /// <summary>Serializes <see cref="Start"/> and <see cref="Stop"/> so lifecycle transitions cannot interleave.</summary>
    private readonly object SyncRoot = new();

    /// <summary>The active HTTP listener, or <c>null</c> while stopped.</summary>
    private HttpListener? _listener;

    /// <summary>The token source used to stop the accept loop, or <c>null</c> while stopped.</summary>
    private CancellationTokenSource? _cancellation;

    /// <summary>Bounds the number of in-flight request handlers, or <c>null</c> while stopped.</summary>
    private SemaphoreSlim? _concurrency;

    /// <summary>
    ///   Raised when the accept loop terminates unexpectedly while the proxy is running.
    /// </summary>
    ///
    public event Action<Exception>? Faulted;

    /// <summary>
    ///   The loopback port the proxy is configured to listen on.
    /// </summary>
    ///
    public int ListenPort => Options.ListenPort;

    /// <summary>
    ///   Initializes a new instance of the <see cref="ReverseProxy"/> class.
    /// </summary>
    ///
    /// <param name="options">The listen and upstream port configuration.</param>
    /// <param name="logger">The logger used to report faults and upstream failures.</param>
    ///
    /// <exception cref="ArgumentNullException">Occurs when <paramref name="options"/> or <paramref name="logger"/> is <c>null</c>.</exception>
    ///
    public ReverseProxy(ProxyOptions options,
                        ILogger<ReverseProxy> logger)
    {
        ArgumentNullException.ThrowIfNull(options, nameof(options));
        ArgumentNullException.ThrowIfNull(logger, nameof(logger));
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(options.MaxConcurrentRequests, nameof(options.MaxConcurrentRequests));

        Options = options;
        Logger = logger;
        UpstreamBase = $"http://127.0.0.1:{options.UpstreamPort}";
        Http = new HttpClient(new SocketsHttpHandler { PooledConnectionLifetime = TimeSpan.FromMinutes(5) }) { Timeout = Timeout.InfiniteTimeSpan };
    }

    /// <summary>
    ///   Binds the listening socket and begins accepting requests on a background loop.
    /// </summary>
    ///
    public void Start()
    {
        if (_listener is not null)
        {
            return;
        }

        lock (SyncRoot)
        {
            if (_listener is not null)
            {
                return;
            }

            var listener = new HttpListener();
            listener.Prefixes.Add($"http://127.0.0.1:{Options.ListenPort}/");
            listener.Start();

            var cancellation = new CancellationTokenSource();
            var concurrency = new SemaphoreSlim(Options.MaxConcurrentRequests, Options.MaxConcurrentRequests);

            _cancellation = cancellation;
            _concurrency = concurrency;
            _listener = listener;

            Logger.LogInformation("Proxy listening on :{ListenPort} -> :{UpstreamPort}.", Options.ListenPort, Options.UpstreamPort);

            _ = Task.Run(() => AcceptLoopAsync(listener, concurrency, cancellation.Token));
        }
    }

    /// <summary>
    ///   Stops accepting requests and releases the listening socket.
    /// </summary>
    ///
    public void Stop()
    {
        lock (SyncRoot)
        {
            try
            {
                _cancellation?.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // Already torn down; nothing to cancel.
            }

            try
            {
                _listener?.Stop();
                _listener?.Close();
            }
            catch (ObjectDisposedException)
            {
                // Already closed.
            }

            _listener = null;
        }
    }

    /// <summary>
    ///   Stops the proxy and disposes the underlying HTTP client.
    /// </summary>
    ///
    public void Dispose()
    {
        Stop();
        Http.Dispose();
    }

    /// <summary>
    ///   Accepts incoming connections until cancellation, dispatching each to <see cref="SafeHandleAsync"/>.
    /// </summary>
    ///
    /// <param name="listener">The bound listener to accept from.</param>
    /// <param name="concurrency">Limits the in-flight handlers; a slot is taken before accepting and released when the handler completes.</param>
    /// <param name="cancellationToken">A token that can be used to signal a request for cancellation.</param>
    ///
    private async Task AcceptLoopAsync(HttpListener listener,
                                       SemaphoreSlim concurrency,
                                       CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                // Reserve a slot before accepting so, once we are saturated, excess connections wait in the
                // socket's accept queue instead of materializing as work we cannot yet service.

                await concurrency.WaitAsync(cancellationToken).ConfigureAwait(false);
                var context = await listener.GetContextAsync().ConfigureAwait(false);

                _ = Task.Run(async () =>
                {
                    try
                    {
                        await SafeHandleAsync(context).ConfigureAwait(false);
                    }
                    finally
                    {
                        concurrency.Release();
                    }
                });
            }
        }
        catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
        {
            Logger.LogError(ex, "Proxy accept loop faulted.");
            Faulted?.Invoke(ex);
        }
        catch
        {
            // Cancellation during shutdown is expected.
        }
    }

    /// <summary>
    ///   Handles a single request: reads and (for chat requests) sanitizes the body, forwards it to
    ///   Ollama, and streams the response back.
    /// </summary>
    ///
    /// <param name="context">The listener context for the request to handle.</param>
    ///
    /// <remarks>
    ///  This method is "safe" in that it catches all exceptions and logs them; no exception leaks to callers.
    /// </remarks>
    ///
    private async Task SafeHandleAsync(HttpListenerContext context)
    {
        byte[]? rentedBody = null;

        try
        {
            var request = context.Request;
            var method = request.HttpMethod;
            var path = request.Url!.AbsolutePath;
            var contentLength = 0;

            if (request.HasEntityBody)
            {
                (rentedBody, contentLength) = await ReadRequestBodyAsync(request).ConfigureAwait(false);
            }

            if ((rentedBody is not null) && (contentLength > 0) && (Sanitizer.IsChatPath(method, path)))
            {
                contentLength = Sanitizer.SanitizeChatBody(rentedBody.AsSpan(0, contentLength));
            }

            using var forwarded = BuildForwardRequest(request, method, rentedBody, contentLength);
            HttpResponseMessage upstream;

            try
            {
                // ResponseHeadersRead keeps the body unbuffered so ReadAsStreamAsync yields Ollama's live
                // stream; the default (ResponseContentRead) would buffer the whole response first, breaking
                // SSE streaming and hanging on long generations.

                upstream = await Http.SendAsync(forwarded, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                // Ollama is down or refused the connection; fail open with a clear 502.

                Logger.LogWarning(ex, "Ollama upstream unavailable; returning 502.");
                await WriteUpstreamUnavailableAsync(context).ConfigureAwait(false);
                return;
            }

            using (upstream)
            {
                await RelayResponseAsync(context, upstream).ConfigureAwait(false);
            }
        }
        catch (Exception ex)
        {
            // A single bad request must never take down the proxy.

            Logger.LogDebug(ex, "Proxy request handling failed.");
        }
        finally
        {
            if (rentedBody is not null)
            {
                ArrayPool<byte>.Shared.Return(rentedBody);
            }

            try
            {
                context.Response.OutputStream.Close();
            }
            catch (Exception)
            {
                // The client may have already disconnected.
            }
        }
    }

    /// <summary>
    ///   Reads the request body into a buffer rented from the shared <see cref="ArrayPool{T}"/>.  When the
    ///   content length is declared (the common case) the buffer is rented to that exact size; otherwise it
    ///   is grown as bytes arrive.
    /// </summary>
    ///
    /// <param name="request">The inbound listener request.</param>
    ///
    /// <returns>
    ///   The rented buffer (the caller is responsible for returning it to the pool) and the number of valid
    ///   bytes read into it.
    /// </returns>
    ///
    private static async Task<(byte[] Buffer, int Length)> ReadRequestBodyAsync(HttpListenerRequest request)
    {
        var input = request.InputStream;
        var declaredLength = request.ContentLength64;

        if (declaredLength > 0)
        {
            var sized = ArrayPool<byte>.Shared.Rent((int)declaredLength);

            try
            {
                var read = 0;

                while (read < declaredLength)
                {
                    var chunk = await input.ReadAsync(sized.AsMemory(read, (int)declaredLength - read)).ConfigureAwait(false);

                    if (chunk == 0)
                    {
                        break;
                    }

                    read += chunk;
                }

                return (sized, read);
            }
            catch
            {
                // Reclaim the buffer before the failure propagates; the caller never receives it.

                ArrayPool<byte>.Shared.Return(sized);
                throw;
            }
        }

        // The length is unknown (chunked transfer); grow a rented buffer as the body streams in.

        var growing = ArrayPool<byte>.Shared.Rent(RelayBufferSize);
        var count = 0;

        try
        {
            while (true)
            {
                if (count == growing.Length)
                {
                    var larger = ArrayPool<byte>.Shared.Rent(growing.Length * 2);
                    growing.AsSpan(0, count).CopyTo(larger);

                    // Point at the new buffer before returning the old one so the catch below never
                    // double-returns whichever buffer is live.

                    var previous = growing;
                    growing = larger;

                    ArrayPool<byte>.Shared.Return(previous);
                }

                var chunk = await input.ReadAsync(growing.AsMemory(count)).ConfigureAwait(false);

                if (chunk == 0)
                {
                    break;
                }

                count += chunk;
            }

            return (growing, count);
        }
        catch
        {
            // Reclaim the buffer before the failure propagates; the caller never receives it.

            ArrayPool<byte>.Shared.Return(growing);
            throw;
        }
    }

    /// <summary>
    ///   Builds the outbound request to Ollama, copying the method, body, and forwardable headers.
    /// </summary>
    ///
    /// <param name="request">The inbound listener request.</param>
    /// <param name="method">The HTTP method of the request.</param>
    /// <param name="body">The (possibly sanitized) request body buffer, or <c>null</c> when there is no body.</param>
    /// <param name="bodyLength">The number of valid bytes in <paramref name="body"/>.</param>
    ///
    /// <returns>The request message to send upstream.</returns>
    ///
    private HttpRequestMessage BuildForwardRequest(HttpListenerRequest request,
                                                   string method,
                                                   byte[]? body,
                                                   int bodyLength)
    {
        var forwarded = new HttpRequestMessage(new HttpMethod(method), UpstreamBase + request.Url!.PathAndQuery);

        if (bodyLength > 0)
        {
            forwarded.Content = new ByteArrayContent(body!, 0, bodyLength);
        }

        foreach (var header in request.Headers.AllKeys)
        {
            // Skip hop-by-hop and length headers; the client recomputes those.

            if ((header is null)
                || (header.Equals("Host", StringComparison.OrdinalIgnoreCase))
                || (header.Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                || (header.Equals("Connection", StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }

            var value = request.Headers[header];

            if (value is null)
            {
                continue;
            }

            if (header.StartsWith("Content-", StringComparison.OrdinalIgnoreCase))
            {
                forwarded.Content?.Headers.TryAddWithoutValidation(header, value);
            }
            else
            {
                forwarded.Headers.TryAddWithoutValidation(header, value);
            }
        }

        return forwarded;
    }

    /// <summary>
    ///   Streams the upstream response (status, headers, and body) back to the client without buffering.
    /// </summary>
    ///
    /// <param name="context">The listener context to write the response to.</param>
    /// <param name="upstream">The response received from Ollama.</param>
    ///
    private static async Task RelayResponseAsync(HttpListenerContext context,
                                                 HttpResponseMessage upstream)
    {
        context.Response.StatusCode = (int)upstream.StatusCode;
        context.Response.SendChunked = true;

        foreach (var header in upstream.Content.Headers)
        {
            if (header.Key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            context.Response.Headers[header.Key] = string.Join(",", header.Value);
        }

        using var stream = await upstream.Content.ReadAsStreamAsync().ConfigureAwait(false);
        var buffer = ArrayPool<byte>.Shared.Rent(RelayBufferSize);

        try
        {
            int read;

            while ((read = await stream.ReadAsync(buffer).ConfigureAwait(false)) > 0)
            {
                await context.Response.OutputStream.WriteAsync(buffer.AsMemory(0, read)).ConfigureAwait(false);
                await context.Response.OutputStream.FlushAsync().ConfigureAwait(false);
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    /// <summary>
    ///   Writes the <c>502</c> upstream-unavailable response.
    /// </summary>
    ///
    /// <param name="context">The listener context to write the response to.</param>
    ///
    private static async Task WriteUpstreamUnavailableAsync(HttpListenerContext context)
    {
        context.Response.StatusCode = 502;
        context.Response.ContentType = "application/json";

        await context.Response.OutputStream.WriteAsync(UpstreamUnavailableBody).ConfigureAwait(false);
    }
}
