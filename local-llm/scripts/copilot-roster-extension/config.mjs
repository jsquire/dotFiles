import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";

export function requireValue(condition, message) {
    if (!condition) throw new Error(message);
}

function fields(value, allowed, name) {
    requireValue(value && typeof value === "object" && !Array.isArray(value), `${name} must be an object`);
    for (const key of Object.keys(value)) {
        requireValue(allowed.includes(key), `Unsupported ${name} field ${key}`);
    }
}

export function endpoint(value, name, cloud = false) {
    requireValue(typeof value === "string", `${name} must be a URL`);
    const url = new URL(value);
    requireValue(["http:", "https:"].includes(url.protocol), `${name} must use HTTP or HTTPS`);
    requireValue(!url.username && !url.password && !url.search && !url.hash, `${name} cannot contain credentials, a query or a fragment`);
    if ((cloud) && (url.protocol === "http:")) {
        requireValue(["127.0.0.1", "localhost", "[::1]"].includes(url.hostname), `${name} must use HTTPS outside loopback`);
    }
    return url.href.replace(/\/$/, "");
}

export function budgets(prompt, context, output) {
    for (const [name, value] of Object.entries({ prompt, context, output })) {
        requireValue(Number.isSafeInteger(value) && value > 0, `${name} budget must be a positive integer`);
    }
    requireValue(prompt + output <= context, "Prompt and output budgets must fit the context window");
    return { maxPromptTokens: prompt, maxContextWindowTokens: context, maxOutputTokens: output };
}

export function localBudgets(context) {
    const prompt = Math.floor(context * 0.75);
    return budgets(prompt, context, Math.min(16384, context - prompt));
}

function positiveInteger(value, name) {
    requireValue(Number.isSafeInteger(value) && value > 0, `${name} must be a positive integer`);
    return value;
}

export function openRouterService() {
    return {
        id: "openrouter",
        label: "OpenRouter",
        api: "openai-chat",
        baseUrl: "https://openrouter.ai/api/v1",
        credential: { env: "OPENROUTER_API_KEY", kind: "bearer" },
        requestBody: {
            provider: {
                allow_fallbacks: false,
                require_parameters: true,
            },
        },
        discovery: {
            kind: "openrouter",
            url: "https://openrouter.ai/api/v1/models",
            preferredModels: [
                "anthropic/claude-opus-5.5",
                "anthropic/claude-sonnet-5.5",
                "moonshotai/kimi-k3",
                "moonshotai/kimi-k2.7-code",
                "moonshotai/kimi-k2.6",
                "qwen/qwen3.8-2.4t-a95b",
                "qwen/qwen3.8-max-0902",
            ],
            maxContextWindowTokens: 1048576,
            maxOutputTokens: 131072,
            defaultMaxOutputTokens: 16384,
        },
    };
}

