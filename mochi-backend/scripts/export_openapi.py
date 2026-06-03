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
from typing import Any

# 패키지 외부 단독 실행에서도 `app` 패키지를 import 할 수 있도록 sys.path 보강.
_REPO_ROOT = Path(__file__).resolve().parents[1]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from app.main import app  # noqa: E402


def _downgrade_nullable_to_30(node: Any) -> Any:
    """OpenAPI 3.1 의 ``anyOf: [X, {"type": "null"}]`` 를 3.0 의 ``X + nullable: true`` 로 낮춘다.

    swift-openapi-generator 1.12.2 는 3.1 의 ``{"type": "null"}`` 을 지원하지 않아 해당 필드를
    통째로 skip 한다 (url/text/summary/agentRunId/Idempotency-Key 누락). 계약의 *의미*(nullable)
    는 그대로 두고 *문법*만 3.0 으로 낮춰 iOS 생성 클라이언트가 모든 optional 필드를 받게 한다.
    """
    if isinstance(node, dict):
        any_of = node.get("anyOf")
        if isinstance(any_of, list):
            non_null = [
                s for s in any_of if not (isinstance(s, dict) and s.get("type") == "null")
            ]
            if (
                len(non_null) != len(any_of)
                and len(non_null) == 1
                and isinstance(non_null[0], dict)
            ):
                merged = {k: v for k, v in node.items() if k != "anyOf"}
                merged.update(non_null[0])
                merged["nullable"] = True
                return _downgrade_nullable_to_30(merged)
        return {k: _downgrade_nullable_to_30(v) for k, v in node.items()}
    if isinstance(node, list):
        return [_downgrade_nullable_to_30(item) for item in node]
    return node


def _drop_422_responses(schema: dict[str, Any]) -> None:
    """FastAPI 가 자동 추가하는 ``422 → HTTPValidationError`` 응답 문서를 제거한다.

    백엔드는 validation 실패도 공통 에러 envelope(`common.validation_failed`,
    `core/error_envelope.py:handle_validation_exception`)로 내려보내므로, openapi 의
    `422 → HTTPValidationError` 문서는 *실제 응답과 어긋난다*. 제거하면 generator 가 422 를
    `.undocumented` 로 처리해 다른 에러(400/401/404/429/503)와 동일하게 iOS 어댑터가 envelope 를
    디코드한다(요청추적 `requestId`·`code` 보존). 문서화된 422 만 envelope 를 유실하던 회귀 해소.
    """
    for path_item in schema.get("paths", {}).values():
        if not isinstance(path_item, dict):
            continue
        for operation in path_item.values():
            if isinstance(operation, dict) and isinstance(operation.get("responses"), dict):
                operation["responses"].pop("422", None)


def _assert_no_residual_null(node: Any, path: str = "") -> None:
    """3.0 변환 후 `{"type": "null"}` 이 남아 있으면 generator 가 또 skip 하므로 fail-fast.

    ``_downgrade_nullable_to_30`` 은 단일 non-null `anyOf` 만 변환한다. union nullable
    (non-null 2개+) 이나 미처리 형태가 새로 들어오면 조용히 stale 생성물을 만들기 전에 멈춘다.
    """
    if isinstance(node, dict):
        if node.get("type") == "null":
            raise SystemExit(
                f"export_openapi: 미변환 'type: null' 잔존 at '{path}' — "
                "_downgrade_nullable_to_30 확장 필요 (generator 가 skip 함)."
            )
        for key, value in node.items():
            _assert_no_residual_null(value, f"{path}/{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            _assert_no_residual_null(value, f"{path}[{index}]")


def main() -> None:
    schema = app.openapi()
    schema = _downgrade_nullable_to_30(schema)
    _drop_422_responses(schema)
    _assert_no_residual_null(schema)
    schema["openapi"] = "3.0.3"
    json.dump(schema, sys.stdout, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
