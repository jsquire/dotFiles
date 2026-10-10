import { applyEdits, modify, parse } from "jsonc-parser";
import { createHash, randomUUID } from "node:crypto";
import { lstat, mkdir, readFile, readdir, rename, stat, unlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { openRouterService, requireValue, validateConfig } from "./config.mjs";

const sourceDirectory = dirname(fileURLToPath(import.meta.url));
const assets = ["extension.mjs", "config.mjs", "gateway.mjs", "router.mjs"];
const hash = value => createHash("sha256").update(value).digest("hex");

async function optionalFile(path) {
    try { return await readFile(path, "utf8"); }
    catch (error) { if (error.code === "ENOENT") return undefined; throw error; }
}

async function exists(path) {
    try { await lstat(path); return true; }
    catch (error) { if (error.code === "ENOENT") return false; throw error; }
}

async function fileHash(path) {
    const content = await optionalFile(path);
    return content === undefined ? undefined : hash(content);
}

async function replaceSettings(path, text, release) {
    const staged = join(release, `settings-edit-${randomUUID()}.jsonc`);
    await writeFile(staged, text, { flag: "wx", mode: 0o600 });
    await rename(staged, path);
}

async function saveJournal(path, manifest) {
    const staged = join(dirname(path), `journal-edit-${randomUUID()}.json`);
    await writeFile(staged, JSON.stringify(manifest, null, 2) + "\n", { flag: "wx", mode: 0o600 });
    await rename(staged, path);
}

function settings(text = "{}\n") {
    const errors = [];
    const value = parse(text, errors, { allowTrailingComma: true });
    requireValue(errors.length === 0 && value && typeof value === "object" && !Array.isArray(value), "Existing settings are not a valid JSONC object");
    return value;
}

function editSetting(text, value, path = ["experimental"]) {
    return applyEdits(text, modify(text, path, value, {
        formattingOptions: { insertSpaces: true, tabSize: 2, eol: text.includes("\r\n") ? "\r\n" : "\n" },
    }));
}

async function locked(home, action) {
    requireValue(isAbsolute(home), "Configuration home must be absolute");
    await mkdir(home, { recursive: true });
    const path = join(home, "roster-routing-deployment.lock");
    try {
        await writeFile(path, String(process.pid), { flag: "wx", mode: 0o600 });
    } catch (error) {
        if (error.code !== "EEXIST") throw error;
        const previous = await readFile(path, "utf8");
        const pid = Number(previous);
        requireValue(Number.isSafeInteger(pid) && pid > 0, "Deployment lock is invalid and will not be removed");
        let alive = true;
        try { process.kill(pid, 0); }
        catch (probeError) { if (probeError.code !== "ESRCH") throw probeError; alive = false; }
        requireValue(!alive, "Another deployment process is running; no files were changed");
        requireValue(await readFile(path, "utf8") === previous, "Deployment lock changed; no files were changed");
        await unlink(path);
        await writeFile(path, String(process.pid), { flag: "wx", mode: 0o600 });
    }
    try { return await action(); }
    finally { await unlink(path); }
}

export async function install(home, config, { enableExperimental = true } = {}) {
    validateConfig(config);
    return locked(home, async () => {
        const extension = join(home, "extensions", "roster-routing");
        try {
            await stat(extension);
            throw new Error("Extension directory already exists. Roll back the previous managed deployment or explicitly preserve it before installing");
        } catch (error) {
            if (error.code !== "ENOENT") throw error;
        }
        const configPath = join(home, "roster-routing.json");
        const previousConfig = await optionalFile(configPath);
        const configText = JSON.stringify(config, null, 2) + "\n";
        requireValue(previousConfig === undefined || previousConfig === configText, "Existing routing configuration differs. It will not be overwritten");
        const settingsPath = join(home, "settings.json");
        const previousText = await optionalFile(settingsPath) ?? "{}\n";
        const previousSettings = settings(previousText);
        requireValue(previousSettings.experimental === undefined || typeof previousSettings.experimental === "boolean",
            "Existing experimental setting must be a boolean");
        requireValue(previousSettings.extensions === undefined || previousSettings.extensions === null ||
            (typeof previousSettings.extensions === "object" && !Array.isArray(previousSettings.extensions)), "Existing extensions setting must be an object");
        const originalMode = previousSettings.extensions?.mode;
        requireValue(originalMode === undefined || ["load_only", "load_and_augment", "disabled"].includes(originalMode), "Unknown existing extension mode");
        requireValue(originalMode !== "disabled", "Extensions are intentionally disabled. Enable Load Only explicitly before installing");
        const changedSetting = enableExperimental && previousSettings.experimental !== true;
        const changedMode = originalMode !== "load_only";
        if (((changedSetting) || (changedMode)) && (await exists(settingsPath))) {
            requireValue(!(await lstat(settingsPath)).isSymbolicLink(),
                "Automatic experimental enablement does not overwrite a settings symlink. Enable it through the CLI first");
        }
        const release = join(home, "roster-routing-recovery", randomUUID());
        await mkdir(join(release, "release"), { recursive: true, mode: 0o700 });
        const manifest = {
            schemaVersion: 1, home, state: "preparing", files: {},
            configCreated: previousConfig === undefined, configHash: hash(configText),
            settingChanged: changedSetting,
            originalSettingPresent: Object.hasOwn(previousSettings, "experimental"),
            originalSetting: previousSettings.experimental,
            modeChanged: changedMode,
            originalModePresent: Object.hasOwn(previousSettings.extensions ?? {}, "mode"),
            originalMode,
            originalExtensionsPresent: Object.hasOwn(previousSettings, "extensions"),
            originalExtensionsNull: previousSettings.extensions === null,
        };
        const manifestPath = join(release, "manifest.json");
        const save = () => saveJournal(manifestPath, manifest);
        await save();
        for (const name of assets) {
            const content = await readFile(join(sourceDirectory, name));
            await writeFile(join(release, "release", name), content, { mode: 0o600 });
            manifest.files[name] = hash(content);
        }
        await save();
        if (manifest.configCreated) {
            manifest.configWritten = true;
            await save();
            await writeFile(configPath, configText, { flag: "wx", mode: 0o600 });
        }
        if ((changedSetting) || (changedMode)) {
            requireValue((await optionalFile(settingsPath) ?? "{}\n") === previousText, "Settings changed during deployment");
            manifest.settingWritten = changedSetting;
            manifest.modeWritten = changedMode;
            await save();
            let updated = changedSetting ? editSetting(previousText, true) : previousText;
            if (changedMode) updated = editSetting(updated, "load_only", ["extensions", "mode"]);
            await replaceSettings(settingsPath, updated, release);
        }
        await mkdir(dirname(extension), { recursive: true });
        manifest.extensionWritten = true;
        await save();
        await rename(join(release, "release"), extension);
        manifest.state = "installed";
        await save();
        return { manifestPath, extension };
    });
}

async function managedManifest(home) {
    const recovery = join(home, "roster-routing-recovery");
    let entries;
    try { entries = await readdir(recovery, { withFileTypes: true }); }
    catch (error) { if (error.code === "ENOENT") return undefined; throw error; }
    const extension = join(home, "extensions", "roster-routing");
    const configPath = join(home, "roster-routing.json");
    const matches = [];
    for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        const manifestPath = join(recovery, entry.name, "manifest.json");
        let manifest;
        try { manifest = JSON.parse(await readFile(manifestPath, "utf8")); }
        catch (error) { if (error.code === "ENOENT" || error instanceof SyntaxError) continue; throw error; }
        if (manifest.schemaVersion !== 1 || manifest.home !== home || manifest.state !== "installed") continue;
        const moduleMatches = (await Promise.all(Object.entries(manifest.files ?? {}).map(async ([name, expected]) => {
            if (!assets.includes(name)) return false;
            const current = await fileHash(join(extension, name));
            const pending = manifest.pendingUpgrade?.modules?.[name];
            return current === expected || (pending && (current === pending.previousHash || current === pending.newHash));
        }))).every(Boolean);
        const currentConfigHash = await fileHash(configPath);
        const pendingConfig = manifest.pendingUpgrade?.config;
        const configMatches = currentConfigHash === manifest.configHash ||
            (pendingConfig && (currentConfigHash === pendingConfig.previousHash || currentConfigHash === pendingConfig.newHash));
        if ((moduleMatches) && (configMatches)) matches.push({ manifestPath, manifest });
    }
    requireValue(matches.length <= 1, "Multiple managed deployments match the current extension; select a recovery manifest manually");
    return matches[0];
}

