"""API 응답 직렬화 공통 규칙.

FastAPI 기본 ``JSONResponse`` 는 ``datetime.isoformat()`` 을 그대로 써서
microsecond 가 0 일 때만 fractional seconds 를 생략한다 — 같은 필드가
``...:14Z`` 와 ``...:14.010392Z`` 로 들쭉날쭉 나가 클라이언트의 ISO8601
파서를 깨뜨린다. 응답 datetime 필드를 ``UtcDateTime`` 으로 감싸면 항상
microsecond 없는 단일 포맷(``...Z``)으로 직렬화된다.

``WithJsonSchema`` 로 OpenAPI 의 ``format: date-time`` 을 보존해 계약(openapi.json)
diff 가 생기지 않게 한다.
"""

from datetime import UTC, datetime
from typing import Annotated

from pydantic import PlainSerializer, WithJsonSchema


def _serialize_utc(value: datetime) -> str:
    # 소스 datetime 은 naive(`datetime.utcnow()` 관행), UTC-aware, KST-aware 가 섞여 들어온다.
    # naive 는 코드베이스 전반의 가정대로 UTC 로 간주하고, aware 는 UTC 로 환산해
    # 무엇이 와도 항상 microsecond 없는 단일 `...Z` 로 정규화한다.
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


UtcDateTime = Annotated[
    datetime,
    PlainSerializer(_serialize_utc, return_type=str, when_used="json"),
    WithJsonSchema({"type": "string", "format": "date-time"}, mode="serialization"),
]
