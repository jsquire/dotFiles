import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { budgets, endpoint, localBudgets, localEntries, ollamaContext, openRouterEntries, openRouterService,
    serverEntries, validateConfig } from "../config.mjs";
import { createGateway } from "../gateway.mjs";
import { gitGuard, Router } from "../router.mjs";
import { ensure, install, rollback, upgrade } from "../deploy.mjs";

const root = process.env.ROSTER_TEST_ROOT;
assert(root, "Set ROSTER_TEST_ROOT to an isolated session artifact directory");
await mkdir(root, { recursive: true });
const config = () => ({ schemaVersion: 1, services: [], timeoutMs: 1000 });
const model = () => ({ id: "org/model", maxPromptTokens: 24576, maxContextWindowTokens: 32768, maxOutputTokens: 256 });
const service = () => ({ id: "arbitrary-service", api: "openai-chat", baseUrl: "https://service.example/v1", models: [model()] });
const openRouterCatalog = () => ({ data: [
    {
        id: "preferred/model",
        name: "Preferred Model",
        context_length: 1000000,
        architecture: { output_modalities: ["text"] },
        pricing: { prompt: "0.000002", completion: "0.00001" },
        supported_parameters: ["tools", "max_tokens"],
        top_provider: { max_completion_tokens: 128000 },
        expiration_date: null,
    },
    {
        id: "chat-only/model",
        name: "Chat Only",
        context_length: 32768,
        architecture: { output_modalities: ["text"] },
        pricing: { prompt: "0", completion: "0" },
        supported_parameters: ["max_tokens"],
        top_provider: { max_completion_tokens: 4096 },
        expiration_date: null,
    },
] });
test("local budget policy retains explicit known ceilings", () => {
    assert.deepEqual(localBudgets(32768), { maxPromptTokens: 24576, maxContextWindowTokens: 32768, maxOutputTokens: 8192 });
    assert.deepEqual(localBudgets(196608), { maxPromptTokens: 147456, maxContextWindowTokens: 196608, maxOutputTokens: 16384 });
});

test("reject invalid and overcommitted budgets", () => {
    for (const values of [[0, 32768, 256], [32768, 32768, 256], [1.5, 32768, 256]]) {
        assert.throws(() => budgets(...values));
    }
});

test("third-party services support both API families without vendor hardcoding", () => {
    for (const api of ["openai-chat", "anthropic-messages"]) {
        const value = validateConfig({ ...config(), services: [{ ...service(), api }] });
        assert.equal(value.services[0].id, "arbitrary-service");
        assert.equal(value.services[0].api, api);
    }
});

test("OpenRouter configuration uses full-catalog discovery and strict request policy", () => {
    const service = openRouterService();
    const value = validateConfig({ ...config(), services: [service] });
    assert.equal(value.services[0].models.length, 0);
    assert.equal(value.services[0].discovery.kind, "openrouter");
    assert.equal(value.services[0].requestBody.provider.allow_fallbacks, false);
    assert.equal(value.services[0].requestBody.provider.require_parameters, true);
    assert.equal(value.services[0].requestBody.provider.data_collection, "deny");
    assert.equal(value.services[0].requestBody.provider.zdr, true);
});

test("service requires exactly one static or dynamic catalog source", () => {
    const dynamic = openRouterService();
    assert.throws(() => validateConfig({ ...config(), services: [{ ...dynamic, models: [model()] }] }));
    assert.throws(() => validateConfig({ ...config(), services: [{ ...service(), models: [] }] }));
});

