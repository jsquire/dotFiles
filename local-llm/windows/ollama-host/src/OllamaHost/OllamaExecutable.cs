namespace Squire.OllamaHost;

/// <summary>
///   Locates the installed Ollama executable, shared by the supervisor (to launch it) and the tray (to
///   borrow its icon).
/// </summary>
///
internal static class OllamaExecutable
{
    /// <summary>
    ///   The default install path of <c>ollama.exe</c> under the user's local application data.
    /// </summary>
    ///
    public static string DefaultInstalledPath { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Ollama", "ollama.exe");

    /// <summary>
    ///   Returns the first existing executable among the configured override and the default install
    ///   path, or <c>null</c> when neither exists.
    /// </summary>
    ///
    /// <param name="overridePath">An explicit executable path from configuration, or <c>null</c>.</param>
    ///
    /// <returns>An existing executable path, or <c>null</c>.</returns>
    ///
    public static string? FindExistingPath(string? overridePath)
    {
        if ((!string.IsNullOrWhiteSpace(overridePath)) && (File.Exists(overridePath)))
        {
            return overridePath;
        }

        return File.Exists(DefaultInstalledPath) ? DefaultInstalledPath : null;
    }

    /// <summary>
    ///   Returns the path of Ollama's icon file (<c>app.ico</c>) in the install directory, or <c>null</c>
    ///   when it cannot be found.
    /// </summary>
    ///
    /// <param name="overridePath">An explicit executable path from configuration, or <c>null</c>.</param>
    ///
    /// <returns>The path of <c>app.ico</c>, or <c>null</c>.</returns>
    ///
    public static string? FindIconPath(string? overridePath)
    {
        var executable = FindExistingPath(overridePath) ?? DefaultInstalledPath;
        var directory = Path.GetDirectoryName(executable);

        if (directory is null)
        {
            return null;
        }

        var icon = Path.Combine(directory, "app.ico");
        return File.Exists(icon) ? icon : null;
    }
}
