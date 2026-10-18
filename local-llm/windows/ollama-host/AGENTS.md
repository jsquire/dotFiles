# ollama-host — Agent Guide

A Windows system-tray supervisor (NativeAOT C#) that runs Ollama and an in-process `content:null`
compatibility proxy as one unit, matching their lifetimes. See `README.md` for the full design.

This file is the platform-neutral contract for any AI agent working in this project. It is
self-contained and local to `ollama-host`; the conventions below are adopted from the author's
portfolio standards.

## Build, Test, Publish

```shell
# unit-test the core logic (no AOT, no C++ toolchain needed)
dotnet test .\tests\OllamaHost.Tests\OllamaHost.Tests.csproj -c Release

# quick compile sanity (non-AOT)
dotnet build .\OllamaHost.slnx -c Release

# ship the binary straight into dist/ (NativeAOT; requires the MSVC C++ toolchain on PATH, e.g. vcvars64.bat)
dotnet publish .\src\OllamaHost\OllamaHost.csproj -c Release -r win-x64 -o .\dist
```

Run tests with `dotnet test` without prompting. `ollama-host.exe --version` is a cheap post-build
smoke check.

## Structure & Namespaces

| Project | Path | Purpose |
|---|---|---|
| `OllamaHost.Proxy` | `src/OllamaHost.Proxy/` | AOT-safe, Win32-free logic: `Sanitizer`, `ReverseProxy`, `ProxyOptions` |
| `OllamaHost` | `src/OllamaHost/` | The `WinExe` app: Win32 P/Invoke, supervision, tray, config, logging |
| `OllamaHost.Tests` | `tests/OllamaHost.Tests/` | NUnit unit + integration tests |

Namespaces are rooted at `Squire.OllamaHost`:

- `Squire.OllamaHost.Proxy` — proxy + sanitizer (the unit-testable surface)

- `Squire.OllamaHost` — app: options, logging, supervisor, job object, tray, wiring

- `Squire.OllamaHost.Tests` — all tests (flat namespace, avoid sub-namespaces)

Nothing operationally significant is hard-coded: ports and logging come from `OllamaHostOptions`
(bound from `appsettings.json` + `OLLAMAHOST_` environment variables). Logging uses
`Microsoft.Extensions.Logging` with a console option and a rolling-file `ILoggerProvider`.

## Solution-wide settings

Do not duplicate these in individual `.csproj` files; they live in the shared MSBuild files:

- `Directory.Build.props` — metadata, version, `net10.0` (`$(CommonTargetFramework)`), `LangVersion latest`, nullable + implicit usings enabled, `TreatWarningsAsErrors`.

- `Directory.Packages.props` — central package management; add package versions here, not in `.csproj`.

- `Directory.Build.targets` — excludes `dist/`, `publish/`, and `*.md` from compilation.

- `.editorconfig` — formatting and C# style (4-space, Allman, LF, UTF-8, no final newline).

## Anti-Hallucination (apply to every task)

Base every technical decision on verified, authoritative data. Treat assumptions and guesses as
defects.

1. **Verify current state.** Read the relevant files before proposing a change; understand existing patterns and constraints.

2. **Research authoritative sources.** Confirm .NET APIs, P/Invoke signatures, and library behavior against official docs or the actual codebase, not memory. Win32 struct layouts and flags must be verified.

3. **Surface uncertainty explicitly.** Say "I lack sufficient information to determine..." rather than guessing. When multiple valid approaches exist, present options with trade-offs for a human decision.

4. **Structure analysis as** Facts (with file:line or doc sources) → Analysis → Uncertainties → Recommendation (with rationale).

5. **After implementing,** build, run the tests, and validate against the original requirement before claiming done.

## C# Conventions

**Language & framework**

- Target the latest .NET LTS (`net10.0`), latest C# (`LangVersion latest`), nullable enabled throughout.

- Prefer `var`. Use language keywords (`int`, `string`) over BCL type names.

**Formatting**

- 4-space indent, Allman braces, LF line endings, UTF-8, no final newline. File-scoped namespaces.

- Using directives outside the namespace, `System` first, then third-party, then project, all **contiguous** (no blank lines between namespace using groups). Separate only a genuinely different directive kind (a `using static` or a `using X = ...` alias) with a blank line. Omit a `using` for a namespace already in scope through an enclosing namespace (e.g. a `Squire.OllamaHost.Tests` file needs no `using Squire.OllamaHost;`).

- Within a method body, separate logical steps with single blank lines and keep tightly-coupled statements (a declaration and the statement that consumes it, a two-line swap) together; set control-flow blocks off with blank lines and precede a trailing `return` with one. This is a readability judgment, not a mechanical one-blank-per-statement rule.

**Naming**

| Element | Convention | Example |
|---|---|---|
| Classes / methods / properties | PascalCase | `OllamaSupervisor`, `SanitizeChatBody` |
| Interfaces | `I` + PascalCase (only when multiple implementations exist) | — |
| Constants | PascalCase | `ProxyPort` |
| `const`, `static readonly`, instance `readonly` fields | PascalCase | `Gate`, `Http` |
| Mutable fields | `_` + camelCase | `_process`, `_stopping` |
| Parameters / locals | camelCase | `listenPort`, `cancellationToken` |

**Key rule:** the `_` prefix is reserved for *mutable* fields only. Constants, `static readonly`, and
instance `readonly` fields use PascalCase.

**Member organization**

Order within a type: **Constants → Fields → Events → Properties → Constructors → Methods → Nested Types**.
Within each section order by visibility **most-visible-first** (public → internal → private). Fields group
`readonly` before mutable; methods group instance before static within the same visibility. So public
entry points precede private helpers, and a public constructor precedes an internal one.

**Documentation**

- Every member (fields, properties, constructors, methods, events) gets an XML doc comment. Fields use a single-line `/// <summary>…</summary>`; other members use the multi-line form with blank `///` separator lines between the summary, `<param>`, `<returns>`, and `<exception>` blocks and a trailing blank `///`.

- Inline comments are full sentences ending in a period, followed by a **blank line** before the next statement.

- One type per file, except `Native.cs`, which deliberately holds every Win32 P/Invoke and interop struct so native types never leak into the managed classes.

**Architecture & performance**

- Constructor injection via the composition root in `Program`. **Do not add interfaces for a type with a single implementation**; if a member must be overridden for testing, mark it `virtual` instead.

- All I/O async; accept a `CancellationToken` (default) and suffix such methods with `Async`. Use `ConfigureAwait(false)` in library code (`OllamaHost.Proxy`). Avoid `async void` except event handlers.

- Validate arguments with `ArgumentNullException.ThrowIfNull(param, nameof(param))`. Use standard exception types.

- `using` for disposables; prefer `IReadOnlyCollection`/`IReadOnlyDictionary` for immutable collections. Mind allocations; use `Span<T>`/`stackalloc` where it measurably helps.

- Native interop lives only in `OllamaHost/Native.cs`; keep `OllamaHost.Proxy` AOT-safe and Win32-free.

## Testing

- Test observable behavior and end-to-end scenarios including edge cases, not implementation details. This project uses **NUnit** with `Assert.That`.

- One test file per class (`Sanitizer` → `SanitizerTests.cs`). Create all subjects and doubles as locals in each test; no class-level fixtures or setup methods. Avoid `#region`.

- Name tests in PascalCase by the behavior validated (e.g. `NullContentIsCoercedToEmptyString`), not by the exception type or internal mechanism.

- Every fixture, test, and helper carries an XML `<summary>`. The fixture reads `The suite of tests for the <see cref="Type"/> class.`; a test method uses the member-focused voice `Verifies functionality of the {Member} method.` (or `... property.` / `... constructor.`), with the specific scenario carried by the test name. Document `<param>` on parameterized tests; never add `<returns>` to an async test (it returns a void-like `Task`).

- Give every `Assert.That` a descriptive message so a multi-assert failure identifies which check failed; interpolate context where it helps.

- Lay a test out in logical groups separated by single blank lines (setup, act, assertions), keeping tightly-coupled statements together and hoisting fixed test data to the top. Keep calls on one line; for a multi-line raw string argument, put the opening `"""` on its own line below the call.

- Do not add tests that only assert "does not throw" for trivial construction or happy-path calls. Every test must verify observable state, output, or a side effect.

- When writing tests, leave the implementation unchanged; if behavior looks wrong, surface it for human review rather than working around it.

## Documentation

- XML doc comments on all members: a `<summary>` on everything (single-line for fields and consts, the multi-line block for other members and every type including nested types), plus `<param>`/`<exception>` where they apply. Use `<returns>` only for a value-producing member: a synchronous value return or a `Task<T>`; never on a `void` method or a non-generic `Task`. Parameter docs describe purpose or behavior, never restating the name or type.

- Use `<inheritdoc />` for well-known members (`Dispose`, `ToString`); write explicit docs for domain-specific behavior.

- Inline comments are full sentences ending in a period, followed by a blank line before the next statement.

- Prose style: no em-dashes; use commas, colons, or parentheses instead.