test("OpenRouter discovery highlights preferences without hiding incompatible models", () => {
    const discovery = {
        preferredModels: ["preferred/model"],
        maxContextWindowTokens: 262144,
        maxOutputTokens: 32768,
        defaultMaxOutputTokens: 8192,
    };
    const entries = openRouterEntries(openRouterCatalog(), discovery);
    assert.deepEqual(entries.map(entry => entry.id), ["preferred/model", "chat-only/model"]);
    assert.equal(entries[0].preferred, true);
    assert.equal(entries[0].available, true);
    assert.equal(entries[0].maxContextWindowTokens, 262144);
    assert.equal(entries[0].maxOutputTokens, 32768);
    assert.match(entries[0].label, /\[preferred\].*\$2\/\$10 per MTok.*1M.*tools/);
    assert.equal(entries[1].available, false);
    assert.equal(entries[1].unavailableReason, "does not support tools");
    assert.match(entries[1].label, /unavailable: does not support tools/);
});

test("reject unsupported APIs, inline auth, duplicate models and invalid registry", () => {
    for (const candidate of [
        { ...service(), api: "openai-responses" },
        { ...service(), apiKey: "synthetic-inline-key" },
        { ...service(), headers: { Authorization: "not-a-real-key" } },
        { ...service(), credential: { env: "bad-name", kind: "api-key" } },
        { ...service(), models: [model(), model()] },
        { ...service(), requestBody: { models: ["fallback"] } },
    ]) assert.throws(() => validateConfig({ ...config(), services: [candidate] }));
});

test("URLs reject embedded credentials and insecure third-party destinations", () => {
    for (const url of ["https://user:pass@example.com/v1", "https://example.com/v1?key=x", "ftp://example.com", "http://example.com/v1"]) {
        assert.throws(() => endpoint(url, "test", true));
    }
    assert.equal(endpoint("http://127.0.0.1:1234/v1/", "test", true), "http://127.0.0.1:1234/v1");
});

test("Ollama discovery excludes hosted models and derives configured context", () => {
    const installed = { models: [
        { name: "mock:latest", details: { parameter_size: "8B", quantization_level: "Q4_K_M" } },
        { name: "remote", remote_host: "https://host.example" },
    ] };
    const entries = localEntries(installed, new Map([["mock:latest", {
        parameters: "temperature 0.7\nnum_ctx 65536",
        model_info: { "general.architecture": "mock", "mock.context_length": 131072 },
    }]]));
    assert.equal(entries.length, 1);
    assert.equal(entries[0].id, "mock:latest");
    assert.equal(entries[0].maxContextWindowTokens, 65536);
    assert.match(entries[0].label, /8B.*Q4_K_M/);
});

test("Ollama context falls back to architecture metadata", () => {
    assert.equal(ollamaContext({
        parameters: "temperature 0.7",
        model_info: { "general.architecture": "mock", "mock.context_length": 32768 },
    }), 32768);
    assert.throws(() => ollamaContext({ model_info: { "general.architecture": "mock" } }));
});

test("canonical server roster parses with the routing core", async () => {
    const server = JSON.parse(await readFile(new URL("../../../cachyos/server-models.json", import.meta.url), "utf8"));
    assert(serverEntries(server).length > 3);
});

async function mockUpstream(t, handler) {
    const calls = [];
    const server = createServer(async (req, res) => {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        calls.push({ path: req.url, body, auth: req.headers.authorization, key: req.headers["x-api-key"] });
        handler(req, res, body);
    });
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    t.after(() => { server.closeAllConnections(); return new Promise(resolve => server.close(resolve)); });
    return { calls, baseUrl: `http://127.0.0.1:${server.address().port}/v1` };
}

async function gatewayFixture(t, api = "openai-chat", handler = (_req, res, body) => {
    res.setHeader("content-type", "application/json"); res.end(JSON.stringify({ model: body.model }));
}) {
    const upstream = await mockUpstream(t, handler);
    const gateway = await createGateway({ timeoutMs: 1000 });
    t.after(() => gateway.close());
    const connection = gateway.add("selected", { ...upstream, api, wireModel: "wire", maxOutputTokens: 256,
        credential: "synthetic-credential", requestBody: { provider: { only: ["chosen-upstream"], allow_fallbacks: false } } });
    const send = (body, key = connection.apiKey) => fetch(`${connection.baseUrl}/${api === "openai-chat" ? "chat/completions" : "messages"}`, {
        method: "POST", headers: { authorization: `Bearer ${key}` }, body: JSON.stringify({ model: "wire", messages: [], ...body }),
    });
    return { ...upstream, send };
}

