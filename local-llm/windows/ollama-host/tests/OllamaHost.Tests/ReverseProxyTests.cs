using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging.Abstractions;
using NUnit.Framework;
using Squire.OllamaHost.Proxy;

namespace Squire.OllamaHost.Tests;

/// <summary>
///   The suite of tests for the <see cref="ReverseProxy"/> class.
/// </summary>
///
[TestFixture]
public class ReverseProxyTests
{
    /// <summary>
    ///   Verifies that a chat request with null content is sanitized before it reaches the upstream.
    /// </summary>
    ///
    [Test]
    public async Task NullContentIsSanitizedBeforeReachingUpstream()
    {
        var upstreamPort = FreePort();
        var proxyPort = FreePort();

        using var upstream = new StubUpstream(upstreamPort);
        using var proxy = CreateProxy(proxyPort, upstreamPort);

        proxy.Start();

        var (status, _) = await PostAsync(proxyPort, "/v1/chat/completions", """{"messages":[{"role":"assistant","content":null}]}""");
        Assert.That(status, Is.EqualTo(200), "The proxy should forward the request successfully");

        var received = JsonNode.Parse(upstream.LastBody)!;
        Assert.That(received["messages"]![0]!["content"]!.GetValue<string>(), Is.EqualTo(string.Empty), "Null content should be coerced to an empty string before reaching the upstream");
    }

    /// <summary>
    ///   Verifies that a chat request with string content reaches the upstream unchanged.
    /// </summary>
    ///
    [Test]
    public async Task StringContentReachesUpstreamUnchanged()
    {
        var upstreamPort = FreePort();
        var proxyPort = FreePort();

        using var upstream = new StubUpstream(upstreamPort);
        using var proxy = CreateProxy(proxyPort, upstreamPort);

        proxy.Start();

        await PostAsync(proxyPort, "/v1/chat/completions", """{"messages":[{"role":"user","content":"hello"}]}""");

        var received = JsonNode.Parse(upstream.LastBody)!;
        Assert.That(received["messages"]![0]!["content"]!.GetValue<string>(), Is.EqualTo("hello"), "Existing string content should reach the upstream unchanged");
    }

    /// <summary>
    ///   Verifies that a non-chat request is forwarded without any body alteration.
    /// </summary>
    ///
    [Test]
    public async Task NonChatPathIsNotAltered()
    {
        const string raw = """{"messages":[{"role":"assistant","content":null}]}""";

        var upstreamPort = FreePort();
        var proxyPort = FreePort();

        using var upstream = new StubUpstream(upstreamPort);
        using var proxy = CreateProxy(proxyPort, upstreamPort);

        proxy.Start();

        await PostAsync(proxyPort, "/api/generate", raw);

        Assert.That(upstream.LastPath, Is.EqualTo("/api/generate"), "The request path should be forwarded unchanged");
        Assert.That(Encoding.UTF8.GetString(upstream.LastBody), Is.EqualTo(raw), "A non-chat body should be forwarded byte-for-byte");
    }

    /// <summary>
    ///   Verifies that the proxy returns a 502 when the upstream is unreachable.
    /// </summary>
    ///
    [Test]
    public async Task UpstreamDownReturns502()
    {
        var deadPort = FreePort();
        var proxyPort = FreePort();

        using var proxy = CreateProxy(proxyPort, deadPort);

        proxy.Start();

        var (status, _) = await PostAsync(proxyPort, "/v1/chat/completions", """{"messages":[{"role":"user","content":"hi"}]}""");
        Assert.That(status, Is.EqualTo(502), "An unreachable upstream should surface as a 502");
    }

    /// <summary>
    ///   Verifies that null content is sanitized when the body arrives without a Content-Length,
    ///   exercising the proxy's grow-and-double read path.
    /// </summary>
    ///
    [Test]
    public async Task NullContentIsSanitizedOverChunkedBody()
    {
        var upstreamPort = FreePort();
        var proxyPort = FreePort();

        using var upstream = new StubUpstream(upstreamPort);
        using var proxy = CreateProxy(proxyPort, upstreamPort);

        proxy.Start();

        // A body larger than the proxy's 64 KB read buffer, sent without a Content-Length, forces the
        // grow-and-double read path while the null content is still sanitized in place.

        var filler = new string('x', 100_000);
        var json = $$"""{"filler":"{{filler}}","messages":[{"role":"assistant","content":null}]}""";
        var (status, _) = await PostChunkedAsync(proxyPort, "/v1/chat/completions", json);

        Assert.That(status, Is.EqualTo(200), "The proxy should forward the chunked request successfully");

        var received = JsonNode.Parse(upstream.LastBody)!;

        Assert.That(received["messages"]![0]!["content"]!.GetValue<string>(), Is.EqualTo(string.Empty), "Null content should be coerced even when the body spans multiple read buffers");
        Assert.That(received["filler"]!.GetValue<string>(), Is.EqualTo(filler), "The large body should be forwarded intact");
    }

