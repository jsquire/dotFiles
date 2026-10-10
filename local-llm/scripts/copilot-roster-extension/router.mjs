import { randomBytes } from "node:crypto";
import { identity, localEntries, openRouterEntries, requireValue, serverEntries } from "./config.mjs";
import { createGateway } from "./gateway.mjs";

const OWNED = /^roster-(?:local|server|cloud)-[a-f0-9]+-/;

export class Router {
    constructor(session, config, { fetchImpl = fetch, environment = process.env, gatewayFactory = createGateway,
        credentialLoader = async name => environment[name] } = {}) {
        this.session = session;
        this.config = config;
        this.fetchImpl = fetchImpl;
        this.environment = environment;
        this.credentialLoader = credentialLoader;
        this.gatewayFactory = gatewayFactory;
        this.epoch = randomBytes(6).toString("hex");
        this.registered = new Map();
        this.busy = false;
    }

    async json(url) {
        const response = await this.fetchImpl(url, { redirect: "error", signal: AbortSignal.timeout(10000) });
        requireValue(response.ok, `Discovery failed with HTTP ${response.status}`);
        return response.json();
    }

    async postJson(url, body) {
        const response = await this.fetchImpl(url, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(body),
            redirect: "error",
            signal: AbortSignal.timeout(10000),
        });
        requireValue(response.ok, `Discovery failed with HTTP ${response.status}`);
        return response.json();
    }

    async idle() {
        const activity = await this.session.rpc.metadata.activity();
        requireValue(typeof activity.hasActiveWork === "boolean", "Runtime did not report authoritative session activity");
        requireValue(!activity.hasActiveWork, "Wait for foreground and background work to finish before changing routes");
    }

    async choose(entries, argument, heading) {
        if (argument) {
            const entry = entries.find(candidate => candidate.id === argument);
            requireValue(entry, `Unknown selection ${argument}`);
            requireValue(entry.available !== false, `${entry.id} cannot be selected: ${entry.unavailableReason ?? "unavailable"}`);
            return entry;
        }
        requireValue(this.session.capabilities.ui?.elicitation, "Interactive selection is unavailable. Supply an explicit selection argument");
        const choices = entries.map(entry => `${entry.id} | ${entry.label}`);
        const selected = await this.session.ui.select(heading, choices);
        if (selected === null) return null;
        const index = choices.indexOf(selected);
        requireValue(index >= 0, "Host returned an unknown selection");
        const entry = entries[index];
        requireValue(entry.available !== false, `${entry.id} cannot be selected: ${entry.unavailableReason ?? "unavailable"}`);
        return entry;
    }

    async local(argument) {
        requireValue(this.config.local, "Local routing is not configured");
        const installed = await this.json(this.config.local.discoveryUrl);
        requireValue(Array.isArray(installed.models), "Ollama returned an invalid model list");
        const localModels = installed.models.filter(model => !model.remote_model && !model.remote_host);
        const details = new Map(await Promise.all(localModels.map(async model => [
            model.name,
            await this.postJson(new URL("/api/show", this.config.local.discoveryUrl).href, { model: model.name }),
        ])));
        const entry = await this.choose(localEntries(installed, details), argument, "Select an installed Ollama model");
        if (!entry) return;
        const models = await this.json(`${this.config.local.baseUrl}/models`);
        requireValue(Array.isArray(models.data), "Compatibility proxy returned an invalid model list");
        requireValue(models.data.some(model => model.id === entry.wireModel || model.id === `${entry.wireModel}:latest`),
            "Selected local alias is not advertised by the compatibility endpoint");
        await this.activate("local", entry, { api: "openai-chat", baseUrl: this.config.local.baseUrl });
    }

    async server(argument) {
        requireValue(this.config.server, "Server routing is not configured");
        let roster;
        try {
            roster = await this.json(`${this.config.server.controlUrl}/models`);
        } catch (error) {
            await this.session.log(`Server discovery failed (${error.message}). Using the configured offline roster for selection only.`, { level: "warning" });
            const { readFile } = await import("node:fs/promises");
            roster = JSON.parse(await readFile(this.config.server.rosterPath, "utf8"));
        }
        const entry = await this.choose(serverEntries(roster), argument, "Select an already-served server model");
        if (!entry) return;
        requireValue(!entry.image, "Server image-profile switching is not validated. Keep using the existing wrapper");
        const state = await this.json(`${this.config.server.controlUrl}/status`);
        requireValue(state.mode === entry.id, "Server mode differs. Shared-server switching requires coordinated ownership; use the existing switch workflow, then retry /server");
        requireValue(state.api_up === true && state.served_model === entry.wireModel, "Server readiness or model identity does not match the selection");
        const models = await this.json(`${this.config.server.baseUrl}/models`);
        requireValue(models.data?.some(model => model.id === entry.wireModel), "vLLM does not advertise the selected model");
        await this.activate("server", entry, { api: "openai-chat", baseUrl: this.config.server.baseUrl });
    }

    async cloud(argument) {
        requireValue(this.config.services.length > 0, "No third-party services are configured in roster-routing.json");
        const split = argument.indexOf(" ");
        const serviceArgument = split < 0 ? argument : argument.slice(0, split);
        const modelArgument = split < 0 ? "" : argument.slice(split + 1).trim();
        const service = await this.choose(this.config.services, serviceArgument, "Select a third-party service");
        if (!service) return;
        let entries = service.models;
        if (service.discovery?.kind === "openrouter") {
            entries = openRouterEntries(await this.json(service.discovery.url), service.discovery);
        }
        const entry = await this.choose(entries.map(model => ({
            ...model, label: model.label ?? model.id, wireModel: model.wireModel ?? model.id,
        })), modelArgument, `Select a model from ${service.id}`);
        if (!entry) return;
        if (this.session.capabilities.ui?.elicitation) {
            if (!await this.session.ui.confirm(`Send this session's conversation and tool results to ${service.id} at ${service.baseUrl}? No other service will be used on failure.`)) return;
        } else {
            throw new Error("Cloud selection requires an interactive history-transfer confirmation");
        }
        const credential = service.credential && await this.credentialLoader(service.credential.env);
        requireValue(!service.credential || (typeof credential === "string" && credential.length > 0), `Credential access is missing for ${service.id}`);
        const authHeader = service.credential?.header ?? (service.api === "anthropic-messages" ? "x-api-key" : "authorization");
        const authPrefix = service.credential?.prefix ?? (authHeader.toLowerCase() === "authorization" ? "Bearer " : "");
        await this.activate("cloud", entry, { ...service, credential, authHeader, authPrefix });
    }

    async activate(kind, entry, service) {
        await this.idle();
        const signature = identity({
            kind, entry, service: { ...service, credential: undefined },
        });
        let selection = this.registered.get(signature);
        if (selection) this.gateway.update(signature, { ...service, ...entry });
        if (!selection) {
            this.gateway ??= await this.gatewayFactory({ timeoutMs: this.config.timeoutMs, fetchImpl: this.fetchImpl });
            const provider = `roster-${kind}-${this.epoch}-${signature}-${randomBytes(4).toString("hex")}`;
            const connection = this.gateway.add(signature, { ...service, ...entry });
            selection = `${provider}/${entry.id}`;
            try {
                await this.session.rpc.provider.add({
                providers: [{ name: provider, type: service.api === "anthropic-messages" ? "anthropic" : "openai",
                    ...(service.api === "openai-chat" ? { wireApi: "completions" } : {}), ...connection }],
                models: [{ provider, id: entry.id, wireModel: entry.wireModel,
                    name: `${kind} / ${kind === "cloud" ? `${service.id} / ` : ""}${entry.label ?? entry.id}`,
                    maxPromptTokens: entry.maxPromptTokens, maxContextWindowTokens: entry.maxContextWindowTokens,
                    maxOutputTokens: entry.maxOutputTokens }],
                });
            } catch (error) {
                this.gateway.remove(signature);
                throw error;
            }
            this.registered.set(signature, selection);
        }
        await this.idle();
        await this.session.setModel(selection);
        requireValue((await this.session.rpc.model.getCurrent()).modelId === selection, "Runtime did not commit the selected route");
        const known = new Set(this.registered.values());
        const list = await this.session.rpc.model.list();
        const stale = list.list.filter(model => OWNED.test(model.id) && !known.has(model.id)).map(model => model.id);
        if (stale.length) await this.session.rpc.provider.withdraw({ models: stale });
        requireValue((await this.session.rpc.model.getCurrent()).modelId === selection, "Model changed during stale-route cleanup");
        await this.session.log(`Selected ${kind} / ${kind === "cloud" ? `${service.id} / ` : ""}${entry.label ?? entry.id}. Output ceiling ${entry.maxOutputTokens}. Delegation and image tools are blocked on extension routes during this trial.`, { level: "info" });
    }

    async command(name, argument = "") {
        requireValue(!this.busy, "Another routing command is already in progress");
        this.busy = true;
        try {
            if (argument.trim() === "status") {
                await this.session.log(`Active model ${ (await this.session.rpc.model.getCurrent()).modelId }`, { level: "info" });
                return;
            }
            await this.idle();
            await this[name](argument.trim());
        } finally {
            this.busy = false;
        }
    }

    async guard(input) {
        let current;
        try {
            current = (await this.session.rpc.model.getCurrent()).modelId;
            requireValue(typeof current === "string" && current.length > 0, "Runtime did not report the active model ID");
        } catch (error) {
            console.error(`Routing guard could not read the active model: ${error.message}`);
            return { permissionDecision: "deny", permissionDecisionReason: "Active route could not be verified. Tool execution is blocked until routing recovers." };
        }
        if (!OWNED.test(current)) return;
        const name = input.toolName.replace(/^.*\./, "");
        if (["task", "write_agent", "run_factory", "run_workflow", "delegate", "fleet"].includes(name)) {
            return { permissionDecision: "deny", permissionDecisionReason: "Delegation on BYOK routes is blocked until provider isolation is validated. No automatic cloud routing." };
        }
        if (/imagegen/i.test(input.toolName)) {
            return { permissionDecision: "deny", permissionDecisionReason: "Image-profile routing remains with the existing wrapper." };
        }
    }

    async close() {
        if (this.gateway) await this.gateway.close();
    }
}

export function gitGuard(input) {
    const args = input.toolArgs;
    const command = typeof args === "object" && args !== null ? (args.command ?? args.cmd ?? "") : "";
    if ((/(?:shell|powershell|bash|terminal)/i.test(input.toolName)) &&
        (/\bgit(?:\.exe)?\s+(?:(?:-[^\s]+)\s+)*(?:add|commit|push|merge|rebase|reset|stash|cherry-pick|revert|tag)\b/i.test(command))) {
        return { permissionDecision: "deny", permissionDecisionReason: "Legacy Git mutation restrictions remain in effect during the extension trial." };
    }
}
