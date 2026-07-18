using System.Text.Json;

namespace Squire.OllamaHost.Proxy;

/// <summary>
///   Fixes the one Ollama OpenAI-compatibility gap that poisons sessions:  a chat message whose
///   <c>content</c> is JSON <c>null</c>.  Ollama's endpoint rejects it with
///   <c>400 "invalid message content type: &lt;nil&gt;"</c> (OpenAI itself accepts null), which
///   permanently breaks the conversation.  This coerces any null message content to an empty string
///   and leaves everything else untouched.
/// </summary>
///
public static class Sanitizer
{
    /// <summary>The number of bytes in the JSON <c>null</c> literal.</summary>
    private const int NullTokenLength = 4;

    /// <summary>
    ///   Determines whether a request carries a chat <c>messages</c> array whose contents should be
    ///   sanitized.
    /// </summary>
    ///
    /// <param name="method">The HTTP method of the request.</param>
    /// <param name="path">The absolute request path.</param>
    ///
    /// <returns><c>true</c> for chat completion requests; otherwise, <c>false</c>.</returns>
    ///
    public static bool IsChatPath(string method,
                                  string path) =>
        (string.Equals(method, "POST", StringComparison.OrdinalIgnoreCase)) && ((path == "/v1/chat/completions") || (path == "/api/chat"));

    /// <summary>
    ///   Rewrites every <c>content: null</c> to <c>content: ""</c> in place within <paramref name="body"/>
    ///   and returns the new content length.  The body is scanned once with a <see cref="Utf8JsonReader"/>
    ///   (no DOM allocation); because <c>null</c> (four bytes) shrinks to <c>""</c> (two bytes) the result
    ///   always fits in the same buffer.  When nothing is null, or the body cannot be parsed, the buffer
    ///   is left untouched and its original length is returned.
    /// </summary>
    ///
    /// <param name="body">The mutable request body buffer; sanitized in place.</param>
    ///
    /// <returns>The length of the sanitized content within <paramref name="body"/>.</returns>
    ///
    public static int SanitizeChatBody(Span<byte> body)
    {
        // Fast negative filter:  with no `null` literal anywhere the body cannot contain content:null, so
        // the full tokenizer scan is skipped.  IndexOf is vectorized and far cheaper than the reader.

        if (body.IndexOf("null"u8) < 0)
        {
            return body.Length;
        }

        List<int>? nullValueOffsets = null;

        try
        {
            var reader = new Utf8JsonReader(body);

            while (reader.Read())
            {
                if ((reader.TokenType == JsonTokenType.PropertyName) && (reader.ValueTextEquals("content"u8)))
                {
                    reader.Read();

                    if (reader.TokenType == JsonTokenType.Null)
                    {
                        (nullValueOffsets ??= []).Add((int)reader.TokenStartIndex);
                    }
                }
            }
        }
        catch (JsonException)
        {
            // A body that cannot be parsed is forwarded unchanged.

            return body.Length;
        }

        return nullValueOffsets is null ? body.Length : CompactNullContent(body, nullValueOffsets);
    }

    /// <summary>
    ///   Compacts the buffer in place, replacing each four-byte <c>null</c> token at the given offsets
    ///   with a two-byte empty string and shifting the surrounding bytes left to close the gap.
    /// </summary>
    ///
    /// <param name="body">The mutable request body buffer.</param>
    /// <param name="nullValueOffsets">The ascending byte offsets at which each <c>null</c> content value starts.</param>
    ///
    /// <returns>The length of the compacted content.</returns>
    ///
    private static int CompactNullContent(Span<byte> body,
                                          List<int> nullValueOffsets)
    {
        var write = 0;
        var read = 0;

        foreach (var offset in nullValueOffsets)
        {
            var length = offset - read;

            body.Slice(read, length).CopyTo(body.Slice(write, length));
            write += length;

            body[write++] = (byte)'"';
            body[write++] = (byte)'"';

            read = offset + NullTokenLength;
        }

        var tail = body.Length - read;
        body.Slice(read, tail).CopyTo(body.Slice(write, tail));

        return write + tail;
    }
}
