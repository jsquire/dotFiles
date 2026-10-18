# ollama-host

A Windows **system-tray supervisor** that runs Ollama and a compatibility proxy as
one unit and keeps their lifetimes matched.  Written in C# and compiled as an AOT native binary, its goal is to be tiny, unobtrusive, and consume minimal resources.

It exists to fix a specific, session-poisoning bug: reasoning models over Ollama's OpenAI-compatible
endpoint will occasionally produce a turn where text is empty, which the client then replays as `content: null`.
Ollama's `/v1/chat/completions` is strict in its validation and rejects the `null` with an HTTP 400 response, permanently breaking the conversation. `ollama-host` sits in front of Ollama and coerces any `content: null` message to an empty string value to pass validation.

## What it does

Concretely, the supervisor:

- **Starts `ollama serve` as a monitored child process** (told which port to serve on via `OLLAMA_HOST`)
  and hosts an **in-process reverse proxy** in front of it. The proxy rewrites `content: null` on chat
  requests and streams everything else through untouched; if Ollama is down it returns an HTTP 502.

- **Lives in the system tray** with a right-click menu (Status, Restart Ollama, Restart Proxy,
  Update Ollama via WinGet, Exit) and no console window.

- **Matches lifetimes.** If Ollama or the proxy dies unexpectedly, the tray prompts to restart it;
  choosing **Exit** tears both down together. This managed lifetime for Ollama is also enforced If 
  the supervisor itself crashes, so a failure can never orphan the GPU.

- **Runs as a single instance** with a guard to prevent launching concurrent copies.

## How do I use it

Launch the **Ollama Host** Start Menu shortcut or run `ollama-host.exe` directly. The host starts
Ollama, initializes the proxy, and drops to the tray. Point your clients at `http://localhost:11435/v1` 
rather than Ollama's own `:11434` and the `content: null` protection is automatically applied.

The tray menu covers day-to-day control: check status, restart Ollama or the proxy independently,
trigger a WinGet update of Ollama, or exit (which stops both).

### Configuration

Settings load from `appsettings.json` next to the exe, overlaid by environment variables using the
`OLLAMAHOST_` prefix (for example `OLLAMAHOST_Proxy__ListenPort=11500`). Every key has a default, so
configuration is optional.

| Key | Default | Purpose |
|---|:---:|---|
| Proxy:ListenPort | 11435 | Port clients target |
| Proxy:MaxConcurrentRequests | 64 | Requests handled at once before the accept loop applies backpressure |
| Ollama:UpstreamPort | 11434 | Port Ollama serves on (and the proxy forwards to) |
| Ollama:ExecutablePath | auto | Explicit `ollama.exe`; otherwise resolved from the install dir or `PATH` |
| Logging:Sink | File | `File` or `Console` |
| Logging:MinimumLevel | Information | Minimum log level |
| Logging:File:Path | `%LOCALAPPDATA%\ollama-host\logs\ollama-host.log` | Active log file |
| Logging:File:RollSizeBytes | 1048576 | Roll the log at this size (1 MB) |
| Logging:File:RetainedFileCountLimit | 2 | Rolled archives to keep |

Logging is built on `Microsoft.Extensions.Logging`. The file sink is a small rolling `ILoggerProvider`
written for this project, since the logging ecosystem ships no first-party file provider.

## How do I build it

Building requires the **.NET 10 SDK** or greater. A NativeAOT publish additionally requires the **MSVC C++
toolchain** (generally installed by Visual Studio C++ build tools) on `PATH`; the SDK alone fails at the native-link step.
Run the publish from a Developer Command Prompt, or after calling `vcvars64.bat`.

```powershell
# Test the core logic (no AOT, no C++ toolchain needed)
dotnet test .\tests\OllamaHost.Tests\OllamaHost.Tests.csproj -c Release

# Build (non-AOT, quick sanity check)
dotnet build .\OllamaHost.slnx -c Release

# Publish the shipping binary (NativeAOT; needs the MSVC toolchain on PATH). A post-publish
# step stages the exe into dist/ and refreshes its .sha256.
dotnet publish .\src\OllamaHost\OllamaHost.csproj -c Release -r win-x64
```

`ollama-host.exe --version` prints the version and exits, which serves as a cheap post-build smoke
check.

The `dist/` directory holds the shipping copy that the installer deploys. A post-publish MSBuild step
copies the freshly published `ollama-host.exe` into `dist/` and regenerates the adjacent `.sha256`, so
a normal `dotnet publish` keeps `dist/` current; refreshing it remains the responsibility of whoever
changes the code. The Windows installer
(`local-llm/windows/install-windows.ps1`) copies `dist/ollama-host.exe` verbatim — verifying its
`.sha256` — along with the example `appsettings.json` to `%LOCALAPPDATA%\ollama-host\`, and creates the
**Ollama Host** Start Menu shortcut. It never builds from source, so no SDK is required on the target.
See `dist/README.md` for the target-platform assumptions.

## Source structure

- **src**  
_The proxy core and the tray application that supervises Ollama._

- **tests**  
_The NUnit coverage for the proxy core._

- **dist**  
_The prebuilt, self-contained binary the installer deploys, with its checksum and example configuration._

- **OllamaHost.slnx**  
_The solution file for the project._

## Design notes

- **No WinForms; C# on NativeAOT**  
  The tray icon, menu, balloon notifications, and the Yes/No prompt are implemented as Win32 P/Invoke calls rather than relying on a UI framework. Avoiding WinForms and WPF keeps the whole app NativeAOT-compatible, so it ships as a single self-contained exe of roughly 5 MB with no .NET runtime to install on the target.

- **The proxy is minimal and transparent**  
  The proxy only ever coerces a `content: null` field to `""`. Otherwise, it forwards the bytes unchanged. This ensures that the proxy targets only the one incompatibility that breaks sessions and nothing else.

- **A Job Object guarantees cleanup**  
  Ollama is spawned into a Windows Job Object marked `KILL_ON_JOB_CLOSE`. Because the job handle is
  owned by the supervisor process, the operating system tears Ollama down if the supervisor exits for
  any reason, including a crash.  This ensures that the GPU is never left pinned by an orphaned server.

- **File logging is size-aware**
  The local file-based implementation of `ILoggerProvider` rolls files at a size threshold and prunes to avoid unbounded growth. Thresholds are configuration driven (see the table above).

- **The tray borrows Ollama's icon**  
  Rather than ship its own artwork, the tray loads `app.ico` from the Ollama install directory at
  runtime, falling back to the shared application icon when Ollama cannot be found.