export function validateConfig(input) {
    fields(input, ["schemaVersion", "local", "server", "services", "timeoutMs"], "configuration");
    requireValue(input?.schemaVersion === 1, "Unsupported routing configuration schema");
    requireValue(Array.isArray(input.services), "services must be an array");
    if ((input.local !== undefined) && (input.local !== null)) {
        fields(input.local, ["baseUrl", "discoveryUrl", "rosterPath"], "local");
    }
    if ((input.server !== undefined) && (input.server !== null)) {
        fields(input.server, ["baseUrl", "controlUrl", "rosterPath"], "server");
    }
    const local = input.local && {
        ...input.local,
        baseUrl: endpoint(input.local.baseUrl, "local.baseUrl"),
        discoveryUrl: endpoint(input.local.discoveryUrl, "local.discoveryUrl"),
    };
    if (local?.rosterPath !== undefined) requireValue(isAbsolute(local.rosterPath), "legacy local.rosterPath must be absolute");
    const server = input.server && {
        ...input.server,
        baseUrl: endpoint(input.server.baseUrl, "server.baseUrl"),
        controlUrl: endpoint(input.server.controlUrl, "server.controlUrl"),
    };
    if (server) requireValue(isAbsolute(server.rosterPath), "server.rosterPath must be absolute");
    const names = new Set();
    const services = input.services.map(service => {
        fields(service, ["id", "label", "api", "baseUrl", "credential", "headers", "requestBody", "models", "discovery"], "service");
        requireValue(/^[a-z][a-z0-9-]*$/.test(service.id), "Service id must be a lowercase identifier");
        requireValue(!names.has(service.id), `Duplicate service ${service.id}`);
        names.add(service.id);
        requireValue(["openai-chat", "anthropic-messages"].includes(service.api), `Unsupported API family for ${service.id}`);
        const baseUrl = endpoint(service.baseUrl, `${service.id}.baseUrl`, true);
        const headers = service.headers ?? {};
        requireValue(headers && typeof headers === "object" && !Array.isArray(headers), "headers must be an object");
        for (const [name, value] of Object.entries(headers)) {
            requireValue(typeof value === "string", `Header ${name} must be text`);
            requireValue(!/authorization|api.?key|token|secret|cookie/i.test(name), "Credentials must reference an environment variable, not inline headers");
        }
        const credential = service.credential;
        if (credential) {
            fields(credential, ["env", "kind", "header", "prefix"], "credential");
            requireValue(/^[A-Z_][A-Z0-9_]*$/.test(credential.env), "Credential env must name an environment variable");
            requireValue(["api-key", "bearer"].includes(credential.kind), "Unsupported credential kind");
            if (credential.header !== undefined) requireValue(/^[A-Za-z0-9-]+$/.test(credential.header), "Credential header must be an HTTP header name");
            if (credential.prefix !== undefined) requireValue(typeof credential.prefix === "string" && !/[\r\n]/.test(credential.prefix), "Credential prefix must be single-line text");
            if (service.api === "anthropic-messages") {
                requireValue(credential.kind === "api-key", "Anthropic Messages requires api-key authentication");
            }
        }
        const requestBody = service.requestBody ?? {};
        requireValue(requestBody && typeof requestBody === "object" && !Array.isArray(requestBody), "requestBody must be an object");
        for (const key of Object.keys(requestBody)) {
            requireValue(!["model", "models", "messages", "system", "tools", "tool_choice", "stream", "max_tokens", "max_completion_tokens"].includes(key),
                `requestBody cannot override ${key}`);
        }
        const discovery = service.discovery;
        if (discovery !== undefined) {
            fields(discovery, ["kind", "url", "preferredModels", "maxContextWindowTokens", "maxOutputTokens",
                "defaultMaxOutputTokens"], "discovery");
            requireValue(discovery.kind === "openrouter", `Unsupported discovery kind for ${service.id}`);
            requireValue(service.api === "openai-chat", "OpenRouter discovery requires OpenAI Chat");
            const preferredModels = discovery.preferredModels ?? [];
            requireValue(Array.isArray(preferredModels) &&
                preferredModels.every(id => typeof id === "string" && id.length > 0 && !/\s/.test(id)),
            "preferredModels must contain nonempty model IDs without whitespace");
            requireValue(new Set(preferredModels).size === preferredModels.length, "preferredModels contains duplicates");
            service = {
                ...service,
                discovery: {
                    ...discovery,
                    url: endpoint(discovery.url, `${service.id}.discovery.url`, true),
                    preferredModels,
                    maxContextWindowTokens: positiveInteger(discovery.maxContextWindowTokens, "discovery.maxContextWindowTokens"),
                    maxOutputTokens: positiveInteger(discovery.maxOutputTokens, "discovery.maxOutputTokens"),
                    defaultMaxOutputTokens: positiveInteger(discovery.defaultMaxOutputTokens, "discovery.defaultMaxOutputTokens"),
                },
            };
            requireValue(discovery.defaultMaxOutputTokens <= discovery.maxOutputTokens,
                "discovery.defaultMaxOutputTokens cannot exceed discovery.maxOutputTokens");
        }
        const configuredModels = service.models ?? [];
        requireValue(Array.isArray(configuredModels), `${service.id}.models must be an array`);
        requireValue((configuredModels.length > 0) !== Boolean(discovery),
            `${service.id} requires either a static model list or discovery`);
        const ids = new Set();
        const models = configuredModels.map(model => {
            fields(model, ["id", "label", "wireModel", "maxPromptTokens", "maxContextWindowTokens", "maxOutputTokens", "outputParameter"], "model");
            requireValue(typeof model.id === "string" && model.id.length > 0 && !/\s/.test(model.id), "Model id must be nonempty without whitespace");
            requireValue(!ids.has(model.id), `Duplicate model ${model.id}`);
            ids.add(model.id);
            requireValue(["max_tokens", "max_completion_tokens"].includes(model.outputParameter ?? "max_tokens"), "Unsupported output parameter");
            if (service.api === "anthropic-messages") {
                requireValue((model.outputParameter ?? "max_tokens") === "max_tokens", "Messages uses max_tokens");
            }
            requireValue(model.wireModel === undefined || (typeof model.wireModel === "string" && model.wireModel.length > 0), "wireModel must be nonempty text");
            return { ...model, ...budgets(model.maxPromptTokens, model.maxContextWindowTokens, model.maxOutputTokens) };
        });
        return { ...service, label: service.label ?? service.id, baseUrl, headers, requestBody, models };
    });
    const timeoutMs = input.timeoutMs ?? 180000;
    requireValue(Number.isSafeInteger(timeoutMs) && timeoutMs >= 1000 && timeoutMs <= 600000, "timeoutMs must be between 1000 and 600000");
    return { schemaVersion: 1, local, server, services, timeoutMs };
}

