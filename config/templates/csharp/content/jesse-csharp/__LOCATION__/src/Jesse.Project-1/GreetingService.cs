namespace __ROOT_NAMESPACE__;

/// <summary>
/// Provides application greetings.
/// </summary>
internal static class GreetingService
{
    /// <summary>
    /// Creates a greeting for the supplied name.
    /// </summary>
    ///
    /// <param name="name">The name of the person or system to greet.</param>
    ///
    /// <returns>A greeting containing the supplied name.</returns>
    ///
    /// <exception cref="ArgumentException">Thrown when <paramref name="name"/> is empty or whitespace.</exception>
    public static string CreateGreeting(string name)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);

        return $"Hello, {name}!";
    }
}
