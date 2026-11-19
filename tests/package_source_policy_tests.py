"""Regression checks for source-archive inclusion and machine-local exclusions."""
import ast
import re
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
verify_source = (root / "scripts" / "verify.py").read_text(encoding="utf-8")
update_client = (root / "src" / "update_client.hpp").read_text(encoding="utf-8")
loopback_certificate_policy = re.search(
    r"#ifdef EYEBREAK_TEST_BUILD\s*\ninline bool configureLoopbackTestCertificate\([^\n]+\)\s*\{(?P<body>.*?)\n\}\s*\n#endif",
    update_client,
    re.DOTALL,
)
loopback_certificate_region = loopback_certificate_policy.group(0) if loopback_certificate_policy else ""
loopback_certificate_body = loopback_certificate_policy.group("body") if loopback_certificate_policy else ""

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
    "include focused exact-candidate acceptance workflow": included(
        Path(".github/workflows/windows-v1.4.0-focused-acceptance.yml")
    ),
    "include signed update security verification workflow": included(
        Path(".github/workflows/windows-v1.4.0-update-security.yml")
    ),
    "include the manually dispatched development-candidate build and audit": included(
        Path(".github/workflows/windows-v1.4.0-development-candidate.yml")
    ),
    "include updater metadata regression test": included(
        Path("tests/updater_metadata_tests.cpp")
    ),
    "timeout harness avoids Windows certificate-store operations": all(
        token not in (root / "tests" / "windows_download_stall_timeout_acceptance.ps1").read_text(encoding="utf-8")
        for token in ("Import-Certificate", "X509Store", "CurrentUser\\Root")
    ),
    "limit test-only unknown-CA exception to the exact localhost request": all(
        item in loopback_certificate_region for item in (
            "#ifdef EYEBREAK_TEST_BUILD",
            "_wcsicmp(url.host.c_str(),L\"localhost\")==0",
            "url.port>=1024",
            "EBR_TEST_ALLOW_UNTRUSTED_LOOPBACK_CERT",
            "SECURITY_FLAG_IGNORE_UNKNOWN_CA",
            "return true;",
        )
    ),
    "exclude generated executables": all(
        not included(Path(path)) for path in (
            "release/EyeBreakReminder.exe",
            "build/updater-metadata-tests.exe",
            "tests/core-tests.exe",
        )
    ),
    "verifier excludes live v1.4.0 evidence from source completeness": all(
        f"Path('{path}')" in verify_source for path in (
            "docs/V1.4.0_AUTONOMOUS_COMPLETION_PROGRESS.md",
            "docs/V1.4.0_ACCEPTANCE_MATRIX.json",
            "docs/V1.4.0_FINAL_COMPLETION_AUDIT.md",
        )
    ),
}

for name, passed in checks.items():
    print(f"{'PASS' if passed else 'FAIL'}: {name}")
if not all(checks.values()):
    raise SystemExit(1)