export async function loadConfig(home = process.env.COPILOT_HOME ?? join(homedir(), ".copilot")) {
    return validateConfig(JSON.parse(await readFile(join(home, "roster-routing.json"), "utf8")));
}

export function ollamaContext(details) {
    requireValue(details && typeof details === "object" && !Array.isArray(details), "Invalid Ollama model details");
    const configured = /^num_ctx\s+(\d+)$/m.exec(details.parameters ?? "")?.[1];
    if (configured) return Number(configured);
    const architecture = details.model_info?.["general.architecture"];
    const native = architecture && details.model_info?.[`${architecture}.context_length`];
    requireValue(Number.isSafeInteger(native) && native > 0, "Ollama did not report a usable context length");
    return native;
}

export function localEntries(installed, details) {
    requireValue(Array.isArray(installed.models), "Invalid Ollama discovery response");
    const entries = installed.models
        .filter(model => !model.remote_model && !model.remote_host)
        .map(model => {
            requireValue(typeof model.name === "string" && model.name.length > 0, "Ollama returned an invalid model name");
            const shown = details.get(model.name);
            requireValue(shown, `Ollama details are missing for ${model.name}`);
            const context = ollamaContext(shown);
            const parameterSize = shown.details?.parameter_size ?? model.details?.parameter_size;
            const quantization = shown.details?.quantization_level ?? model.details?.quantization_level;
            const suffix = [parameterSize, quantization].filter(Boolean).join(" / ");
            return {
                id: model.name,
                label: suffix ? `${model.name} (${suffix})` : model.name,
                wireModel: model.name,
                image: false,
                ...localBudgets(context),
            };
        });
    requireValue(new Set(entries.map(entry => entry.id)).size === entries.length, "Ollama returned duplicate model names");
    return entries.sort((left, right) => left.label.localeCompare(right.label));
}

