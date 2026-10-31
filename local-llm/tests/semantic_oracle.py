import json
import os
import sys


def emit(fields):
    print("\t".join(str(field) for field in fields))


data = json.load(sys.stdin)
expected = json.load(open(os.environ["ORACLE_EXPECTED"]))
kind = os.environ.get("ORACLE_KIND", "local")
platform = os.environ.get("ORACLE_PLATFORM", "bash")

if kind == "local":
    registry = data["registry"]
    aliases = data["task_alias"]
    launcher = data["launchers"]["copilot"]
    seen = set()
    for page_name, page_input in (("production", "1"), ("experimental", "2")):
        pages = [(page_name, launcher[page_name]["categories"])]
        if page_name == "experimental" and platform == "windows":
            pages.append((
                "windows_experimental",
                launcher.get("windows_experimental", {}).get("categories", []),
            ))
        for semantic_page, categories in pages:
            for category in categories:
                for row in category["rows"]:
                    key = row["key"]
                    alias = expected["local"][semantic_page][key]
                    actual_alias = aliases[row["slot"]]
                    if actual_alias != alias:
                        raise SystemExit(
                            f"{semantic_page} row {key} resolved to {actual_alias}, expected {alias}"
                        )
                    seen.add((semantic_page, key))
                    ctx = int(registry[alias]["ctx"])
                    prompt = ctx * 3 // 4
                    output = min(16384, ctx - prompt)
                    emit((
                        f"local-{semantic_page}-{key}",
                        page_input,
                        key,
                        alias,
                        "http://localhost:11435/v1",
                        prompt,
                        output,
                        "on" if row.get("imagegen") else "off",
                        "127.0.0.1",
                    ))
    expected_pages = {"production", "experimental"}
    if platform == "windows":
        expected_pages.add("windows_experimental")
    expected_rows = {
        (page, key)
        for page in expected_pages
        for key in expected["local"][page]
    }
    if seen != expected_rows:
        raise SystemExit(f"local semantic coverage mismatch: seen={seen}, expected={expected_rows}")
elif kind == "server":
    modes = {mode["mode"]: mode for mode in data["modes"]}
    seen = set()
    for category in data["menu"]["categories"]:
        for row in category["rows"]:
            mode = modes[row["mode"]]
            expected_model = expected["server"][row["key"]]
            if mode["model_id"] != expected_model:
                raise SystemExit(
                    f"server row {row['key']} resolved to {mode['model_id']}, expected {expected_model}"
                )
            seen.add(row["key"])
            emit((
                f"server-{row['key']}",
                "3",
                row["key"],
                mode["model_id"],
                f"http://{os.environ.get('ORACLE_SERVER_IP', '127.0.0.1')}:8000/v1",
                mode["max_prompt"],
                mode["max_output"],
                "off" if mode.get("imagegen_disabled", True) else "on",
                os.environ.get("ORACLE_SERVER_IP", "127.0.0.1"),
            ))
    if seen != set(expected["server"]):
        raise SystemExit(f"server semantic coverage mismatch: seen={seen}, expected={set(expected['server'])}")
else:
    raise SystemExit(f"unknown ORACLE_KIND: {kind}")
