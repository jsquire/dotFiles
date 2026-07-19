# ollama-host (prebuilt binary)

`ollama-host.exe` is a self-contained **NativeAOT** build. The matching `.sha256` file holds its
SHA-256 so an installer can verify integrity before deploying. `appsettings.json` is an example
configuration with every key at its default.

## Target platform assumptions

- **Windows 10 or 11, x64.** The binary is compiled for `win-x64`; there is no ARM64 build here.
  Rebuild from `src/` for other architectures.

- **No .NET runtime is required.** NativeAOT statically links the runtime, so the target needs neither
  the .NET SDK nor the .NET Desktop Runtime.

- **Ollama is installed.** `ollama-host` launches `ollama serve` from
  `Ollama:ExecutablePath` (if set), else `%LOCALAPPDATA%\Programs\Ollama\ollama.exe`, else `ollama` on
  `PATH`. Install it with `winget install Ollama.Ollama`.

- **WinGet is available** if you use the tray's "Update Ollama" action.

- **The configured ports are free.** By default Ollama serves on `127.0.0.1:11434` and the proxy binds
  `127.0.0.1:11435`. Do not run a second proxy on the listen port at the same time.

## Configuration

Edit `appsettings.json` next to the exe, or set `OLLAMAHOST_`-prefixed environment variables (for
example `OLLAMAHOST_Proxy__ListenPort`). See the top-level `README.md` for the full key list. Logs
default to `%LOCALAPPDATA%\ollama-host\logs\ollama-host.log`, rolling at 1 MB.

## Rebuilding

Produced from `src/` with:

```
dotnet publish .\src\OllamaHost\OllamaHost.csproj -c Release -r win-x64
```

A post-publish step copies the built `ollama-host.exe` into this directory and regenerates
`ollama-host.exe.sha256`. NativeAOT requires the MSVC toolchain (the Visual Studio C++ build tools /
linker) on `PATH` at publish time, in addition to the .NET SDK.
