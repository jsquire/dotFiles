using System.Text;
using System.Text.Json.Nodes;
using NUnit.Framework;
using Squire.OllamaHost.Proxy;

namespace Squire.OllamaHost.Tests;

/// <summary>
///   The suite of tests for the <see cref="Sanitizer"/> class.
/// </summary>
///
[TestFixture]
public class SanitizerTests
{
    /// <summary>
    ///   Verifies that only chat completion POST requests are classified as chat paths.
    /// </summary>
    ///
    /// <param name="method">The HTTP method under test.</param>
    /// <param name="path">The request path under test.</param>
    /// <param name="expected">The expected classification.</param>
    ///
    [TestCase("POST", "/v1/chat/completions", true)]
    [TestCase("POST", "/api/chat", true)]
    [TestCase("post", "/v1/chat/completions", true)]
    [TestCase("GET", "/v1/chat/completions", false)]
    [TestCase("POST", "/v1/models", false)]
    [TestCase("POST", "/api/tags", false)]
    public void IsChatPathMatchesOnlyChatPosts(string method, string path, bool expected)
    {
        var isChatPath = Sanitizer.IsChatPath(method, path);
        Assert.That(isChatPath, Is.EqualTo(expected), $"{method} {path} should be classified as expected");
    }

    /// <summary>
    ///   Verifies that a null message content is coerced to an empty string.
    /// </summary>
    ///
    [Test]
    public void NullContentIsCoercedToEmptyString()
    {
        var body = Utf8("""{"messages":[{"role":"assistant","content":null}]}""");
        var length = Sanitizer.SanitizeChatBody(body);
        var message = JsonNode.Parse(body.AsSpan(0, length))!["messages"]![0]!;

        Assert.That(message["content"]!.GetValue<string>(), Is.EqualTo(string.Empty), "Null content should be coerced to an empty string");
    }

    /// <summary>
    ///   Verifies that coercing null content leaves an accompanying tool_calls array intact.
    /// </summary>
    ///
    [Test]
    public void NullContentWithToolCallsKeepsToolCalls()
    {
        var body = Utf8("""{"messages":[{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function"}]}]}""");
        var length = Sanitizer.SanitizeChatBody(body);
        var message = JsonNode.Parse(body.AsSpan(0, length))!["messages"]![0]!;

        Assert.That(message["content"]!.GetValue<string>(), Is.EqualTo(string.Empty), "Null content should be coerced to an empty string");
        Assert.That(message["tool_calls"]![0]!["id"]!.GetValue<string>(), Is.EqualTo("c1"), "The tool_calls array should be preserved unchanged");
    }

    /// <summary>
    ///   Verifies that every null content in a body is coerced, exercising the multi-offset compaction.
    /// </summary>
    ///
    [Test]
    public void MultipleNullContentsAreAllCoerced()
    {
        var body = Utf8("""{"messages":[{"role":"a","content":null},{"role":"b","content":null}]}""");
        var length = Sanitizer.SanitizeChatBody(body);
        var messages = JsonNode.Parse(body.AsSpan(0, length))!["messages"]!.AsArray();

        Assert.That(messages[0]!["content"]!.GetValue<string>(), Is.EqualTo(string.Empty), "The first null content should be coerced to an empty string");
        Assert.That(messages[1]!["content"]!.GetValue<string>(), Is.EqualTo(string.Empty), "The second null content should be coerced to an empty string");
    }

    /// <summary>
    ///   Verifies that a body whose content is already a string is returned unchanged.
    /// </summary>
    ///
    [Test]
    public void StringContentIsUnchanged()
    {
        var body = Utf8("""{"messages":[{"role":"user","content":"hello"}]}""");
        var length = Sanitizer.SanitizeChatBody(body);

        Assert.That(length, Is.EqualTo(body.Length), "A body with no null content should keep its original length");
        Assert.That(JsonNode.Parse(body.AsSpan(0, length))!["messages"]![0]!["content"]!.GetValue<string>(), Is.EqualTo("hello"), "Existing string content should be preserved");
    }

    /// <summary>
    ///   Verifies that only null contents are coerced while other messages are preserved.
    /// </summary>
    ///
    [Test]
    public void OnlyNullContentsAreChangedAndOthersPreserved()
    {
        var body = Utf8(
        """
            {"model":"m","messages":[
              {"role":"user","content":"hi"},
              {"role":"assistant","content":null},
              {"role":"user","content":"again"}
            ]}
        """);

        var length = Sanitizer.SanitizeChatBody(body);
        var messages = JsonNode.Parse(body.AsSpan(0, length))!["messages"]!.AsArray();

        Assert.That(messages[0]!["content"]!.GetValue<string>(), Is.EqualTo("hi"), "Leading string content should be preserved");
        Assert.That(messages[1]!["content"]!.GetValue<string>(), Is.EqualTo(string.Empty), "Null content should be coerced to an empty string");
        Assert.That(messages[2]!["content"]!.GetValue<string>(), Is.EqualTo("again"), "Trailing string content should be preserved");
    }

    /// <summary>
    ///   Verifies that a message without a content key is left untouched.
    /// </summary>
    ///
    [Test]
    public void MissingContentKeyIsLeftAlone()
    {
        var body = Utf8("""{"messages":[{"role":"assistant","tool_calls":[]}]}""");
        var length = Sanitizer.SanitizeChatBody(body);

        Assert.That(length, Is.EqualTo(body.Length), "A body with no content key should keep its original length");
        Assert.That(JsonNode.Parse(body.AsSpan(0, length))!["messages"]![0]!.AsObject().ContainsKey("content"), Is.False, "No content key should be introduced");
    }

    /// <summary>
    ///   Verifies that a body without a messages array passes through unchanged.
    /// </summary>
    ///
    [Test]
    public void BodyWithoutMessagesIsUnchanged()
    {
        var body = Utf8("""{"model":"m","prompt":"hi"}""");
        var length = Sanitizer.SanitizeChatBody(body);

        Assert.That(length, Is.EqualTo(body.Length), "A body without messages should keep its original length");
    }

    /// <summary>
    ///   Verifies that a malformed body fails open and is returned unchanged.
    /// </summary>
    ///
    [Test]
    public void MalformedJsonFailsOpen()
    {
        var body = Utf8("this is not json {");
        var length = Sanitizer.SanitizeChatBody(body);

        Assert.That(length, Is.EqualTo(body.Length), "Malformed JSON should be forwarded unchanged");
    }

    /// <summary>
    ///   Verifies that a string value containing the literal "null" is not corrupted by the fast-path filter.
    /// </summary>
    ///
    [Test]
    public void StringContainingNullLiteralIsUnchanged()
    {
        var body = Utf8("""{"messages":[{"role":"user","content":"the pointer was null and void"}]}""");
        var length = Sanitizer.SanitizeChatBody(body);

        Assert.That(length, Is.EqualTo(body.Length), "A string containing 'null' should keep its original length");
        Assert.That(JsonNode.Parse(body.AsSpan(0, length))!["messages"]![0]!["content"]!.GetValue<string>(), Is.EqualTo("the pointer was null and void"), "String content containing 'null' should be preserved verbatim");
    }

    /// <summary>
    ///   Encodes a string as UTF-8 bytes for use as a request body.
    /// </summary>
    ///
    /// <param name="value">The string to encode.</param>
    ///
    /// <returns>The UTF-8 encoded bytes.</returns>
    ///
    private static byte[] Utf8(string value) => Encoding.UTF8.GetBytes(value);
}
