# Manual end-to-end checklist (real hardware)

The automated suites (`run-all.sh` / `run-all.ps1`) cover schema, the switch daemon, launcher behavioural
parity, and installer roster generation in a sandbox. They deliberately never run a real install, touch the
live `:4090` endpoint, or invoke `systemctl`/`sudo`/`ollama`. The steps below are the parts that need actual
hardware (a running vLLM/Ollama server and the `copilot`/`crush` binaries). Run them once after deploying.

## 1. Server (the squire-server / CachyOS box)
- [ ] Install/upgrade: `./install-cachyos.sh --install server --force`
- [ ] `/etc/local-llm/server-models.json` exists and matches `cachyos/server-models.json`
- [ ] `curl -fsS http://127.0.0.1:4090/models` returns the roster (5 modes, `default_mode`, no `unit` field)
- [ ] Browser `http://<server-ip>:4090/` shows a switch button per mode; clicking one switches the model
- [ ] `~/.config/local-llm/local-models.json` was generated for the box's tier (check `"tier"`)
- [ ] `~/.config/local-llm/server-models.json` (client fallback) present

## 2. Client launchers (Windows box and/or CachyOS client)
- [ ] `copilot-local` -> Local -> pick each category's model -> Copilot launches against Ollama (`:11434`)
- [ ] `copilot-local` -> Squire-Server -> pick a model -> the server switches, then Copilot talks to vLLM
      (`:8000`); banner shows the roster label + the expected prompt/output caps
- [ ] `copilot-local` -> Local-Experimental -> `[10]` offload -> the offload serve starts and is restored on exit
- [ ] `copilot-local` -> `[6]` Office documents -> Copilot gets `--custom-instructions .../office/SKILL.md`
- [ ] `crush-task` -> Local pick -> `.crush.json` written in the CWD, crush launches
- [ ] `crush-task` -> Squire-Server pick -> switch happens and `.crush.json` `context_window` matches the roster
- [ ] `crush-task` review / docs / image profiles each write the right MCP + system-prompt config
- [ ] **Image gen follows the environment:** image profile under Local hits the local image server
      (`localhost:8001`); under Squire-Server it hits the server's `:8001` (the server GPU does the work).
      Check `.crush.json` `imagegen-mcp.env.IMAGEGEN_URL` for crush, and that copilot exported
      `COPILOT_MCP_IMAGEGEN_HOST` (so `~/.copilot/mcp-config.json` expands to the right host).

## 3. The point of the refactor: change models with data only
- [ ] Edit `~/.config/local-llm/local-models.json` (rename a label, or add a row + its `task_alias`/`registry`
      entry) -> re-run `copilot-local` -> the change shows up with NO script edit
- [ ] Add/rename a mode in the server's `/etc/local-llm/server-models.json` ->
      `sudo systemctl restart vllm-switch-web` -> `/models` advertises it -> the launcher's server page shows it
      with no client-side edit

## 4. Offline fallback
- [ ] Stop the switch daemon (`sudo systemctl stop vllm-switch-web`) -> run a launcher's Squire-Server page ->
      it falls back to the bundled `~/.config/local-llm/server-models.json` and still renders the roster
