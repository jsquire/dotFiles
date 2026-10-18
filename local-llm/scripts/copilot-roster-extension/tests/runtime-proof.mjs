import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";
import { install } from "../deploy.mjs";

const root = process.env.ROSTER_TEST_ROOT;
assert(root && process.env.COPILOT_SDK_PATH && process.env.COPILOT_RUNTIME_PATH,
    "Set isolated ROSTER_TEST_ROOT, COPILOT_SDK_PATH and COPILOT_RUNTIME_PATH");
await mkdir(root, { recursive: true });
const run = await mkdtemp(join(root, "runtime-"));
const home = join(run, "home");
const requests = [];
const results = [];
const errors = [];
let failing = false;
const mock = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {};
    const reply = data => { res.setHeader("content-type", "application/json"); res.end(JSON.stringify(data)); };
    if (req.url === "/api/tags") return reply({ models: [{ name: "local-wire" }, { name: "remote-wire", remote_host: "https://not-used.example" }] });
    if (req.url === "/api/show") return reply({
        parameters: "num_ctx 32768",
        details: { parameter_size: "1B", quantization_level: "Q4_K_M" },
        model_info: { "general.architecture": "proof", "proof.context_length": 32768 },
    });
    if (req.url === "/control/models") return reply({
        schema_version: 2,
        modes: [{ mode: "active", label: "Active fake server", model_id: "server-wire", ctx: 32768,
            max_prompt: 24576, max_output: 256, imagegen_disabled: true }],
    });
    if (req.url === "/control/status") return reply({ mode: "active", api_up: true, served_model: "server-wire" });
    if (req.url === "/openrouter/models") return reply({ data: [{
        id: "dynamic/model",
        name: "Dynamic proof model",
        context_length: 32768,
        architecture: { output_modalities: ["text"] },
        pricing: { prompt: "0.000001", completion: "0.000002" },
        supported_parameters: ["tools", "max_tokens"],
        top_provider: { max_completion_tokens: 256 },
        expiration_date: null,
    }] });
    if (req.url?.endsWith("/models")) {
        return reply({ data: [{ id: req.url.startsWith("/local") ? "local-wire" : "server-wire" }] });
    }
    requests.push({
        path: req.url, model: body.model, maxTokens: body.max_tokens,
        stream: body.stream, marker: JSON.stringify(body.messages).includes("ROSTER-PROOF-ALPHA"),
        providerPolicy: body.provider,
        syntheticCredential: req.headers.authorization === "Bearer synthetic-fixture-key",
    });
    if (failing) {
        res.writeHead(503, { "content-type": "application/json" });
        return res.end('{"error":{"message":"synthetic failure"}}');
    }
    const content = `Synthetic ${body.model} response`;
    if (req.url?.endsWith("/messages")) {
        if (body.stream) {
            res.writeHead(200, { "content-type": "text/event-stream" });
            const event = (type, data) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
            event("message_start", { message: { id: "msg_proof", type: "message", role: "assistant",
                model: body.model, content: [], stop_reason: null, stop_sequence: null,
                usage: { input_tokens: 100, output_tokens: 0 } } });
            event("content_block_start", { index: 0, content_block: { type: "text", text: "" } });
            event("content_block_delta", { index: 0, delta: { type: "text_delta", text: content } });
            event("content_block_stop", { index: 0 });
            event("message_delta", { delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 8 } });
            event("message_stop", {});
            return res.end();
        }
        return reply({ id: "msg_proof", type: "message", role: "assistant", model: body.model,
            content: [{ type: "text", text: content }], stop_reason: "end_turn", stop_sequence: null,
            usage: { input_tokens: 100, output_tokens: 8 } });
    }
    if (body.stream) {
        const chunk = { id: "proof", object: "chat.completion.chunk", created: 1, model: body.model };
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(`data: ${JSON.stringify({ ...chunk, choices: [{ index: 0, delta: { role: "assistant", content }, finish_reason: null }] })}\n\n`);
        res.write(`data: ${JSON.stringify({ ...chunk, choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 100, completion_tokens: 8, total_tokens: 108 } })}\n\n`);
        return res.end("data: [DONE]\n\n");
    }
    reply({ id: "proof", object: "chat.completion", created: 1, model: body.model,
        choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
        usage: { prompt_tokens: 100, completion_tokens: 8, total_tokens: 108 } });
});
await new Promise(resolve => mock.listen(0, "127.0.0.1", resolve));
const url = `http://127.0.0.1:${mock.address().port}`;
const common = { id: "org/model", maxPromptTokens: 24576, maxContextWindowTokens: 32768, maxOutputTokens: 256 };
const configuration = {
    schemaVersion: 1,
    local: { discoveryUrl: `${url}/api/tags`, baseUrl: `${url}/local/v1` },
    server: { rosterPath: join(run, "not-needed.json"), controlUrl: `${url}/control`, baseUrl: `${url}/server/v1` },
    services: [
        { id: "chat-service", api: "openai-chat", baseUrl: `${url}/chat/v1`, models: [{ ...common, wireModel: "chat-wire" }] },
        { id: "messages-service", api: "anthropic-messages", baseUrl: `${url}/anthropic/v1`, models: [{ ...common, wireModel: "messages-wire" }] },
        { id: "credential-service", api: "openai-chat", baseUrl: `${url}/credential/v1`,
            credential: { env: "OPENAI_API_KEY", kind: "api-key" },
            models: [{ ...common, wireModel: "credential-wire" }] },
        { id: "missing-key-service", api: "openai-chat", baseUrl: `${url}/missing/v1`,
            credential: { env: "UNSET_SYNTHETIC_SERVICE_API_KEY", kind: "api-key" },
            models: [{ ...common, wireModel: "missing-wire" }] },
        { id: "openrouter", api: "openai-chat", baseUrl: `${url}/openrouter/v1`,
            requestBody: { provider: { allow_fallbacks: false, require_parameters: true } },
            discovery: { kind: "openrouter", url: `${url}/openrouter/models`,
                preferredModels: ["dynamic/model"], maxContextWindowTokens: 32768,
                maxOutputTokens: 256, defaultMaxOutputTokens: 128 } },
    ],
    timeoutMs: 10000,
};
await install(home, configuration);
await mkdir(join(run, "temp"), { recursive: true });
const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) =>
    !/(TOKEN|SECRET|API_KEY|COPILOT|^GH_|^GITHUB_|^OPENAI_|^ANTHROPIC_)/i.test(key)));