async function recoverPendingUpgrade(manifestPath, manifest) {
    const pending = manifest.pendingUpgrade;
    if (!pending) return manifest;
    const conflicts = [];
    for (const [name, entry] of Object.entries(pending.modules ?? {})) {
        const target = join(manifest.home, "extensions", "roster-routing", name);
        const current = await fileHash(target);
        if (current === entry.newHash) {
            const staged = join(dirname(manifestPath), `upgrade-recovery-${randomUUID()}-${name}`);
            await writeFile(staged, await readFile(entry.backup), { flag: "wx", mode: 0o600 });
            await rename(staged, target);
        } else if (current !== entry.previousHash) conflicts.push(`extension/${name}`);
    }
    if (pending.config) {
        const target = join(manifest.home, "roster-routing.json");
        const current = await fileHash(target);
        if (current === pending.config.newHash) {
            const staged = join(dirname(manifestPath), `upgrade-recovery-${randomUUID()}-config.json`);
            await writeFile(staged, await readFile(pending.config.backup), { flag: "wx", mode: 0o600 });
            await rename(staged, target);
        } else if (current !== pending.config.previousHash) conflicts.push("roster-routing.json");
    }
    requireValue(conflicts.length === 0,
        `Incomplete upgrade recovery conflict. No additional files were changed. Preserve and resolve ${conflicts.join(", ")}`);
    manifest.files = pending.previousFiles;
    manifest.configHash = pending.previousConfigHash;
    delete manifest.pendingUpgrade;
    await saveJournal(manifestPath, manifest);
    return manifest;
}

