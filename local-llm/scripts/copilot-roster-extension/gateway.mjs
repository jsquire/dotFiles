import { createServer } from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { requireValue } from "./config.mjs";

const MAX_BODY_BYTES = 8 * 1024 * 1024;

export async function createGateway({ timeoutMs = 180000, fetchImpl = fetch } = {}) {
    const token = randomBytes(32).toString("hex");
    const routes = new Map();
    const requests = new Set();
    const server = createServer(async (req, res) => {
        const abort = new AbortController();
        requests.add(abort);
        res.on("close", () => { if (!res.writableFinished) abort.abort(); });
        try {
            const auth = req.headers.authorization?.replace(/^Bearer /i, "") ?? req.headers["x-api-key"] ?? "";
            const supplied = Buffer.from(auth);
            requireValue(supplied.length === token.length && timingSafeEqual(supplied, Buffer.from(token)), "Unauthorized gateway request");
            requireValue(req.method === "POST", "Only inference POST requests are accepted");
            const path = req.url?.split("?")[0];
            const route = [...routes.entries()].find(([key]) =>
                path === `/${key}/v1/chat/completions` || path === `/${key}/v1/messages` || path === `/${key}/messages`);
            requireValue(route, "Unknown inference route");
            const [, target] = route;
            const messages = target.api === "anthropic-messages";
            requireValue(messages ? path.endsWith("/messages") : path.endsWith("/chat/completions"), "API family mismatch");
            let bytes = 0;
            const chunks = [];
            for await (const chunk of req) {
                bytes += chunk.length;
                requireValue(bytes <= MAX_BODY_BYTES, "Request body exceeds gateway limit");
                chunks.push(chunk);
            }
            const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
            requireValue(body && typeof body === "object" && Array.isArray(body.messages), "Inference requires a messages array");
            requireValue(body.model === target.wireModel, "Wire model does not match the selected route");
            requireValue(!body.models, "Multi-model fallback requests are prohibited");
            const parameter = target.outputParameter ?? "max_tokens";
            const requested = [body.max_tokens, body.max_completion_tokens].filter(value => value !== undefined);
            requireValue(requested.every(value => Number.isSafeInteger(value) && value > 0), "Invalid output budget");
            const cap = Math.min(...requested, target.maxOutputTokens);
            delete body.max_tokens;
            delete body.max_completion_tokens;
            Object.assign(body, target.requestBody ?? {}, { [parameter]: cap });
            const headers = { ...target.headers, "content-type": "application/json" };
            if (messages) headers["anthropic-version"] ??= "2023-06-01";
            if (target.credential) {
                const name = target.authHeader ?? (messages ? "x-api-key" : "authorization");
                headers[name] = `${target.authPrefix ?? (messages ? "" : "Bearer ")}${target.credential}`;
            }
            const upstream = await fetchImpl(`${target.baseUrl}${messages ? "/messages" : "/chat/completions"}`, {
                method: "POST", headers, body: JSON.stringify(body), redirect: "error",
                signal: AbortSignal.any([abort.signal, AbortSignal.timeout(timeoutMs)]),
            });
            res.writeHead(upstream.status, {
                "content-type": upstream.headers.get("content-type") ?? "application/json",
                "cache-control": "no-store",
            });
            if (upstream.body) await pipeline(Readable.fromWeb(upstream.body), res);
            else res.end();
        } catch (error) {
            if (!res.headersSent) {
                const status = error instanceof SyntaxError ? 400 : ({
                    "Unauthorized gateway request": 401,
                    "Only inference POST requests are accepted": 405,
                    "Unknown inference route": 404,
                    "API family mismatch": 400,
                    "Wire model does not match the selected route": 403,
                    "Multi-model fallback requests are prohibited": 400,
                    "Invalid output budget": 400,
                    "Inference requires a messages array": 400,
                    "Request body exceeds gateway limit": 413,
                }[error.message] ?? (error.name === "TimeoutError" ? 504 : 502));
                res.writeHead(status, { "content-type": "application/json" });
                res.end(JSON.stringify({ error: { message: error instanceof SyntaxError ? "Invalid JSON request" :
                    (error.name === "TimeoutError" ? "Selected provider timed out" :
                        (error.message.startsWith("fetch") ? "Selected provider transport failed" : error.message)) } }));
            } else res.destroy();
        } finally {
            requests.delete(abort);
        }
    });
    await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", resolve);
    });
    return {
        add(key, target) {
            requireValue(!routes.has(key), "Duplicate gateway route");
            routes.set(key, target);
            return { baseUrl: `http://127.0.0.1:${server.address().port}/${key}${target.api === "anthropic-messages" ? "" : "/v1"}`, apiKey: token };
        },
        remove(key) {
            routes.delete(key);
        },
        update(key, target) {
            requireValue(routes.has(key), "Unknown gateway route");
            routes.set(key, target);
        },
        async close() {
            for (const request of requests) request.abort();
            server.closeAllConnections();
            await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
        },
    };
}
