"""Keep standard-user acceptance evidence names aligned with the workflow gate."""
import re
from pathlib import Path


root = Path(__file__).resolve().parents[1]
workflow = (root / ".github" / "workflows" / "windows-v1.4.0-updater-acceptance.yml").read_text(encoding="utf-8")
harness = (root / "tests" / "windows_standard_user_acceptance.ps1").read_text(encoding="utf-8")

required_block = re.search(
    r"\$requiredEvents\s*=\s*@\((?P<body>.*?)\n\s*\)", workflow, re.DOTALL
)
standard_events_block = re.search(
    r"\$standardUserAcceptanceEventNames\s*=\s*\[ordered\]@\{(?P<body>.*?)\n\s*\}",
    harness,
    re.DOTALL,
)
owner_events_block = re.search(
    r"\$activeConsoleAcceptanceEventNames\s*=\s*\[ordered\]@\{(?P<body>.*?)\n\s*\}",
    harness,
    re.DOTALL,
)

failures = []
if not required_block:
    failures.append("workflow required-event block was not found")
if not standard_events_block:
    failures.append("standard-user event-name map was not found")
if not owner_events_block:
    failures.append("active-console event-name map was not found")

if required_block and standard_events_block and owner_events_block:
    required = re.findall(r"'([^']+)'", required_block.group("body"))
    standard_map = dict(
        re.findall(r"(?m)^\s*([A-Za-z]\w*)='([^']*)'\s*$", standard_events_block.group("body"))
    )
    standard_names = list(standard_map.values())
    owner_keys = re.findall(r"(?m)^\s*([A-Za-z]\w*)=", owner_events_block.group("body"))

    if len(required) != 7 or len(set(required)) != len(required):
        failures.append(f"expected seven unique workflow event names, found {len(required)}")
    if set(required) != set(standard_names) or len(standard_names) != len(required):
        failures.append("standard-user event map does not exactly match the workflow's required event names")
    if set(owner_keys) != set(standard_map):
        failures.append("active-console and standard-user event maps do not have matching keys")

    for key in standard_map:
        if key == "InstalledLaunch":
            emitted = (
                "$launchEventName=$acceptanceEventNames.InstalledLaunch" in harness
                and "Name=$launchEventName" in harness
            )
        else:
            emitted = f"Name=$acceptanceEventNames.{key}" in harness
        if not emitted:
            failures.append(f"event map key {key} is not connected to its emitted event")

    if "$acceptanceEventNames=if($AllowActiveConsoleAdministrator){$activeConsoleAcceptanceEventNames}else{$standardUserAcceptanceEventNames}" not in harness:
        failures.append("event-map selection does not preserve the distinct standard-user and active-console paths")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    raise SystemExit(1)

print("PASS: standard-user event names exactly match all workflow-gated events")
print("PASS: each required event is connected to its emitted result")
print("PASS: active-console-owner event map remains separate with the same keys")