test("OpenAI gateway injects and clamps output caps and explicit upstream policy", async t => {
    const fixture = await gatewayFixture(t);
    for (const max_tokens of [undefined, 1000, 32]) {
        const response = await fixture.send({ max_tokens });
        assert.equal(response.status, 200);
    }
    assert.deepEqual(fixture.calls.map(call => call.body.max_tokens), [256, 256, 32]);
    assert(fixture.calls.every(call => call.auth === "Bearer synthetic-credential"));
    assert.equal(fixture.calls[0].body.provider.allow_fallbacks, false);
});

test("Anthropic gateway uses Messages path, x-api-key and mandatory max_tokens", async t => {
    const fixture = await gatewayFixture(t, "anthropic-messages");
    assert.equal((await fixture.send({})).status, 200);
    assert.equal(fixture.calls[0].path, "/v1/messages");
    assert.equal(fixture.calls[0].key, "synthetic-credential");
    assert.equal(fixture.calls[0].body.max_tokens, 256);
});

test("gateway rejects wrong auth, model and model-fallback list without upstream traffic", async t => {
    const fixture = await gatewayFixture(t);
    const responses = [
        await fixture.send({}, "incorrect"),
        await fixture.send({ model: "other" }),
        await fixture.send({ models: ["wire", "other"] }),
    ];
    assert.deepEqual(responses.map(response => response.status), [401, 403, 400]);
    assert.equal(fixture.calls.length, 0);
});

test("streaming passes through unchanged and still caps output", async t => {
    const fixture = await gatewayFixture(t, "openai-chat", (_req, res) => {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.end("data: {\"choices\":[]}\n\ndata: [DONE]\n\n");
    });
    const response = await fixture.send({ stream: true });
    assert.equal(await response.text(), "data: {\"choices\":[]}\n\ndata: [DONE]\n\n");
    assert.equal(fixture.calls[0].body.max_tokens, 256);
});

test("provider failures remain failures and never retry another service", async t => {
    const fixture = await gatewayFixture(t, "openai-chat", (_req, res) => {
        res.writeHead(503); res.end('{"error":{"message":"deliberate failure"}}');
    });
    assert.equal((await fixture.send({})).status, 503);
    assert.equal(fixture.calls.length, 1);
});

    test("alternate output parameter respects the smallest requested ceiling and preserves tool messages", async t => {
        const upstream = await mockUpstream(t, (_req, res) => res.end("{}"));
        const gateway = await createGateway();
        t.after(() => gateway.close());
        const connection = gateway.add("alternate", { api: "openai-chat", baseUrl: upstream.baseUrl,
            wireModel: "wire", maxOutputTokens: 256, outputParameter: "max_completion_tokens" });
        const messages = [{ role: "assistant", content: null, tool_calls: [{ id: "tool", type: "function",
            function: { name: "synthetic", arguments: "{}" } }] }, { role: "tool", tool_call_id: "tool", content: "result" }];
        const response = await fetch(`${connection.baseUrl}/chat/completions`, { method: "POST",
            headers: { authorization: `Bearer ${connection.apiKey}` },
            body: JSON.stringify({ model: "wire", messages, max_tokens: 32, max_completion_tokens: 64 }) });
        assert.equal(response.status, 200);
        assert.equal(upstream.calls[0].body.max_completion_tokens, 32);
        assert.equal(upstream.calls[0].body.max_tokens, undefined);
        assert.deepEqual(upstream.calls[0].body.messages, messages);
    });

    test("Messages tool-use and tool-result blocks are not rewritten by the gateway", async t => {
        const fixture = await gatewayFixture(t, "anthropic-messages");
        const messages = [{ role: "assistant", content: [{ type: "tool_use", id: "tool", name: "synthetic", input: {} }] },
            { role: "user", content: [{ type: "tool_result", tool_use_id: "tool", content: "result" }] }];
        assert.equal((await fixture.send({ messages })).status, 200);
        assert.deepEqual(fixture.calls[0].body.messages, messages);
    });

    test("rollback preserves concurrent extension settings while removing only its mode override", async () => {
        const home = await mkdtemp(join(root, "mode-recovery-"));
        await writeFile(join(home, "settings.json"), '{"experimental":true,"extensions":{"mode":"load_and_augment","enabled":["existing"]}}');
        const installed = await install(home, config());
        const current = await readFile(join(home, "settings.json"), "utf8");
        await writeFile(join(home, "settings.json"), current.replace('"existing"', '"user-changed"'));
        await rollback(installed.manifestPath);
        const restored = JSON.parse(await readFile(join(home, "settings.json"), "utf8"));
        assert.equal(restored.extensions.mode, "load_and_augment");
        assert.deepEqual(restored.extensions.enabled, ["user-changed"]);
    });
