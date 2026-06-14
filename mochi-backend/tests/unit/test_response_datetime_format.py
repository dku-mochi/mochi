"""응답 datetime 직렬화 포맷 회귀 가드.

FastAPI 기본 ``isoformat()`` 은 microsecond 가 0 일 때만 fractional seconds 를
생략해 같은 필드가 ``...:14Z`` / ``...:14.010392Z`` 로 들쭉날쭉 나갔고, 이게
클라이언트의 ISO8601 파서를 깨뜨렸다. ``app.core.schema.UtcDateTime`` 으로
항상 microsecond 없는 단일 ``...Z`` 포맷이 나오는지 고정한다.
"""

import json
from datetime import UTC, datetime, timedelta, timezone

from pydantic import BaseModel

from app.core.schema import UtcDateTime
from app.modules.auth.presentation.schemas import TokensResponse, UserResponse


class _Probe(BaseModel):
    at: UtcDateTime


def _serialize(value: datetime) -> str:
    return json.loads(_Probe(at=value).model_dump_json())["at"]


def _tokens_json(microsecond: int) -> dict:
    response = TokensResponse(
        access_token="a",
        access_token_expires_at=datetime(2026, 6, 13, 12, 51, 14, microsecond, tzinfo=UTC),
        refresh_token="r",
        refresh_token_expires_at=datetime(2026, 6, 13, 12, 51, 14, microsecond, tzinfo=UTC),
    )
    return json.loads(response.model_dump_json(by_alias=True))


def test_datetime_serialized_without_fractional_seconds() -> None:
    assert _tokens_json(10392)["accessTokenExpiresAt"] == "2026-06-13T12:51:14Z"


def test_datetime_format_deterministic_across_microseconds() -> None:
    # microsecond 0 / 비0 모두 동일 포맷이어야 한다 (원래 버그: 0 일 때만 소수점 생략).
    assert _tokens_json(0)["accessTokenExpiresAt"] == _tokens_json(999999)["accessTokenExpiresAt"]


def test_naive_datetime_treated_as_utc() -> None:
    # capture(`POST /mochi_items`)·presign 경로는 DB 재조회 없이 naive `datetime.utcnow()` 를
    # 그대로 반환한다 — naive 도 UTC 로 간주해 `...Z` 가 붙어야 한다.
    assert _serialize(datetime(2026, 6, 13, 12, 51, 14)) == "2026-06-13T12:51:14Z"


def test_offset_aware_datetime_normalized_to_utc() -> None:
    # KST-aware(`+09:00`) deadline 도 UTC 로 환산해 단일 `...Z` 로 통일.
    kst = timezone(timedelta(hours=9))
    assert _serialize(datetime(2026, 6, 13, 21, 51, 14, tzinfo=kst)) == "2026-06-13T12:51:14Z"


def test_optional_datetime_none_serializes_null() -> None:
    response = UserResponse(
        id="00000000-0000-0000-0000-000000000001",
        email="a@b.com",
        display_name="x",
        locale="ko",
        onboarding_completed_at=None,
    )
    assert json.loads(response.model_dump_json(by_alias=True))["onboardingCompletedAt"] is None
