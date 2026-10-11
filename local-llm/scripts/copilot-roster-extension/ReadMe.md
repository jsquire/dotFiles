# Copilot roster routing extension

Experimental user extension for ordinary `copilot` sessions. It adds `/local`,
`/server`, and `/cloud` without replacing the harness, its native `/model`
command, conversation, or foreground permission handler.

Requires Node 22 or newer for installation and a CLI bundle exposing the
experimental provider registration, scoped withdrawal, and session activity
APIs. Native mock-backed integration is verified through Copilot CLI 1.0.91.
Live isolated OpenRouter routing is verified on Copilot CLI 1.0.95. The earlier
1.0.87 feasibility probe does not establish compatibility with this
implementation's newer scoped-withdrawal API.

## Trial boundaries

- No model changes or endpoint discovery occur during extension startup.
- `/local` discovers installed local models from Ollama `/api/tags`, obtains
  each model's configured context and capabilities from `/api/show`, excludes
  Ollama-hosted entries, and requires the existing compatibility proxy. It
  does not depend on the wrapper roster. There is no direct-local or cloud
  substitution when Ollama or the proxy is unavailable.
- `/server` selects only a mode already served and ready with the expected
  model ID. It never posts a shared-server switch. The existing switch service
  has no atomic ownership lease protecting active inference consumers.
- `/cloud` supports static OpenAI Chat Completions or Anthropic Messages
  services and live OpenRouter discovery. OpenRouter's complete text-model
  catalog is fetched only when `/cloud` is invoked. Preferred frontier-coding
  models are highlighted but do not restrict other compatible choices.
- OpenRouter entries without tool support remain visible with an exact
  incompatibility reason. They cannot be activated as a normal Copilot model.
- Every cloud selection requires a history-transfer confirmation. A
  noninteractive host cannot select cloud through these commands.
- Agent delegation, messages to existing agents, and image tools are denied on
  extension-managed routes. Image task rows explicitly direct the user back to
  the existing wrapper.
- A small session-owned loopback gateway forwards to exactly one selected
  endpoint, clamps the output request parameter, and applies configured body
  policy. It does not select another endpoint, follow redirects, or retry.
- Prompt/context limits are registered with the runtime. Live streaming and
  tool-call formatting are verified with a free OpenRouter coding model.
  Long-history compaction, boundary-sized generation-limit compliance,
  vision/reasoning capabilities, authenticated Copilot return and rendered TUI
  behavior still need acceptance testing.

The Git hook denies common legacy mutation command patterns. It is not an
exhaustive shell parser or a substitute for the user's instruction and native
permission policy. The original permission handler and other hooks are
preserved. Do not retire the wrapper based on this hook alone.

## Install on Windows

Run from this directory after reviewing the extension code.

```powershell
npm ci --ignore-scripts --no-audit --no-fund
node .\deploy.mjs ensure --role desktop --server-host 192.168.1.99
```

The server host is an explicit example matching this installation's existing
launcher. Omit it for local-only operation or substitute the intended host.
No server request is made by the installer.

`ensure` performs a fresh installation or a journaled upgrade of an existing
managed deployment. It refuses unmanaged or conflicting files rather than
overwriting them. If the managed modules and configuration already match,
`ensure` returns without rewriting files or extending the journal.

The installer deploys only four runtime modules and a separate
`roster-routing.json`, enables experimental features, and selects Load Only.
It preserves existing settings comments, model defaults, other extension
settings, wrappers, rosters, authentication and sessions. It refuses to
adopt or overwrite an unmanaged extension or routing configuration.
Intentionally disabled extensions require an explicit user enablement first.
Settings symlinks are not overwritten; enable the required settings through
the CLI first if automatic editing is refused.

The installer prints the exact recovery manifest path. Keep it.

## Install on Linux

The same Node installer is platform-neutral and uses the existing deployed
rosters in the user's local-LLM configuration directory.

```bash
npm ci --ignore-scripts --no-audit --no-fund
node deploy.mjs ensure --role client --server-host YOUR_SERVER_HOST
```

Use `--role desktop` for local Ollama plus an optional server, `--role client`
for server plus cloud, and `--role server` for local vLLM plus cloud. Linux
installation has not been executed on a Linux host in this Windows
implementation run. No remote server deployment is performed.

## Start and use

Start normal `copilot` in a new session. The CLI prompts for this extension's
scoped permission to register hooks. Copilot CLI 1.0.91 offers one-time,
running-session, and location-persisted approval. Choose the location option
only when the repository or working directory should always trust this
extension. Do not use allow-all to bypass the prompt.

```text
/local
/local qwen38-27b-192k
/server active-mode-id
/cloud
/cloud openrouter anthropic/claude-opus-5.5
/local status
/model
```

Local selection IDs are the model names returned by Ollama. Opening a menu does
not pull or unload models. Cloud service selection and model selection are
distinct. OpenRouter labels include preference, current catalog pricing,
context and compatibility. Native `/model` remains available and can also
expose registered BYOK models.

Credential access uses the SDK's documented initial `joinSession` grant.
Configured sensitive variable names may be prompted at extension startup.
CLI 1.0.91 also offers running-session and location-persisted approval for the
exact extension and environment-variable set. Values are never persisted.
Only the selected service's credential is consumed or forwarded after the cloud
confirmation. Values are never written into configuration or route logs.
If a requested credential grant is denied, the SDK can refuse to load the
extension; the existing session and its permission handler remain intact.
Missing values at selection produce a visible error without changing routes.