function fakeSession() {
    const state = { current: "copilot-default", list: [], calls: [], active: false, picks: [], confirm: true };
    const session = {
        capabilities: { ui: { elicitation: true } },
        ui: { select: async () => state.picks.shift() ?? null, confirm: async () => state.confirm },
        log: async message => state.calls.push({ log: message }),
        setModel: async id => { state.current = id; state.calls.push({ model: id }); },
        rpc: {
            metadata: { activity: async () => ({ hasActiveWork: state.active }) },
            model: { getCurrent: async () => ({ modelId: state.current }), list: async () => ({ list: state.list }) },
            provider: {
                add: async params => {
                    state.calls.push({ add: params });
                    state.list.push(...params.models.map(model => ({ id: `${model.provider}/${model.id}` })));
                },
                withdraw: async ({ models }) => {
                    state.calls.push({ withdraw: models });
                    state.list = state.list.filter(entry => !models.includes(entry.id));
                },
            },
        },
    };
    return { session, state };
}

test("cancelled selection leaves model and registry untouched", async () => {
    const { session, state } = fakeSession();
    const router = new Router(session, validateConfig({ ...config(), services: [service()] }));
    await router.command("cloud", "");
    assert.equal(state.current, "copilot-default");
    assert.equal(state.list.length, 0);
});

test("cloud history-transfer rejection and missing credentials do not register or switch", async () => {
    const { session, state } = fakeSession();
    const router = new Router(session, validateConfig({ ...config(), services: [
        { ...service(), credential: { env: "SYNTHETIC_KEY", kind: "api-key" } },
    ] }), { environment: {} });
    state.confirm = false;
    await router.command("cloud", "arbitrary-service org/model");
    state.confirm = true;
    await assert.rejects(router.command("cloud", "arbitrary-service org/model"), /Credential access/);
    assert.equal(state.list.length, 0);
    assert.equal(state.current, "copilot-default");
});

test("dynamic OpenRouter selection discovers and registers a compatible live catalog entry", async t => {
    const { session, state } = fakeSession();
    const configured = openRouterService();
    configured.baseUrl = "http://127.0.0.1:1/v1";
    configured.discovery.url = "http://127.0.0.1:1/models";
    delete configured.credential;
    const calls = [];
    const router = new Router(session, validateConfig({ ...config(), services: [configured] }), {
        fetchImpl: async url => {
            calls.push(url);
            return Response.json(openRouterCatalog());
        },
    });
    t.after(() => router.close());
    await router.command("cloud", "openrouter preferred/model");
    assert.deepEqual(calls, ["http://127.0.0.1:1/models"]);
    assert.match(state.current, /preferred\/model$/);
    const registration = state.calls.find(call => call.add).add;
    assert.equal(registration.models[0].wireModel, "preferred/model");
    assert.equal(registration.models[0].maxContextWindowTokens, 1000000);
    assert.equal(registration.models[0].maxOutputTokens, 128000);
});