Object.assign(environment, { COPILOT_HOME: home, COPILOT_CACHE_HOME: join(run, "cache"),
    COPILOT_OFFLINE: "true", COPILOT_PROVIDER_BASE_URL: `${url}/seed/v1`, COPILOT_MODEL: "seed-wire",
    OPENAI_API_KEY: "synthetic-fixture-key",
    COPILOT_DISABLE_TELEMETRY: "true", TMP: join(run, "temp"), TEMP: join(run, "temp") });
const { CopilotClient, RuntimeConnection } = await import(pathToFileURL(process.env.COPILOT_SDK_PATH).href);
const client = new CopilotClient({
    connection: RuntimeConnection.forStdio({ path: process.env.COPILOT_RUNTIME_PATH,
        args: ["--no-auto-update", "--disable-builtin-mcps", "--no-custom-instructions",
            "--allow-tool=extension-permission-access(user:roster-routing)"] }),
    env: environment, baseDirectory: home, workingDirectory: run, useLoggedInUser: false,
});
let session;
let originalHookCalls = 0;
let permissionRequests = 0;
let externalToolCalls = 0;
let accept = true;
async function bounded(promise) {
    let timer;
    try {
        return await Promise.race([promise, new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error("Proof operation exceeded 30 seconds")), 30000);
        })]);
    } finally { clearTimeout(timer); }
}
async function command(name, args) {
    const result = await bounded(session.rpc.commands.execute({ commandName: name, args }));
    assert(!result.error, result.error);
}
try {
    await bounded(client.start());
    results.push({ step: "runtime", status: await client.getStatus() });
    const settings = await client.rpc.user.settings.get();
    results.push({ step: "extension-setting-metadata",
        settings: Object.fromEntries(Object.entries(settings.settings).filter(([key]) => /extension/i.test(key))) });
    assert.equal((await client.rpc.extensions.discover()).mode, "load_only");
    session = await bounded(client.createSession({
        model: "seed/mock", providers: [{ name: "seed", type: "openai", baseUrl: `${url}/seed/v1` }],
        models: [{ provider: "seed", id: "mock", wireModel: "seed-wire", maxPromptTokens: 24576,
            maxContextWindowTokens: 32768, maxOutputTokens: 256 }],
        tools: [{ name: "proof_edit", description: "Synthetic tool, never writes files",
            parameters: { type: "object", properties: {} },
            handler: () => { externalToolCalls++; return "unexpected execution"; } }],
        availableTools: ["proof_edit", "task"],
        requestExtensions: true, enableExperimentalMode: true, enableConfigDiscovery: true,
        configDirectory: home, workingDirectory: run, enableManagedSettings: false,
        enableHostGitOperations: false, skipCustomInstructions: true, enableSessionStore: false,
        hooks: { onPreToolUse: async () => { originalHookCalls++; } },
        onPermissionRequest: async request => {
            permissionRequests++;
            results.push({ step: "synthetic-permission-request", request });
            if ((request.kind === "extension-permission-access") &&
                (request.extensionName === "user:roster-routing") &&
                (request.capabilities.length === 1) && (request.capabilities[0] === "register hooks")) {
                return { kind: "approve-once" };
            }
            if ((request.kind === "extension-env-access") &&
                (request.extensionName === "user:roster-routing") &&
                (request.environmentVariables.length === 1) &&
                (request.environmentVariables[0] === "OPENAI_API_KEY") &&
                (process.env.ROSTER_DENY_CREDENTIAL !== "1")) {
                return { kind: "approve-once" };
            }
            return { kind: "reject" };
        },
        onElicitationRequest: async () => ({ action: "accept", content: { confirmed: accept } }),
    }));
    session.on("session.error", event => errors.push(event.data));
    const id = session.sessionId;
    await bounded(session.sendAndWait({ prompt: "Remember synthetic marker ROSTER-PROOF-ALPHA." }, 30000));
    if (process.env.ROSTER_DENY_CREDENTIAL === "1") {
        const failedCommand = await bounded(session.rpc.commands.execute({ commandName: "local", args: "local-wire" }));
        assert(failedCommand.error);
        assert.equal((await session.rpc.model.getCurrent()).modelId, "seed/mock");
        assert(requests.every(request => request.model === "seed-wire"));
        await bounded(session.rpc.tools.execute({ name: "proof_edit", arguments: {} }));
        assert.equal(externalToolCalls, 0);
        assert(originalHookCalls > 0);
        results.push({ step: "denied-credential-access-preserves-session-default-permissions-and-history" });
    } else {
    const managedModels = new Map();
    for (const [name, args, wire] of [["local", "local-wire", "local-wire"], ["server", "active", "server-wire"],
        ["cloud", "chat-service org/model", "chat-wire"], ["cloud", "messages-service org/model", "messages-wire"],
        ["cloud", "openrouter dynamic/model", "dynamic/model"]]) {
        await command(name, args);
        managedModels.set(wire, (await session.rpc.model.getCurrent()).modelId);
        await bounded(session.sendAndWait({ prompt: `Synthetic turn for ${name}. No tools.` }, 30000));
        assert.equal(session.sessionId, id);
        assert.equal(requests.at(-1).model, wire);
        assert(requests.at(-1).marker);
        assert.equal(requests.at(-1).maxTokens, name === "local" ? 8192 : 256);
        if (wire === "dynamic/model") {
            assert.deepEqual(requests.at(-1).providerPolicy, {
                allow_fallbacks: false, require_parameters: true,
            });
        }
        results.push({ step: `switch-${wire}`, sameSession: true, history: true, outputCap: requests.at(-1).maxTokens });
    }
    const prior = (await session.rpc.model.getCurrent()).modelId;
    accept = false;
    await command("cloud", "chat-service org/model");
    assert.equal((await session.rpc.model.getCurrent()).modelId, prior);
    accept = true;
    const refusedCredential = await bounded(session.rpc.commands.execute({ commandName: "cloud", args: "missing-key-service org/model" }));
    assert(refusedCredential.error);
    assert.equal((await session.rpc.model.getCurrent()).modelId, prior);
    await command("cloud", "credential-service org/model");
    managedModels.set("credential-wire", (await session.rpc.model.getCurrent()).modelId);
    await bounded(session.sendAndWait({ prompt: "Synthetic granted credential turn. No tools." }, 30000));
    assert(requests.at(-1).syntheticCredential);
    results.push({ step: "missing-credential-preserves-route-and-approved-synthetic-key-routes-correctly" });
    const before = requests.length;
    const denied = await session.rpc.tools.execute({ name: "proof_edit", arguments: {} });
    assert.equal(externalToolCalls, 0);
    assert(permissionRequests > 0);
    assert(originalHookCalls > 0);
    results.push({ step: "original-permission-and-hook-preserved", denied, permissionRequests, originalHookCalls });
    const delegation = await session.rpc.tools.execute({ name: "task", arguments: {
        name: "explore", agent_type: "explore", description: "Synthetic managed task",
        prompt: "Return a short synthetic result.", model: "seed/mock",
    } });
    assert(requests.length > before);
    assert(requests.slice(before).every(request => request.model === "credential-wire"));
    results.push({ step: "managed-delegation-pinned-to-active-route", delegation,
        requests: requests.length - before });
    const crossProviderStart = requests.length;
    const crossProvider = await session.rpc.tools.execute({ name: "task", arguments: {
        name: "explore", agent_type: "explore", description: "Synthetic approved local task",
        prompt: "Return a short synthetic result.", model: managedModels.get("local-wire"),
    } });
    assert(requests.length > crossProviderStart);
    assert(requests.slice(crossProviderStart).every(request => request.model === "local-wire"));
    const grantedStart = requests.length;
    const granted = await session.rpc.tools.execute({ name: "task", arguments: {
        name: "explore", agent_type: "explore", description: "Synthetic persisted local grant",
        prompt: "Return a short synthetic result.",
    } });
    assert(requests.length > grantedStart);
    assert(requests.slice(grantedStart).every(request => request.model === "local-wire"));
    results.push({ step: "approved-cross-provider-grant-persists-until-route-change",
        crossProvider, granted });
    await session.setModel("seed/mock");
    await new Promise(resolve => setTimeout(resolve, 100));
    const standardStart = requests.length;
    const standardDelegation = await session.rpc.tools.execute({ name: "task", arguments: {
        name: "explore", agent_type: "explore", description: "Synthetic standard task",
        prompt: "Return a short synthetic result.",
    } });
    assert(requests.length > standardStart);
    assert(requests.slice(standardStart).every(request => request.model === "seed-wire"));
    results.push({ step: "standard-model-restores-default-subagent-inheritance", standardDelegation,
        requests: requests.length - standardStart });
    await bounded(session.rpc.extensions.reload());
    await new Promise(resolve => setTimeout(resolve, 300));
    await command("local", "local-wire");
    await bounded(session.sendAndWait({ prompt: "Synthetic post-reload turn." }, 30000));
    assert.equal(requests.at(-1).model, "local-wire");
    const list = await session.rpc.model.list();
    assert(list.list.some(model => model.id === "seed/mock"));
    assert.equal(list.list.filter(model => model.id.startsWith("roster-")).length, 1);
    results.push({ step: "reload-preserves-unrelated-model-and-withdraws-stale-owned-models" });
    failing = true;
    const failureStart = requests.length;
    await assert.rejects(bounded(session.sendAndWait({ prompt: "Synthetic deliberate failure." }, 30000)));
    assert(requests.slice(failureStart).every(request => request.model === "local-wire"));
    assert(errors.length > 0);
    results.push({ step: "failure-no-fallback", requests: requests.length - failureStart, errors });
    failing = false;
    const nativeHome = join(run, "native-home");
    await install(nativeHome, { ...configuration, services: [] });
    const native = await bounded(new Promise((resolve, reject) => {
        const child = spawn(process.env.COPILOT_RUNTIME_PATH, [
            "--no-auto-update", "--disable-builtin-mcps", "--no-custom-instructions",
            "--allow-tool=extension-permission-access(user:roster-routing)",
            "-p", "Synthetic native-launch proof. Reply briefly without tools.",
        ], { cwd: run, env: { ...environment, COPILOT_HOME: nativeHome }, stdio: ["ignore", "pipe", "pipe"] });
        let stdout = "", stderr = "";
        const timer = setTimeout(() => { child.kill(); reject(new Error("Owned native launch timed out")); }, 25000);
        child.stdout.on("data", data => { stdout += data; });
        child.stderr.on("data", data => { stderr += data; });
        child.once("error", error => { clearTimeout(timer); reject(error); });
        child.once("close", code => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
    }));
    assert.equal(native.code, 0, native.stderr);
    assert(native.stdout.includes("Synthetic seed-wire response"));
    results.push({ step: "native-launch-with-persistent-experimental-setting-no-wrapper", native });
    }
} catch (error) {
    results.push({ step: "unexpected-failure", error: error?.stack ?? String(error), errors });
    process.exitCode = 1;
} finally {
    await writeFile(join(run, "result.json"), JSON.stringify({ results, requests }, null, 2));
    if (session) await bounded(session.disconnect()).catch(error => results.push({ step: "disconnect-error", error: String(error) }));
    await bounded(client.stop()).catch(async error => {
        results.push({ step: "stop-error", error: String(error) });
        await client.forceStop();
    });
    mock.closeAllConnections();
    await new Promise(resolve => mock.close(resolve));
    await writeFile(join(run, "result.json"), JSON.stringify({ results, requests }, null, 2));
    console.log(JSON.stringify({ run, results }, null, 2));
}
