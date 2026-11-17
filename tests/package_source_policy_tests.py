"""Regression checks for source-archive inclusion and machine-local exclusions."""
import ast
from pathlib import Path


root = Path(__file__).resolve().parents[1]
tree = ast.parse((root / "scripts" / "package.py").read_text(encoding="utf-8"))
needed = {"EXCLUDED_DIRS", "EXCLUDED_SUFFIXES", "in_source"}
nodes = [
    node for node in tree.body
    if (isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id in needed
        for target in node.targets
    )) or (isinstance(node, ast.FunctionDef) and node.name == "in_source")
]
namespace = {"Path": Path}
exec(compile(ast.Module(body=nodes, type_ignores=[]), "scripts/package.py", "exec"), namespace)
included = namespace["in_source"]

checks = {
    "exclude linked-worktree Git pointer": not included(Path(".git")),
    "exclude generated reports from their own source ZIP": all(
        not included(Path(path)) for path in (
            "docs/V1.4.0_AUTONOMOUS_COMPLETION_PROGRESS.md",
            "docs/V1.4.0_ACCEPTANCE_MATRIX.json",
            "docs/V1.4.0_FINAL_COMPLETION_AUDIT.md",
            "docs/V1.4.0_FINAL_PRE_RELEASE_VERIFICATION.md",
        )
    ),
    "include public acceptance workflow": included(
        Path(".github/workflows/windows-v1.4.0-updater-acceptance.yml")
    ),
    "include updater metadata regression test": included(
        Path("tests/updater_metadata_tests.cpp")
    ),
    "exclude generated executables": all(
        not included(Path(path)) for path in (
            "release/EyeBreakReminder.exe",
            "build/updater-metadata-tests.exe",
            "tests/core-tests.exe",
        )
    ),
}

for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'}: {name}")
if not all(checks.values()):
    raise SystemExit(1)