export async function upgrade(home, config, { reason = "Upgrade managed roster routing deployment" } = {}) {
    validateConfig(config);
    return locked(home, async () => {
        const managed = await managedManifest(home);
        requireValue(managed, "No matching managed deployment was found. Preserve or resolve the existing files before upgrading");
        let { manifest } = managed;
        const { manifestPath } = managed;
        manifest = await recoverPendingUpgrade(manifestPath, manifest);
        const extension = join(home, "extensions", "roster-routing");
        const configPath = join(home, "roster-routing.json");
        const previousConfig = await readFile(configPath, "utf8");
        requireValue(hash(previousConfig) === manifest.configHash, "Routing configuration changed outside the managed deployment");
        const nextConfig = JSON.stringify(config, null, 2) + "\n";
        const changes = {};
        for (const name of assets) {
            const current = await readFile(join(extension, name));
            requireValue(hash(current) === manifest.files[name], `Managed extension file changed: ${name}`);
            const next = await readFile(join(sourceDirectory, name));
            if (current.equals(next)) continue;
            changes[name] = { current, next, previousHash: hash(current), newHash: hash(next) };
        }
        const configChanged = nextConfig !== previousConfig;
        if ((Object.keys(changes).length === 0) && (!configChanged)) {
            return { manifestPath, extension, upgraded: false };
        }
        const adjustment = join(dirname(manifestPath), `upgrade-${randomUUID()}`);
        await mkdir(adjustment, { recursive: true, mode: 0o700 });
        const modules = {};
        for (const [name, change] of Object.entries(changes)) {
            const backup = join(adjustment, `previous-${name}`);
            const staged = join(adjustment, `next-${name}`);
            await writeFile(backup, change.current, { flag: "wx", mode: 0o600 });
            await writeFile(staged, change.next, { flag: "wx", mode: 0o600 });
            modules[name] = {
                previousHash: change.previousHash,
                newHash: change.newHash,
                backup,
                staged,
            };
        }
        let configUpgrade;
        if (configChanged) {
            const backup = join(adjustment, "previous-roster-routing.json");
            const staged = join(adjustment, "next-roster-routing.json");
            await writeFile(backup, previousConfig, { flag: "wx", mode: 0o600 });
            await writeFile(staged, nextConfig, { flag: "wx", mode: 0o600 });
            configUpgrade = { previousHash: hash(previousConfig), newHash: hash(nextConfig), backup, staged };
        }
        manifest.pendingUpgrade = {
            reason,
            previousFiles: { ...manifest.files },
            previousConfigHash: manifest.configHash,
            modules,
            config: configUpgrade,
        };
        await saveJournal(manifestPath, manifest);
        for (const [name, entry] of Object.entries(modules)) {
            await rename(entry.staged, join(extension, name));
        }
        if (configUpgrade) await rename(configUpgrade.staged, configPath);
        manifest.files = {
            ...manifest.files,
            ...Object.fromEntries(Object.entries(modules).map(([name, entry]) => [name, entry.newHash])),
        };
        manifest.configHash = configUpgrade?.newHash ?? manifest.configHash;
        manifest.adjustments ??= [];
        for (const [name, entry] of Object.entries(modules)) {
            manifest.adjustments.push({
                module: name,
                previousHash: entry.previousHash,
                newHash: entry.newHash,
                backup: entry.backup,
                reason,
            });
        }
        if (configUpgrade) {
            manifest.adjustments.push({
                module: "roster-routing.json",
                previousHash: configUpgrade.previousHash,
                newHash: configUpgrade.newHash,
                backup: configUpgrade.backup,
                reason,
            });
        }
        delete manifest.pendingUpgrade;
        await saveJournal(manifestPath, manifest);
        return { manifestPath, extension, upgraded: true };
    });
}