export function serverEntries(roster) {
    requireValue(roster.schema_version === 2 && Array.isArray(roster.modes), "Invalid server roster");
    const entries = roster.modes.map(mode => ({
        id: mode.mode, label: mode.label, wireModel: mode.model_id, image: !mode.imagegen_disabled,
        ...budgets(mode.max_prompt, mode.ctx, mode.max_output),
    }));
    requireValue(new Set(entries.map(entry => entry.id)).size === entries.length, "Duplicate server modes");
    return entries;
}

function compactNumber(value) {
    if (value >= 1000000) return `${Number((value / 1000000).toFixed(2))}M`;
    if (value >= 1000) return `${Number((value / 1000).toFixed(1))}K`;
    return String(value);
}

function perMillion(value) {
    const price = Number(value) * 1000000;
    if (!Number.isFinite(price) || price < 0) return "?";
    return `$${Number(price.toFixed(4))}`;
}

export function openRouterEntries(catalog, discovery, now = Date.now()) {
    requireValue(catalog && typeof catalog === "object" && Array.isArray(catalog.data), "OpenRouter returned an invalid model list");
    const preferred = new Set(discovery.preferredModels);
    const entries = catalog.data.map(model => {
        requireValue(model && typeof model === "object" && typeof model.id === "string" &&
            model.id.length > 0 && !/\s/.test(model.id), "OpenRouter returned an invalid model ID");
        const outputs = model.architecture?.output_modalities;
        const parameters = model.supported_parameters;
        const context = model.context_length;
        const advertisedOutput = model.top_provider?.max_completion_tokens;
        const expiration = model.expiration_date ? Date.parse(model.expiration_date) : NaN;
        let unavailableReason;
        if (!Array.isArray(outputs) || !outputs.includes("text")) unavailableReason = "does not produce text";
        else if (!Array.isArray(parameters) || !parameters.includes("tools")) unavailableReason = "does not support tools";
        else if (!Number.isSafeInteger(context) || context <= 1) unavailableReason = "does not report a usable context window";
        else if (Number.isFinite(expiration) && expiration <= now) unavailableReason = "is expired";
        let dynamicBudgets;
        if (!unavailableReason) {
            const maxContextWindowTokens = Math.min(context, discovery.maxContextWindowTokens);
            const reported = Number.isSafeInteger(advertisedOutput) && advertisedOutput > 0
                ? advertisedOutput : discovery.defaultMaxOutputTokens;
            const maxOutputTokens = Math.min(reported, discovery.maxOutputTokens, maxContextWindowTokens - 1);
            dynamicBudgets = budgets(maxContextWindowTokens - maxOutputTokens, maxContextWindowTokens, maxOutputTokens);
        }
        const isPreferred = preferred.has(model.id);
        const input = perMillion(model.pricing?.prompt);
        const output = perMillion(model.pricing?.completion);
        const contextLabel = Number.isSafeInteger(context) && context > 0 ? compactNumber(context) : "unknown context";
        const prefix = isPreferred ? "[preferred] " : "";
        const capabilities = unavailableReason ? `unavailable: ${unavailableReason}` : "tools";
        return {
            id: model.id,
            wireModel: model.id,
            label: `${prefix}${model.name ?? model.id} | ${input}/${output} per MTok | ${contextLabel} | ${capabilities}`,
            preferred: isPreferred,
            available: !unavailableReason,
            unavailableReason,
            outputParameter: Array.isArray(parameters) && (!parameters.includes("max_tokens")) &&
                parameters.includes("max_completion_tokens") ? "max_completion_tokens" : "max_tokens",
            ...(dynamicBudgets ?? {}),
        };
    });
    requireValue(new Set(entries.map(entry => entry.id)).size === entries.length, "OpenRouter returned duplicate model IDs");
    return entries.sort((left, right) => Number(right.preferred) - Number(left.preferred) ||
        Number(right.available) - Number(left.available) || left.label.localeCompare(right.label));
}

export function identity(value) {
    return createHash("sha256").update(JSON.stringify(value)).digest("hex").slice(0, 16);
}
