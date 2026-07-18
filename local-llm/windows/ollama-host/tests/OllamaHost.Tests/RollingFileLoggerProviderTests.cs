using Microsoft.Extensions.Logging;
using NUnit.Framework;

namespace Squire.OllamaHost.Tests;

/// <summary>
///   The suite of tests for the <see cref="RollingFileLoggerProvider"/> class.
/// </summary>
///
[TestFixture]
public class RollingFileLoggerProviderTests
{
    /// <summary>
    ///   Verifies functionality of the CreateLogger method.
    /// </summary>
    ///
    [Test]
    public void CreateLoggerWritesEntryToFile()
    {
        var directory = CreateTempDirectory();

        try
        {
            var path = Path.Combine(directory, "ollama-host.log");
            var options = new LoggingOptions { FilePath = path, MinimumLevel = LogLevel.Information };

            using (var provider = new RollingFileLoggerProvider(options))
            {
                provider.CreateLogger("Proxy").LogInformation("hello world");
            }

            var contents = File.ReadAllText(path);

            Assert.That(contents, Does.Contain("hello world"), "The entry message should be written to the file");
            Assert.That(contents, Does.Contain("Proxy"), "The category name should be written to the file");
            Assert.That(contents, Does.Contain("[INFO]"), "The level abbreviation should be written to the file");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    /// <summary>
    ///   Verifies functionality of the CreateLogger method.
    /// </summary>
    ///
    [Test]
    public void CreateLoggerRespectsMinimumLevel()
    {
        var directory = CreateTempDirectory();

        try
        {
            var path = Path.Combine(directory, "ollama-host.log");
            var options = new LoggingOptions { FilePath = path, MinimumLevel = LogLevel.Warning };

            using (var provider = new RollingFileLoggerProvider(options))
            {
                var logger = provider.CreateLogger("Proxy");
                logger.LogInformation("info-message");
                logger.LogWarning("warn-message");
            }

            var contents = File.ReadAllText(path);

            Assert.That(contents, Does.Contain("warn-message"), "An entry at or above the minimum level should be written");
            Assert.That(contents, Does.Not.Contain("info-message"), "An entry below the minimum level should be discarded");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    /// <summary>
    ///   Verifies functionality of the CreateLogger method.
    /// </summary>
    ///
    [Test]
    public void CreateLoggerRollsActiveFileWhenOverSize()
    {
        var directory = CreateTempDirectory();

        try
        {
            var path = Path.Combine(directory, "ollama-host.log");
            var existing = new string('x', 128);
            File.WriteAllText(path, existing);

            var options = new LoggingOptions { FilePath = path, MinimumLevel = LogLevel.Information, RollSizeBytes = 64 };

            using (var provider = new RollingFileLoggerProvider(options))
            {
                provider.CreateLogger("Proxy").LogInformation("post-roll entry");
            }

            var archives = ArchivesIn(directory);

            Assert.That(archives, Has.Length.EqualTo(1), "The oversized active file should be rolled to a single archive");
            Assert.That(File.ReadAllText(archives[0]), Is.EqualTo(existing), "The archive should hold the previous active-file contents");
            Assert.That(File.ReadAllText(path), Does.Contain("post-roll entry"), "The active file should hold only entries written after the roll");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    /// <summary>
    ///   Verifies functionality of the CreateLogger method.
    /// </summary>
    ///
    [Test]
    public void CreateLoggerPrunesArchivesBeyondRetention()
    {
        var directory = CreateTempDirectory();

        try
        {
            var path = Path.Combine(directory, "ollama-host.log");
            File.WriteAllText(path, new string('x', 128));

            var oldest = SeedArchive(path, "20200101-000001", DateTime.UtcNow.AddMinutes(-30));
            SeedArchive(path, "20200101-000002", DateTime.UtcNow.AddMinutes(-20));
            SeedArchive(path, "20200101-000003", DateTime.UtcNow.AddMinutes(-10));

            var options = new LoggingOptions { FilePath = path, MinimumLevel = LogLevel.Information, RollSizeBytes = 64, RetainedFileCountLimit = 2 };

            using (var provider = new RollingFileLoggerProvider(options))
            {
                provider.CreateLogger("Proxy").LogInformation("trigger roll");
            }

            var archives = ArchivesIn(directory);

            Assert.That(archives, Has.Length.EqualTo(2), "Only the retention limit of archives should remain after pruning");
            Assert.That(File.Exists(oldest), Is.False, "The oldest archive should be pruned first");
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    /// <summary>
    ///   Returns the rolled archive files next to the active log, matched precisely so the active file is
    ///   excluded (a trailing <c>.*</c> search pattern would also match the extensionless active file).
    /// </summary>
    ///
    /// <param name="directory">The directory holding the log files.</param>
    ///
    /// <returns>The archive file paths.</returns>
    ///
    private static string[] ArchivesIn(string directory) =>
        Directory.GetFiles(directory).Where(name => Path.GetFileName(name).StartsWith("ollama-host.log.", StringComparison.Ordinal)).ToArray();

    /// <summary>
    ///   Creates a unique temporary directory for a test's log files.
    /// </summary>
    ///
    /// <returns>The path of the created directory.</returns>
    ///
    private static string CreateTempDirectory()
    {
        var directory = Path.Combine(Path.GetTempPath(), "ollama-host-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);

        return directory;
    }

    /// <summary>
    ///   Writes a placeholder archive file next to the active log and stamps its last-write time.
    /// </summary>
    ///
    /// <param name="path">The active log file path.</param>
    /// <param name="suffix">The archive suffix appended after a dot.</param>
    /// <param name="lastWriteUtc">The last-write timestamp to stamp on the archive.</param>
    ///
    /// <returns>The path of the created archive.</returns>
    ///
    private static string SeedArchive(string path, string suffix, DateTime lastWriteUtc)
    {
        var archive = $"{path}.{suffix}";

        File.WriteAllText(archive, "old");
        File.SetLastWriteTimeUtc(archive, lastWriteUtc);

        return archive;
    }
}
