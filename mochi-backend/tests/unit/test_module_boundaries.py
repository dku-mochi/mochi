"""모듈 경계 검사.

다른 모듈의 `infrastructure/` 또는 `presentation/` 내부를 직접 import하면 실패.
허용된 cross-module 진입은 `domain/` 와 `application/`, 그리고 모든 모듈이 공통으로 쓰는 `app.shared` 와 `app.core` 뿐이다.
"""

import ast
from pathlib import Path

import pytest

APP_DIR = Path(__file__).resolve().parents[2] / "app"
MODULES_DIR = APP_DIR / "modules"

MODULE_NAMES = [p.name for p in MODULES_DIR.iterdir() if p.is_dir() and not p.name.startswith("__")]


def _python_files(directory: Path) -> list[Path]:
    return [p for p in directory.rglob("*.py") if "__pycache__" not in p.parts]


def _imports_in(path: Path) -> set[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    out: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                out.add(alias.name)
        elif isinstance(node, ast.ImportFrom) and node.module:
            out.add(node.module)
    return out


@pytest.mark.parametrize("module_name", MODULE_NAMES)
def test_module_does_not_reach_into_other_modules_infrastructure(module_name: str) -> None:
    violations: list[tuple[str, str]] = []
    for path in _python_files(MODULES_DIR / module_name):
        for imp in _imports_in(path):
            if not imp.startswith("app.modules."):
                continue
            parts = imp.split(".")
            # ['app', 'modules', '<other>', 'infrastructure'|'presentation', ...]
            if len(parts) < 5:
                continue
            other_module = parts[2]
            inner = parts[3]
            if other_module == module_name:
                continue
            if inner in {"infrastructure", "presentation"}:
                violations.append((str(path.relative_to(APP_DIR)), imp))

    assert not violations, (
        f"{module_name} module reaches into other modules' infrastructure/presentation: {violations}"
    )


@pytest.mark.parametrize("module_name", MODULE_NAMES)
def test_domain_layer_has_no_framework_dependencies(module_name: str) -> None:
    forbidden_prefixes = ("sqlalchemy", "fastapi", "httpx", "google", "pgvector")
    violations: list[tuple[str, str]] = []
    domain_dir = MODULES_DIR / module_name / "domain"
    if not domain_dir.exists():
        return
    for path in _python_files(domain_dir):
        for imp in _imports_in(path):
            if any(imp.startswith(prefix) for prefix in forbidden_prefixes):
                violations.append((str(path.relative_to(APP_DIR)), imp))
    assert not violations, f"domain layer of {module_name} imports framework code: {violations}"
