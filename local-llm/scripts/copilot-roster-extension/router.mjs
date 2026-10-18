import { randomBytes } from "node:crypto";
import { identity, localEntries, openRouterEntries, requireValue, serverEntries } from "./config.mjs";
import { createGateway } from "./gateway.mjs";

const OWNED = /^roster-(?:local|server|cloud)-[a-f0-9]+-/;
const DEFAULT_MANAGED_AGENTS = Object.freeze([
    "general-purpose",
    "explore",
    "research",
    "code-review",
    "security-review",
]);
const BLOCKED_MANAGED_TOOLS = Object.freeze([
    "delegate",
    "run_factory",
    "run_workflow",
    "run_dynamic_workflow",
]);
const DELEGATION_TOOLS = Object.freeze([
    "task",
    "fleet",
]);

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
        this.transition = Promise.resolve();
        this.route = { phase: "initializing", model: undefined, kind: undefined, error: undefined };
        this.managedAgents = new Set(DEFAULT_MANAGED_AGENTS);
        this.routeModels = new Map();
        this.grants = new Map();
        this.hostLeases = new Map();
        this.activeSubagents = new Map();
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
        this.routeModels.set(selection, {
            kind,
            entry,
            service,
            host: this.hostKey(kind, service.baseUrl),
        });
        await this.idle();
        await this.transitionTo(selection, kind, async () => {
            await this.session.setModel(selection);
            requireValue((await this.session.rpc.model.getCurrent()).modelId === selection, "Runtime did not commit the selected route");
            const known = new Set(this.registered.values());
            const list = await this.session.rpc.model.list();
            const stale = list.list.filter(model => OWNED.test(model.id) && !known.has(model.id)).map(model => model.id);
            if (stale.length) await this.session.rpc.provider.withdraw({ models: stale });
            requireValue((await this.session.rpc.model.getCurrent()).modelId === selection, "Model changed during stale-route cleanup");
        });
        await this.session.log(`Selected ${kind} / ${kind === "cloud" ? `${service.id} / ` : ""}${entry.label ?? entry.id}. Output ceiling ${entry.maxOutputTokens}. Subagents are pinned to this route. Workflows, remote delegation, rubber-duck, and image tools remain blocked.`, { level: "info" });
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
        const name = input.toolName.replace(/^.*\./, "");
        if ((!DELEGATION_TOOLS.includes(name)) && (!BLOCKED_MANAGED_TOOLS.includes(name)) &&
            (!/imagegen/i.test(input.toolName))) return;
        try {
            const current = (await this.session.rpc.model.getCurrent()).modelId;
            requireValue(typeof current === "string" && current.length > 0, "Runtime did not report the active model ID");
            await this.reconcile(current);
        } catch (error) {
            console.error(`Routing guard could not read the active model: ${error.message}`);
            return { permissionDecision: "deny", permissionDecisionReason: "Active route could not be verified. Tool execution is blocked until routing recovers." };
        }
        if (this.route.phase === "standard") return;
        if (this.route.phase !== "managed") {
            return { permissionDecision: "deny", permissionDecisionReason: "Managed routing is not ready. Delegation is blocked until route policy is verified." };
        }
        if (BLOCKED_MANAGED_TOOLS.includes(name)) {
            return { permissionDecision: "deny", permissionDecisionReason: "This delegation surface is not validated for managed routes." };
        }
        if (DELEGATION_TOOLS.includes(name)) {
            if (name === "task") {
                const agent = input.toolArgs?.name ?? input.toolArgs?.agent_type;
                requireValue(typeof agent === "string" && agent.length > 0, "Task dispatch did not identify an agent");
                if (agent === "rubber-duck") {
                    return { permissionDecision: "deny", permissionDecisionReason: "rubber-duck is not validated for managed routes." };
                }
                try {
                    const denied = await this.configureManagedAgent(agent, input.toolArgs?.model);
                    if (denied) return { permissionDecision: "deny", permissionDecisionReason: denied };
                } catch (error) {
                    return { permissionDecision: "deny", permissionDecisionReason: `Managed subagent routing failed. ${error.message}` };
                }
            }
            return;
        }
        if (/imagegen/i.test(input.toolName)) {
            return { permissionDecision: "deny", permissionDecisionReason: "Image-profile routing remains with the existing wrapper." };
        }
    }

    async initialize() {
        const current = (await this.session.rpc.model.getCurrent()).modelId;
        requireValue(typeof current === "string" && current.length > 0, "Runtime did not report the active model ID");
        await this.reconcile(current, true);
    }

    async modelChanged(model) {
        try {
            const current = (await this.session.rpc.model.getCurrent()).modelId;
            if (current !== model) return;
            if ((this.route.model === model) &&
                (["transitioning", "managed", "standard"].includes(this.route.phase))) return this.transition;
            this.route = { phase: "transitioning", model, kind: undefined, error: undefined };
            return await this.reconcile(model, true);
        } catch (error) {
            this.route = { phase: "failed", model, kind: undefined, error };
            await this.session.log(`Routing policy could not be reconciled after the model change. Delegation is blocked. ${error.message}`, { level: "error" });
        }
    }

    async reconcile(model, force = false) {
        const managed = OWNED.test(model);
        if ((!force) && (this.route.model === model) &&
            ((managed && this.route.phase === "managed") || ((!managed) && (this.route.phase === "standard")))) return;
        return this.transitionTo(model, managed ? this.kindOf(model) : undefined);
    }

    async transitionTo(model, kind, switchModel) {
        this.route = { phase: "transitioning", model, kind, error: undefined };
        const operation = this.transition.then(async () => {
            try {
                if (switchModel) await switchModel();
                const current = (await this.session.rpc.model.getCurrent()).modelId;
                requireValue(current === model, "Model changed while routing policy was being applied");
                this.grants.clear();
                this.hostLeases.clear();
                const currentRoute = this.routeModels.get(model);
                if (currentRoute?.host) this.hostLeases.set(currentRoute.host, model);
                if (kind) {
                    await this.applyManagedPolicy(model);
                    requireValue((await this.session.rpc.model.getCurrent()).modelId === model,
                        "Model changed while managed subagent policy was being applied");
                    this.route = { phase: "managed", model, kind, error: undefined };
                } else {
                    await this.session.rpc.tools.updateSubagentSettings({ subagents: null });
                    requireValue((await this.session.rpc.model.getCurrent()).modelId === model,
                        "Model changed while standard subagent policy was being restored");
                    this.route = { phase: "standard", model, kind: undefined, error: undefined };
                }
            } catch (error) {
                this.route = { phase: "failed", model, kind, error };
                throw error;
            }
        });
        this.transition = operation.catch(() => {});
        return operation;
    }

    async applyManagedPolicy(model) {
        const agents = await this.session.rpc.agent.list({ includeBuiltInAgents: true, includePrompt: false });
        for (const agent of agents.agents ?? []) {
            if ((typeof agent.name === "string") && (agent.name !== "rubber-duck")) this.managedAgents.add(agent.name);
        }
        await this.updateManagedPolicy(model);
    }

    async configureManagedAgent(agent, requestedModel) {
        const operation = this.transition.then(async () => {
            requireValue(this.route.phase === "managed", "Managed route changed before task dispatch");
            const originalAgents = new Set(this.managedAgents);
            const originalGrants = new Map(this.grants);
            const originalHostLeases = new Map(this.hostLeases);
            let changed = false;
            try {
                if (!this.managedAgents.has(agent)) {
                    this.managedAgents.add(agent);
                    changed = true;
                }
                const existing = this.grants.get(agent);
                if ((typeof requestedModel === "string") && (requestedModel.length > 0)) {
                    if (requestedModel === this.route.model) {
                        if (existing) {
                            this.grants.delete(agent);
                            changed = true;
                        }
                    } else if ((!this.routeModels.has(requestedModel)) && (!OWNED.test(requestedModel))) {
                        // Required policy intentionally overrides non-managed model requests.
                    } else if (existing?.model !== requestedModel) {
                        const denial = await this.approveGrant(agent, requestedModel);
                        if (denial) return denial;
                        this.grants.set(agent, {
                            model: requestedModel,
                            sourceModel: this.route.model,
                            sourceKind: this.route.kind,
                        });
                        changed = true;
                    }
                }
                if (changed) await this.updateManagedPolicy(this.route.model);
                return undefined;
            } catch (error) {
                this.managedAgents = originalAgents;
                this.grants = originalGrants;
                this.hostLeases = originalHostLeases;
                this.route = { ...this.route, phase: "failed", error };
                throw error;
            }
        });
        this.transition = operation.catch(() => {});
        return operation;
    }

    async approveGrant(agent, targetModel) {
        const target = this.routeModels.get(targetModel);
        if (!target) return "Cross-provider routing requires an extension-managed model registered in this session.";
        const source = this.routeModels.get(this.route.model) ?? {
            kind: this.route.kind,
            host: undefined,
            entry: { label: this.route.model },
        };
        const allowed = {
            local: new Set(["server", "cloud"]),
            server: new Set(["local", "cloud"]),
            cloud: new Set(["local", "cloud"]),
        };
        if (!allowed[source.kind]?.has(target.kind)) {
            return `${source.kind} routes cannot grant subagents access to ${target.kind} routes.`;
        }
        if ((target.host) && (source.host === target.host) && (targetModel !== this.route.model)) {
            return "Two different models cannot use the same local or vLLM host.";
        }
        if ((target.host) && (this.hostLeases.has(target.host)) &&
            (this.hostLeases.get(target.host) !== targetModel)) {
            return "A different model already holds this local or vLLM host for the current foreground route.";
        }
        for (const grant of this.grants.values()) {
            const granted = this.routeModels.get(grant.model);
            if ((target.host) && (granted?.host === target.host) && (grant.model !== targetModel)) {
                return "Another approved subagent model already holds this local or vLLM host.";
            }
        }
        for (const model of this.activeSubagents.values()) {
            const active = this.routeModels.get(model);
            if ((target.host) && (active?.host === target.host) && (model !== targetModel)) {
                return "A different subagent model is still active on this local or vLLM host.";
            }
        }
        await this.verifyGrantTarget(target);
        if (!this.session.capabilities.ui?.elicitation) {
            return "Cross-provider subagent routing requires interactive approval.";
        }
        const label = target.entry.label ?? target.entry.id;
        const approved = await this.session.ui.confirm(
            `Allow ${agent} subagents to use ${target.kind} / ${label} until the active foreground route changes?`,
        );
        if (approved && target.host) this.hostLeases.set(target.host, targetModel);
        return approved ? undefined : "Cross-provider subagent routing was not approved.";
    }

    async verifyGrantTarget(target) {
        if (target.kind === "local") {
            const installed = await this.json(this.config.local.discoveryUrl);
            requireValue(installed.models?.some(model => (!model.remote_model) && (!model.remote_host) &&
                (model.name === target.entry.wireModel || model.name === target.entry.id)),
            "The approved local model is no longer available from the running Ollama instance");
            const models = await this.json(`${this.config.local.baseUrl}/models`);
            requireValue(models.data?.some(model => model.id === target.entry.wireModel ||
                model.id === `${target.entry.wireModel}:latest`),
            "The running local compatibility endpoint no longer advertises the approved model");
        }
        if (target.kind === "server") {
            const state = await this.json(`${this.config.server.controlUrl}/status`);
            requireValue((state.mode === target.entry.id) && (state.api_up === true) &&
                (state.served_model === target.entry.wireModel),
            "The approved vLLM model is not currently served and ready");
        }
    }

    async updateManagedPolicy(model) {
        requireValue(this.route.phase === "transitioning" || this.route.phase === "managed",
            "Managed policy cannot be updated outside a managed route");
        await this.session.rpc.tools.updateSubagentSettings({
            subagents: {
                agents: Object.fromEntries([...this.managedAgents].map(agent => [agent, {
                    model: this.grants.get(agent)?.model ?? model,
                    modelPolicy: "required",
                    contextTier: "inherit",
                }])),
                disabledSubagents: ["rubber-duck"],
            },
        });
    }

    kindOf(model) {
        return /^roster-(local|server|cloud)-/.exec(model)?.[1];
    }

    hostKey(kind, baseUrl) {
        if ((kind !== "local") && (kind !== "server")) return undefined;
        const hostname = new URL(baseUrl).hostname.toLowerCase();
        return ["localhost", "127.0.0.1", "::1", "[::1]"].includes(hostname) ? "loopback" : hostname;
    }

    subagentEvent(event) {
        if (event.type === "subagent.started") {
            if (event.data.model) this.activeSubagents.set(event.data.toolCallId, event.data.model);
        } else if ((event.type === "subagent.completed") || (event.type === "subagent.failed")) {
            this.activeSubagents.delete(event.data.toolCallId);
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