export async function ensure(home, config, options = {}) {
    return await exists(join(home, "extensions", "roster-routing"))
        ? upgrade(home, config, options)
        : install(home, config, options);
}

export async function rollback(manifestPath) {
    let manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    requireValue(manifest.schemaVersion === 1 && isAbsolute(manifest.home), "Invalid deployment journal");
    const release = dirname(manifestPath);
    requireValue(dirname(release) === join(manifest.home, "roster-routing-recovery"), "Journal is outside the owned recovery directory");
    return locked(manifest.home, async () => {
        manifest = await recoverPendingUpgrade(manifestPath, manifest);
        if (manifest.state === "rolled-back") return { alreadyRolledBack: true };
        const extension = join(manifest.home, "extensions", "roster-routing");
        const conflicts = [];
        const extensionPresent = await exists(extension);
        if ((manifest.extensionWritten) && (extensionPresent)) {
            for (const [name, expected] of Object.entries(manifest.files)) {
                requireValue(assets.includes(name), "Journal contains an unowned extension path");
                const content = await optionalFile(join(extension, name));
                if ((content === undefined) || (hash(content) !== expected)) conflicts.push(`extension/${name}`);
            }
        }
        const configPath = join(manifest.home, "roster-routing.json");
        const currentConfig = await optionalFile(configPath);
        if ((manifest.configWritten) && (currentConfig !== undefined) && (hash(currentConfig) !== manifest.configHash)) conflicts.push("roster-routing.json");
        const settingsPath = join(manifest.home, "settings.json");
        const currentText = await optionalFile(settingsPath) ?? "{}\n";
        const current = settings(currentText);
        const originalSetting = Object.hasOwn(current, "experimental") === manifest.originalSettingPresent &&
            current.experimental === manifest.originalSetting;
        if ((manifest.settingWritten) && (current.experimental !== true) && (!originalSetting)) conflicts.push("settings.experimental");
        const originalMode = Object.hasOwn(current.extensions ?? {}, "mode") === manifest.originalModePresent &&
            current.extensions?.mode === manifest.originalMode;
        if ((manifest.modeWritten) && (current.extensions?.mode !== "load_only") && (!originalMode)) conflicts.push("settings.extensions.mode");
        requireValue(conflicts.length === 0, `Rollback conflict. No files were changed. Preserve and resolve ${conflicts.join(", ")}`);
        if (((manifest.settingWritten) || (manifest.modeWritten)) && (await exists(settingsPath))) {
            requireValue(!(await lstat(settingsPath)).isSymbolicLink(), "Settings became a symlink. Rollback stopped without overwriting it");
        }
        if ((manifest.extensionWritten) && (extensionPresent)) {
            await rename(extension, join(release, "disabled-extension"));
            manifest.extensionWritten = false;
            await saveJournal(manifestPath, manifest);
        }
        if ((manifest.settingWritten) || (manifest.modeWritten)) {
            requireValue((await optionalFile(settingsPath) ?? "{}\n") === currentText, "Settings changed during rollback");
            let restored = (manifest.settingWritten && !originalSetting)
                ? editSetting(currentText, manifest.originalSettingPresent ? manifest.originalSetting : undefined) : currentText;
            if ((manifest.modeWritten) && (!originalMode)) {
                restored = editSetting(restored, manifest.originalModePresent ? manifest.originalMode : undefined, ["extensions", "mode"]);
                const value = settings(restored);
                if ((value.extensions) && (Object.keys(value.extensions).length === 0) &&
                    ((!manifest.originalExtensionsPresent) || (manifest.originalExtensionsNull))) {
                    restored = editSetting(restored, manifest.originalExtensionsNull ? null : undefined, ["extensions"]);
                }
            }
            await replaceSettings(settingsPath, restored, release);
            manifest.settingWritten = false;
            manifest.modeWritten = false;
        }
        if ((manifest.configWritten) && (currentConfig !== undefined)) {
            requireValue(hash(await readFile(configPath, "utf8")) === manifest.configHash, "Routing configuration changed during rollback");
            await unlink(configPath);
            manifest.configWritten = false;
        }
        manifest.state = "rolled-back";
        await saveJournal(manifestPath, manifest);
        return { disabledExtension: join(release, "disabled-extension"), preservedSessions: true };
    });
}

