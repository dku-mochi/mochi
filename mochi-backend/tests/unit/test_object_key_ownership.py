"""P1-1 회귀 — ingest 진입점이 object_key 를 인증 사용자 prefix 로 강제하는가 (IDOR 방지).

presign 은 `{prefix}/{owner_id}/{sha}.{ext}` 만 발급한다. 다른 사용자의 object_key 를
보내 cross-tenant 원본을 Gemini 로 분석시키는 것을 막아야 한다.
"""

from uuid import uuid4

import pytest

from app.core.config import get_settings
from app.core.error_envelope import DomainError
from app.modules.mochi_items.presentation.router import _require_owned_object_key

_PREFIX = get_settings().gcs_capture_prefix


def test_accepts_own_object_key() -> None:
    owner = uuid4()
    _require_owned_object_key(f"{_PREFIX}/{owner}/abc.png", owner_id=owner)  # no raise


def test_rejects_other_owner_object_key() -> None:
    owner = uuid4()
    other = uuid4()
    with pytest.raises(DomainError):
        _require_owned_object_key(f"{_PREFIX}/{other}/abc.png", owner_id=owner)


def test_rejects_prefix_lookalike() -> None:
    """owner uuid 로 시작하지만 디렉토리 경계(`/`)가 아닌 prefix-confusion 도 거부."""
    owner = uuid4()
    with pytest.raises(DomainError):
        _require_owned_object_key(f"{_PREFIX}/{owner}x/abc.png", owner_id=owner)
