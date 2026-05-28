"""Opaque refresh token 생성/해시 — ``RefreshTokenIssuer`` 구현.

- raw secret: 32 byte CSPRNG → URL-safe base64 (padding 제거) → 43 chars
- hash: SHA-256 → 64-hex (lowercase)
- TTL: settings.auth_refresh_ttl_seconds
"""

import hashlib
import secrets
from datetime import datetime, timedelta

from app.core.config import Settings
from app.modules.auth.domain.ports import RefreshTokenIssuer


def _sha256_hex(secret: str) -> str:
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


class OpaqueRefreshTokenIssuer(RefreshTokenIssuer):
    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    def generate(self, *, now: datetime) -> tuple[str, str, datetime]:
        raw = secrets.token_urlsafe(32)  # ~43 chars
        token_hash = _sha256_hex(raw)
        expires_at = now + timedelta(seconds=self._settings.auth_refresh_ttl_seconds)
        return raw, token_hash, expires_at

    def hash_existing(self, *, raw_secret: str) -> str:
        return _sha256_hex(raw_secret)