function argumentsOf(args) {
    const values = {};
    for (let index = 0; index < args.length; index += 2) {
        requireValue(args[index].startsWith("--") && args[index + 1], "Options require --name value pairs");
        values[args[index].slice(2)] = args[index + 1];
    }
    return values;
}

if ((process.argv[1]) && (resolve(process.argv[1]) === fileURLToPath(import.meta.url))) {
    try {
        const command = process.argv[2];
        const options = argumentsOf(process.argv.slice(3));
        if (command === "install" || command === "ensure") {
            const home = options.home ?? join(homedir(), ".copilot");
            const rosterDirectory = join(homedir(), ".config", "local-llm");
            const role = options.role ?? "desktop";
            requireValue(["desktop", "client", "server"].includes(role), "--role must be desktop, client, or server");
            const serverHost = role === "server" ? (options["server-host"] ?? "127.0.0.1") : options["server-host"];
            requireValue(role !== "client" || serverHost, "Client role requires --server-host");
            const config = options.config ? JSON.parse(await readFile(options.config, "utf8")) : {
                schemaVersion: 1,
                local: role === "desktop"
                    ? { baseUrl: "http://127.0.0.1:11435/v1", discoveryUrl: "http://127.0.0.1:11434/api/tags" }
                    : null,
                server: serverHost ? {
                    baseUrl: `http://${serverHost}:8000/v1`,
                    controlUrl: `http://${serverHost}:4090`,
                    rosterPath: join(rosterDirectory, "server-models.json"),
                } : null,
                services: [openRouterService()],
            };
            const action = command === "ensure" ? ensure : install;
            console.log(JSON.stringify(await action(home, config), null, 2));
        } else if (command === "rollback") {
            requireValue(options.manifest, "rollback requires --manifest");
            console.log(JSON.stringify(await rollback(options.manifest), null, 2));
        } else throw new Error("Use install|ensure [--home directory] [--config file] [--role desktop|client|server] [--server-host host] or rollback --manifest file");
    } catch (error) {
        console.error(`Deployment stopped: ${error.message}`);
        process.exitCode = 1;
    }
}