    /// <summary>
    ///   Creates a reverse proxy bound to the supplied loopback ports.
    /// </summary>
    ///
    /// <param name="listenPort">The port the proxy listens on.</param>
    /// <param name="upstreamPort">The port the proxy forwards to.</param>
    ///
    /// <returns>A configured, unstarted proxy.</returns>
    ///
    private static ReverseProxy CreateProxy(int listenPort, int upstreamPort) =>
        new(new ProxyOptions { ListenPort = listenPort, UpstreamPort = upstreamPort }, NullLogger<ReverseProxy>.Instance);

    /// <summary>
    ///   Reserves an unused loopback TCP port.
    /// </summary>
    ///
    /// <returns>A free port number.</returns>
    ///
    private static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();

        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();

        return port;
    }

    /// <summary>
    ///   Posts a JSON body to the proxy with a declared Content-Length.
    /// </summary>
    ///
    /// <param name="port">The proxy port to target.</param>
    /// <param name="path">The request path.</param>
    /// <param name="json">The JSON request body.</param>
    ///
    /// <returns>The response status code and body.</returns>
    ///
    private static async Task<(int Status, string Body)> PostAsync(int port, string path, string json)
    {
        using var client = new HttpClient();

        var content = new StringContent(json, Encoding.UTF8, "application/json");
        var response = await client.PostAsync($"http://127.0.0.1:{port}{path}", content);

        return ((int)response.StatusCode, await response.Content.ReadAsStringAsync());
    }

    /// <summary>
    ///   Posts a JSON body to the proxy using chunked transfer, omitting the Content-Length.
    /// </summary>
    ///
    /// <param name="port">The proxy port to target.</param>
    /// <param name="path">The request path.</param>
    /// <param name="json">The JSON request body.</param>
    ///
    /// <returns>The response status code and body.</returns>
    ///
    private static async Task<(int Status, string Body)> PostChunkedAsync(int port, string path, string json)
    {
        using var client = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{port}{path}")
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        };

        // Force a chunked upload so the server takes the unknown-length read path.

        request.Headers.TransferEncodingChunked = true;

        var response = await client.SendAsync(request);

        return ((int)response.StatusCode, await response.Content.ReadAsStringAsync());
    }

    /// <summary>
    ///   A stub upstream that records the last request body and echoes it back with a 200.
    /// </summary>
    ///
    private sealed class StubUpstream : IDisposable
    {
        /// <summary>The listener that accepts forwarded requests.</summary>
        private readonly HttpListener Listener = new();

        /// <summary>
        ///   The body of the most recently received request.
        /// </summary>
        ///
        public byte[] LastBody { get; private set; } = [];

        /// <summary>
        ///   The absolute path of the most recently received request.
        /// </summary>
        ///
        public string LastPath { get; private set; } = "";

        /// <summary>
        ///   Initializes a new instance of the <see cref="StubUpstream"/> class and begins listening.
        /// </summary>
        ///
        /// <param name="port">The loopback port to listen on.</param>
        ///
        public StubUpstream(int port)
        {
            Listener.Prefixes.Add($"http://127.0.0.1:{port}/");
            Listener.Start();

            _ = Task.Run(LoopAsync);
        }

        /// <summary>
        ///   Stops the listener and releases its resources.
        /// </summary>
        ///
        public void Dispose()
        {
            try
            {
                Listener.Stop();
                Listener.Close();
            }
            catch (ObjectDisposedException)
            {
                // Already disposed.
            }
        }

        /// <summary>
        ///   Accepts requests, records each body and path, and echoes the body back with a 200.
        /// </summary>
        ///
        private async Task LoopAsync()
        {
            while (Listener.IsListening)
            {
                HttpListenerContext context;

                try
                {
                    context = await Listener.GetContextAsync();
                }
                catch (Exception)
                {
                    break;
                }

                using var buffer = new MemoryStream();
                await context.Request.InputStream.CopyToAsync(buffer);

                LastBody = buffer.ToArray();
                LastPath = context.Request.Url!.AbsolutePath;

                context.Response.StatusCode = 200;
                context.Response.ContentType = "application/json";

                await context.Response.OutputStream.WriteAsync(LastBody);
                context.Response.OutputStream.Close();
            }
        }
    }
}
