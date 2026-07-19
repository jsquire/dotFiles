using Microsoft.Extensions.Configuration;
using NUnit.Framework;

namespace Squire.OllamaHost.Tests;

/// <summary>
///   The suite of tests for the <see cref="OllamaHostOptions"/> configuration binding.
/// </summary>
///
[TestFixture]
public class OllamaHostOptionsTests
{
    /// <summary>
    ///   Verifies that supplied configuration values are read into the options.
    /// </summary>
    ///
    [Test]
    public void FromConfigurationReadsProvidedValues()
    {
        var configuration = Build(new()
        {
            ["Proxy:ListenPort"] = "12000",
            ["Proxy:MaxConcurrentRequests"] = "8",
            ["Ollama:UpstreamPort"] = "12001",
            ["Ollama:ExecutablePath"] = @"C:\tools\ollama.exe",
            ["Ollama:WinGetPackageId"] = "Custom.Ollama"
        });

        var options = OllamaHostOptions.FromConfiguration(configuration);

        Assert.That(options.ProxyListenPort, Is.EqualTo(12000), "The proxy listen port should be read from configuration");
        Assert.That(options.ProxyMaxConcurrentRequests, Is.EqualTo(8), "The max concurrent requests should be read from configuration");
        Assert.That(options.OllamaUpstreamPort, Is.EqualTo(12001), "The upstream port should be read from configuration");
        Assert.That(options.OllamaExecutablePath, Is.EqualTo(@"C:\tools\ollama.exe"), "The executable path should be read from configuration");
        Assert.That(options.OllamaWinGetPackageId, Is.EqualTo("Custom.Ollama"), "The WinGet package id should be read from configuration");
    }

    /// <summary>
    ///   Verifies that absent configuration keys fall back to their defaults.
    /// </summary>
    ///
    [Test]
    public void FromConfigurationAppliesDefaultsWhenAbsent()
    {
        var configuration = Build(new());
        var options = OllamaHostOptions.FromConfiguration(configuration);

        Assert.That(options.ProxyListenPort, Is.EqualTo(11435), "The proxy listen port should default to 11435");
        Assert.That(options.ProxyMaxConcurrentRequests, Is.EqualTo(64), "The max concurrent requests should default to 64");
        Assert.That(options.OllamaUpstreamPort, Is.EqualTo(11434), "The upstream port should default to 11434");
        Assert.That(options.OllamaExecutablePath, Is.Null, "The executable path should default to null");
        Assert.That(options.OllamaWinGetPackageId, Is.EqualTo("Ollama.Ollama"), "The WinGet package id should default to Ollama.Ollama");
    }

    /// <summary>
    ///   Verifies that a non-positive or unparsable max concurrent requests falls back to the default.
    /// </summary>
    ///
    /// <param name="value">The invalid configured value.</param>
    ///
    [TestCase("0")]
    [TestCase("-5")]
    [TestCase("not-a-number")]
    public void FromConfigurationFallsBackWhenMaxConcurrentRequestsInvalid(string value)
    {
        var configuration = Build(new()
        {
            ["Proxy:MaxConcurrentRequests"] = value
        });

        var options = OllamaHostOptions.FromConfiguration(configuration);
        Assert.That(options.ProxyMaxConcurrentRequests, Is.EqualTo(64), $"An invalid value ({value}) should fall back to the default of 64");
    }

    /// <summary>
    ///   Builds an in-memory configuration from the supplied key/value pairs.
    /// </summary>
    ///
    /// <param name="values">The configuration keys and values.</param>
    ///
    /// <returns>The composed configuration.</returns>
    ///
    private static IConfiguration Build(Dictionary<string, string?> values) =>
        new ConfigurationBuilder().AddInMemoryCollection(values).Build();
}
