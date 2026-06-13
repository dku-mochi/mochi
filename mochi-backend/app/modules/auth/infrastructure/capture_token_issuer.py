"""Opaque capture token 생성/해시 — ``CaptureTokenIssuer`` 구현.

- raw secret: ``mct_`` prefix + 32 byte CSPRNG URL-safe base64 (padding 제거)
- hash: prefix 포함 전체 raw 의 SHA-256 → 64-hex (lowercase)
- TTL: settings.auth_capture_ttl_seconds (sliding — 검증 시 연장은 use case 책임)
"""

import secrets
from datetime import datetime, timedelta

from app.core.config import Settings
from app.modules.auth.domain.entities import CAPTURE_TOKEN_PREFIX
from app.modules.auth.domain.ports import CaptureTokenIssuer
from app.modules.auth.infrastructure.refresh_issuer import _sha256_hex


class OpaqueCaptureTokenIssuer(CaptureTokenIssuer):
    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    def generate(self, *, now: datetime) -> tuple[str, str, datetime]:
        raw = CAPTURE_TOKEN_PREFIX + secrets.token_urlsafe(32)
        token_hash = _sha256_hex(raw)
        expires_at = now + timedelta(seconds=self._settings.auth_capture_ttl_seconds)
        return raw, token_hash, expires_at

    def hash_existing(self, *, raw_secret: str) -> str:
        return _sha256_hex(raw_secret)