test("dynamic OpenRouter selection explains incompatible catalog entries", async () => {
    const { session, state } = fakeSession();
    const configured = openRouterService();
    configured.baseUrl = "http://127.0.0.1:1/v1";
    configured.discovery.url = "http://127.0.0.1:1/models";
    delete configured.credential;
    const router = new Router(session, validateConfig({ ...config(), services: [configured] }), {
        fetchImpl: async () => Response.json(openRouterCatalog()),
    });
    await assert.rejects(router.command("cloud", "openrouter chat-only/model"), /does not support tools/);
    assert.equal(state.current, "copilot-default");
    assert.equal(state.list.length, 0);
});

test("busy foreground/background work prevents routing before any provider registration", async () => {
    const { session, state } = fakeSession();
    state.active = true;
    const router = new Router(session, validateConfig({ ...config(), services: [service()] }));
    await assert.rejects(router.command("cloud", "arbitrary-service org/model"), /finish/);
    assert.equal(state.list.length, 0);
});

test("registration is reused and stale withdrawal is scoped to owned model IDs", async t => {
    const { session, state } = fakeSession();
    state.list.push({ id: "unrelated/model" }, { id: "roster-cloud-abcdef-old/model" });
    const router = new Router(session, validateConfig({ ...config(), services: [service()] }));
    t.after(() => router.close());
    await router.command("cloud", "arbitrary-service org/model");
    const first = state.current;
    await router.command("cloud", "arbitrary-service org/model");
    assert.equal(state.current, first);
    assert.equal(state.calls.filter(call => call.add).length, 1);
    assert(state.list.some(entry => entry.id === "unrelated/model"));
    assert.deepEqual(state.calls.find(call => call.withdraw).withdraw, ["roster-cloud-abcdef-old/model"]);
});

test("BYOK guards deny delegation/image tools without granting other tools", async () => {
    const { session, state } = fakeSession();
    state.current = "roster-local-abcdef-model/mock";
    const router = new Router(session, config());
    assert.equal((await router.guard({ toolName: "task" })).permissionDecision, "deny");
    assert.equal((await router.guard({ toolName: "functions.write_agent" })).permissionDecision, "deny");
    assert.equal((await router.guard({ toolName: "imagegen-mcp-generate_image" })).permissionDecision, "deny");
    assert.equal(await router.guard({ toolName: "write" }), undefined);
    state.current = "copilot-default";
    assert.equal(await router.guard({ toolName: "task" }), undefined);
});

test("Git trial hook denies legacy mutation patterns without executing commands", () => {
    for (const command of ["git commit -m test", "git push", "git.exe rebase main"]) {
        assert.equal(gitGuard({ toolName: "powershell", toolArgs: { command } }).permissionDecision, "deny");
    }
    assert.equal(gitGuard({ toolName: "powershell", toolArgs: { command: "Get-ChildItem" } }), undefined);
});

test("deployment/rollback preserve JSONC comments, concurrent keys and session files", async () => {
    const home = await mkdtemp(join(root, "recovery-"));
    const original = '{\n  // retain comment\n  "experimental": false,\n  "model": "existing"\n}\n';
    await writeFile(join(home, "settings.json"), original);
    await mkdir(join(home, "session-state", "existing"), { recursive: true });
    await writeFile(join(home, "session-state", "existing", "sentinel"), "untouched");
    const installed = await install(home, config());
    const deployed = await readFile(join(home, "settings.json"), "utf8");
    assert(deployed.includes("// retain comment"));
    await writeFile(join(home, "settings.json"), deployed.replace('"model": "existing"', '"model": "changed-by-user"'));
    await rollback(installed.manifestPath);
    const restored = await readFile(join(home, "settings.json"), "utf8");
    assert(restored.includes('"experimental": false'));
    assert(restored.includes('"model": "changed-by-user"'));
    assert.equal(await readFile(join(home, "session-state", "existing", "sentinel"), "utf8"), "untouched");
    assert((await readFile(join(dirnameOf(installed.manifestPath), "disabled-extension", "extension.mjs"), "utf8")).includes("joinSession"));
});

