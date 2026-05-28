"""백엔드 `/api/v1` OpenAPI 스펙을 정적 JSON으로 추출.

iOS `swift-openapi-generator` 가 빌드 타임에 이 파일을 소스로 사용한다.
사용법:
    uv run python -m scripts.export_openapi > openapi.json
    또는
    PYTHONPATH=. uv run python scripts/export_openapi.py > openapi.json
"""

import json
import sys
from pathlib import Path

# 패키지 외부 단독 실행에서도 `app` 패키지를 import 할 수 있도록 sys.path 보강.
_REPO_ROOT = Path(__file__).resolve().parents[1]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from app.main import app  # noqa: E402


def main() -> None:
    schema = app.openapi()
    json.dump(schema, sys.stdout, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
