using NUnit.Framework;

namespace __ROOT_NAMESPACE__.Tests;

public class GreetingServiceTests
{
    [Test]
    public void CreateGreetingIncludesName()
    {
        const string name = "developer";

        var greeting = GreetingService.CreateGreeting(name);

        Assert.That(greeting, Is.EqualTo("Hello, developer!"));
    }

    [Test]
    public void CreateGreetingRejectsWhitespace()
    {
        Assert.That(() => GreetingService.CreateGreeting(" "), Throws.ArgumentException);
    }
}