test("managed upgrade replaces configuration and remains fully reversible", async () => {
    const home = await mkdtemp(join(root, "upgrade-"));
    const installed = await install(home, config());
    const next = { ...config(), services: [openRouterService()] };
    const upgraded = await upgrade(home, next, { reason: "Synthetic OpenRouter upgrade" });
    assert.equal(upgraded.manifestPath, installed.manifestPath);
    assert.deepEqual(JSON.parse(await readFile(join(home, "roster-routing.json"), "utf8")), next);
    const manifest = JSON.parse(await readFile(installed.manifestPath, "utf8"));
    assert(manifest.adjustments.some(entry => entry.module === "roster-routing.json"));
    await rollback(installed.manifestPath);
    await assert.rejects(readFile(join(home, "roster-routing.json"), "utf8"), error => error.code === "ENOENT");
});

test("ensure installs once and then upgrades the matching managed deployment", async () => {
    const home = await mkdtemp(join(root, "ensure-"));
    const first = await ensure(home, config());
    assert.equal(first.upgraded, undefined);
    const next = { ...config(), services: [openRouterService()] };
    const second = await ensure(home, next);
    assert.equal(second.upgraded, true);
    assert.equal(second.manifestPath, first.manifestPath);
    const manifestBefore = await readFile(first.manifestPath, "utf8");
    const third = await ensure(home, next);
    assert.equal(third.upgraded, false);
    assert.equal(await readFile(first.manifestPath, "utf8"), manifestBefore);
    await rollback(first.manifestPath);
});

test("ensure recovers a partially applied managed upgrade before retrying", async () => {
    const home = await mkdtemp(join(root, "upgrade-recovery-"));
    const installed = await install(home, config());
    const manifest = JSON.parse(await readFile(installed.manifestPath, "utf8"));
    const recovery = dirnameOf(installed.manifestPath);
    const moduleName = "config.mjs";
    const modulePath = join(home, "extensions", "roster-routing", moduleName);
    const configPath = join(home, "roster-routing.json");
    const previousModule = await readFile(modulePath);
    const previousConfig = await readFile(configPath);
    const nextModule = Buffer.from("synthetic interrupted module");
    const nextConfig = Buffer.from('{"schemaVersion":1,"services":[{"id":"interrupted"}]}\n');
    const moduleBackup = join(recovery, "interrupted-module-backup");
    const configBackup = join(recovery, "interrupted-config-backup");
    await writeFile(moduleBackup, previousModule);
    await writeFile(configBackup, previousConfig);
    await writeFile(modulePath, nextModule);
    await writeFile(configPath, nextConfig);
    manifest.pendingUpgrade = {
        reason: "Synthetic interrupted upgrade",
        previousFiles: { ...manifest.files },
        previousConfigHash: manifest.configHash,
        modules: {
            [moduleName]: {
                previousHash: manifest.files[moduleName],
                newHash: createHash("sha256").update(nextModule).digest("hex"),
                backup: moduleBackup,
            },
        },
        config: {
            previousHash: manifest.configHash,
            newHash: createHash("sha256").update(nextConfig).digest("hex"),
            backup: configBackup,
        },
    };
    await writeFile(installed.manifestPath, JSON.stringify(manifest, null, 2));

    const next = { ...config(), services: [openRouterService()] };
    const upgraded = await ensure(home, next);
    assert.equal(upgraded.upgraded, true);
    assert.deepEqual(JSON.parse(await readFile(configPath, "utf8")), next);
    const recoveredManifest = JSON.parse(await readFile(installed.manifestPath, "utf8"));
    assert.equal(recoveredManifest.pendingUpgrade, undefined);
    await rollback(installed.manifestPath);
});

function dirnameOf(path) { return join(path, ".."); }

