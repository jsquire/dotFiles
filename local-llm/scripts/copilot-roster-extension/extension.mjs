import { joinSession } from "@github/copilot-sdk/extension";
import { loadConfig, requireValue } from "./config.mjs";
import { gitGuard, Router } from "./router.mjs";

const config = await loadConfig();
let session;
let router;
try {
    session = await joinSession({
        requestedEnvironmentVariables: [...new Set(config.services.flatMap(service => service.credential ? [service.credential.env] : []))],
        commands: ["local", "server", "cloud"].map(name => ({
            name,
            description: `Select ${name} models without leaving the conversation; use '${name} status' to inspect the route`,
            handler: async context => {
                requireValue(router, "Routing extension is still initializing");
                try {
                    await router.command(name, context.args ?? "");
                } catch (error) {
                    await session.log(`Routing failed. No fallback was selected. ${error.message}`, { level: "error" });
                    throw error;
                }
            },
        })),
        hooks: {
            onPreToolUse: async input => {
                const denied = gitGuard(input);
                if (denied) return denied;
                requireValue(router, "Routing guard is not ready");
                return router.guard(input);
            },
        },
    });
    for (const [api, method] of [[session.rpc.provider, "add"], [session.rpc.provider, "withdraw"],
        [session.rpc.metadata, "activity"], [session.rpc.model, "getCurrent"]]) {
        requireValue(typeof api?.[method] === "function", `Required experimental SDK API ${method} is unavailable`);
    }
    router = new Router(session, config);
    await session.log("Roster routing ready. No model was changed. Experimental trial retains the legacy wrapper; server unit changes, image profiles and BYOK delegation are not enabled.", { level: "info" });
    let stopping = false;
    const stop = async () => {
        if (stopping) return;
        stopping = true;
        try { await router.close(); }
        catch (error) { console.error(`Roster gateway shutdown failed: ${error.message}`); }
        process.exit(0);
    };
    process.once("SIGTERM", stop);
    process.once("SIGINT", stop);
    process.once("disconnect", stop);
} catch (error) {
    console.error(`Roster extension failed to initialize: ${error.message}`);
    if (router) await router.close();
    throw error;
}
