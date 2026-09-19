using NUnit.Framework;

namespace __ROOT_NAMESPACE__.Tests;

[TestFixture]
[NonParallelizable]
public class EntryPointTests
{
    [Test]
    public void MainWritesHelloWorld()
    {
        var originalOut = Console.Out;

        try
        {
            using var output = new StringWriter();
            Console.SetOut(output);

            EntryPoint.Main();

            Assert.That(output.ToString(), Is.EqualTo($"Hello, World!{Environment.NewLine}"));
        }
        finally
        {
            Console.SetOut(originalOut);
        }
    }
}
