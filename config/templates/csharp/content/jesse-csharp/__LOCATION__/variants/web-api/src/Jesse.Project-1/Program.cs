using __ROOT_NAMESPACE__;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddOpenApi();

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.UseHttpsRedirection();
app.MapGet("/greeting/{name}", GreetingService.CreateGreeting);
app.Run();