Requesting another grant by calling `joinSession` again inside a command
disrupted host delivery in an isolated 1.0.90 experiment. The production module
therefore attaches once. It does not use that unsupported on-demand pattern.

Use fresh trial sessions until resume behavior is validated. After extension
reload or runtime restart, reselect the route with its command
before inference. Old gateway endpoints belong to the exited extension process.
Following an explicit new selection, scoped withdrawal removes stale owned
models while leaving unrelated registry entries intact. Persisting an
extension-only default model is not supported in this trial.

## OpenRouter

The default managed configuration declares `OPENROUTER_API_KEY` by name but
does not create, read or store a value during installation. No OpenRouter
request occurs at extension startup.

When `/cloud` selects OpenRouter, the extension fetches the public model catalog,
sorts preferred frontier-coding entries first and keeps every compatible text
model selectable. Context and output budgets come from catalog metadata and are
clamped to local ceilings. Models without text output, tools, usable context or
current availability are shown with a reason and are not activated.

Every inference request includes:

```json
{
  "provider": {
    "allow_fallbacks": false,
    "require_parameters": true
  }
}
```

This disables another upstream attempt after failure and excludes endpoints
that cannot accept the requested parameters. OpenRouter account privacy
settings control provider data retention and training eligibility. The
extension does not force `data_collection` or ZDR request fields, so free
retained-data models remain selectable when the account permits them. Treat
those models as suitable only for synthetic, public or otherwise
non-confidential content.

OpenRouter still chooses the initial eligible upstream unless a future
configuration adds `provider.only` or `provider.order`.

## Add third-party systems

Edit the installed `roster-routing.json` service list and start a new session.
The default installer configures OpenRouter discovery and stores no credentials.
`cloud-config.example.json` contains illustrative entries for both API families.
Replace URLs, model IDs and budgets with the intended system's verified values.
Keep the local/server sections from the installed configuration if using them.

Use `api=openai-chat` for Chat Completions and `api=anthropic-messages` for
Messages. Upstream base URLs include the API version prefix where required,
for example `https://YOUR_SYSTEM/v1`. The gateway handles the CLI's different
OpenAI/Anthropic URL conventions; the configured upstream receives
`/chat/completions` or `/messages`.

Credentials reference an environment variable with `kind=api-key` or
`kind=bearer`. Defaults are Authorization Bearer for Chat and x-api-key for
Messages. Optional `header` and `prefix` support compatible systems with
different credential header conventions. Static non-secret headers are also
supported. HTTPS is required outside loopback for third-party services.
Embedded URL credentials and inline secret headers are rejected.

Optional `requestBody` applies service-specific policy without adding
vendor branches. It cannot override model, messages, tools, streaming or token
identity/budget fields. For a router requiring upstream pinning, an example is
`{"provider":{"only":["YOUR_UPSTREAM"],"allow_fallbacks":false}}`.
OpenRouter is only one example. A system's own upstream routing policy must
be validated rather than assumed from the client-side no-failover guarantee.

An API family is an eligibility criterion, not proof that every implementation
is compatible. Validate authentication, paths, streaming, tool calls/results,
model limits and errors before adopting a new system.

## Non-destructive recovery

Close only your affected session after its work has stopped. Do not kill shared
model services or other Copilot sessions. Run the printed rollback command.

```powershell
node .\deploy.mjs rollback --manifest "ABSOLUTE_RECOVERY_MANIFEST_PATH"
```

Rollback compares original, deployed and current owned values. It preserves
concurrent edits to unrelated settings and refuses conflicts on owned settings
or module files without overwriting them. Modules move into the recovery
directory, not the recycle bin or a deleted tree. Sessions, models, credentials,
project files and wrappers remain untouched.

The journal is written before each deployment mutation, and settings/journal
replacement is atomic. A stale installer lock is recovered only when its
specific owning PID is no longer running. A live or unverifiable lock blocks
deployment.

On a conflict, preserve the directory and inspect the manifest. An explicitly
coordinated move of this exact extension directory outside discovery can
disable it for future sessions while retaining changed files. Do not clear
sessions, reset permissions, globally disable other extensions, or replace the
whole settings file as a shortcut.

Choose the existing wrapper or native Copilot explicitly after recovery.
Verify the selected route before sending the next message. Recovery never
automatically transfers a local conversation to cloud.

## Validation

Tests require an explicit artifact directory and do not use the system temp
directory, real models or real cloud services.

```powershell
$env:ROSTER_TEST_ROOT = "ABSOLUTE_SESSION_ARTIFACT_DIRECTORY"
npm test
$env:COPILOT_SDK_PATH = "ABSOLUTE_INSTALLED_SDK_INDEX_JS"
$env:COPILOT_RUNTIME_PATH = "ABSOLUTE_COPILOT_EXECUTABLE"
$env:ROSTER_DENY_CREDENTIAL = "0"
npm run test:runtime
$env:ROSTER_DENY_CREDENTIAL = "1"
npm run test:runtime
```

The runtime fixture grants only its own synthetic hook privilege and, in the
grant condition, its fabricated API key. Ordinary synthetic tool calls remain
denied by the original host handler. Results and isolated runtime homes are
retained under the supplied artifact directory.

An additional isolated 1.0.91 proof verified that session-scoped extension
approval survives extension reload and location-scoped approval suppresses the
same prompt in a second session under the same working directory. Location
approval is recorded by Copilot in its permissions configuration. It is not a
machine-wide grant and does not apply to other repository roots or directories.