test("a crash journal with write intents but no writes rolls back without data loss", async () => {
    const home = await mkdtemp(join(root, "crash-intent-"));
    const journal = join(home, "roster-routing-recovery", "owned");
    await mkdir(journal, { recursive: true });
    const manifestPath = join(journal, "manifest.json");
    await writeFile(manifestPath, JSON.stringify({ schemaVersion: 1, home, state: "preparing", files: {},
        configWritten: true, extensionWritten: true, settingWritten: true, originalSettingPresent: false }));
    await rollback(manifestPath);
    assert.equal(JSON.parse(await readFile(manifestPath, "utf8")).state, "rolled-back");
});

test("a different server mode never invokes the shared switch endpoint", async () => {
    const { session } = fakeSession();
    const calls = [];
    const server = { schema_version: 2, modes: [{ mode: "wanted", label: "Wanted", model_id: "wire",
        ctx: 32768, max_prompt: 24576, max_output: 256, imagegen_disabled: true }] };
    const router = new Router(session, { ...config(), server: { controlUrl: "http://fake", baseUrl: "http://fake/v1" } }, {
        fetchImpl: async (url, options) => {
            calls.push({ url, method: options.method });
            return Response.json(url.endsWith("/models") ? server : { mode: "other", api_up: true });
        },
    });
    await assert.rejects(router.command("server", "wanted"), /coordinated ownership/);
    assert(calls.every(call => call.method === undefined));
});

test("router concurrency rejects the second command rather than racing switches", async () => {
    const { session } = fakeSession();
    let finish;
    session.ui.select = () => new Promise(resolve => { finish = resolve; });
    const router = new Router(session, validateConfig({ ...config(), services: [service()] }));
    const first = router.command("cloud", "");
    await new Promise(resolve => setImmediate(resolve));
    await assert.rejects(router.command("cloud", ""), /already in progress/);
    finish(null);
    await first;
});

test("credentials are consumed only after destination confirmation", async t => {
    const { session, state } = fakeSession();
    const names = [];
    const router = new Router(session, validateConfig({ ...config(), services: [
        { ...service(), credential: { env: "SYNTHETIC_KEY", kind: "api-key" } },
    ] }), { credentialLoader: async name => { names.push(name); return "synthetic"; } });
    t.after(() => router.close());
    state.confirm = false;
    await router.command("cloud", "arbitrary-service org/model");
    assert.deepEqual(names, []);
    state.confirm = true;
    await router.command("cloud", "arbitrary-service org/model");
    assert.deepEqual(names, ["SYNTHETIC_KEY"]);
});

test("conflicting user edits make rollback stop without overwriting any file", async () => {
    const home = await mkdtemp(join(root, "conflict-"));
    const installed = await install(home, config());
    await writeFile(join(installed.extension, "router.mjs"), "user-edited");
    const settingsBefore = await readFile(join(home, "settings.json"), "utf8");
    await assert.rejects(rollback(installed.manifestPath), /Rollback conflict/);
    assert.equal(await readFile(join(installed.extension, "router.mjs"), "utf8"), "user-edited");
    assert.equal(await readFile(join(home, "settings.json"), "utf8"), settingsBefore);
});

test("a stale lock is removed only after its exact owning process has exited", async () => {
    const home = await mkdtemp(join(root, "stale-lock-"));
    const child = spawn(process.execPath, ["-e", ""], { stdio: "ignore" });
    await new Promise((resolve, reject) => { child.once("close", resolve); child.once("error", reject); });
    await writeFile(join(home, "roster-routing-deployment.lock"), String(child.pid));
    const deployed = await install(home, config());
    await rollback(deployed.manifestPath);
});

test("a live deployment lock leaves settings and extension paths unchanged", async () => {
    const home = await mkdtemp(join(root, "live-lock-"));
    await writeFile(join(home, "roster-routing-deployment.lock"), String(process.pid));
    await assert.rejects(install(home, config()), /Another deployment process/);
    assert.equal(await readFile(join(home, "roster-routing-deployment.lock"), "utf8"), String(process.pid));
});
