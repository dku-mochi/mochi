"""APNs HTTP/2 클라이언트 — httpx(http2) + 직접 ES256 JWT.

aioapns 미채택(추가 의존·추상화 회피). APNs 는 단일 POST /3/device/{token} 이라 직접 호출이 단순.
JWT(ES256, kid=KeyID, iss=TeamID)는 ≤1h 유효해 캐시한다(Apple 권고 20분~60분 재사용).
"""

import time
from typing import Any

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePrivateKey
from cryptography.hazmat.primitives.serialization import load_pem_private_key

from app.core.logging import get_logger
from app.modules.notifications.domain.entities import APNsEnvironment, APNsPushType
from app.modules.notifications.domain.ports import APNsClient

log = get_logger("notifications.apns")

_PROD_HOST = "api.push.apple.com"
_SANDBOX_HOST = "api.sandbox.push.apple.com"
# Apple: provider token 은 발급 후 최소 20분, 최대 60분 재사용 권고. 50분(3000s)에 회전.
_JWT_TTL_SECONDS = 3000


class APNsError(RuntimeError):
    """APNs 가 non-200 을 반환했을 때. 호출부(worker)가 best-effort 로 격리한다.

    status_code/reason 을 담아 호출부가 실패를 분류한다(codex-5): 410 또는 reason 이
    Unregistered/BadDeviceToken 이면 토큰 무효화(영구), 5xx/timeout 은 transient backoff.
    """

    def __init__(self, message: str, *, status_code: int | None = None, reason: str | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.reason = reason


class HttpxAPNsClient(APNsClient):
    def __init__(self, *, team_id: str, key_id: str, p8_pem: str) -> None:
        self._team_id = team_id
        self._key_id = key_id
        key = load_pem_private_key(p8_pem.encode(), password=None)
        if not isinstance(key, EllipticCurvePrivateKey):
            raise ValueError("APNs auth key must be an EC (ES256) private key")
        self._private_key: EllipticCurvePrivateKey = key
        self._client = httpx.AsyncClient(http2=True, timeout=10.0)
        self._jwt_cache: tuple[str, float] | None = None

    def _provider_token(self) -> str:
        now = time.time()
        if self._jwt_cache is not None and now - self._jwt_cache[1] < _JWT_TTL_SECONDS:
            return self._jwt_cache[0]
        token = jwt.encode(
            {"iss": self._team_id, "iat": int(now)},
            self._private_key,
            algorithm="ES256",
            headers={"kid": self._key_id},
        )
        self._jwt_cache = (token, now)
        return token

    async def send(
        self,
        *,
        token: str,
        environment: APNsEnvironment,
        push_type: APNsPushType,
        topic: str,
        payload: dict[str, Any],
        collapse_id: str | None = None,
    ) -> None:
        host = _PROD_HOST if environment == APNsEnvironment.PRODUCTION else _SANDBOX_HOST
        headers = {
            "authorization": f"bearer {self._provider_token()}",
            "apns-topic": topic,
            "apns-push-type": push_type.value,
            # background(silent) push 는 Apple 규격상 priority 5 필수 — 10 이면 스로틀/미전달 위험.
            "apns-priority": "5" if push_type == APNsPushType.BACKGROUND else "10",
        }
        if collapse_id is not None:
            headers["apns-collapse-id"] = collapse_id[:64]
        resp = await self._client.post(f"https://{host}/3/device/{token}", json=payload, headers=headers)
        if resp.status_code != 200:
            # APNs 실패 body 는 {"reason": "..."} JSON — 분류용으로 추출(codex-5).
            reason: str | None = None
            try:
                reason = resp.json().get("reason")
            except Exception:  # noqa: BLE001 - body 가 JSON 이 아니면 reason 없이 진행
                reason = None
            log.warning(
                "apns.failed",
                token=_mask_token(token),
                environment=environment.value,
                push_type=push_type.value,
                topic=topic,
                status_code=resp.status_code,
                reason=reason,
                body=resp.text[:256],
            )
            raise APNsError(
                f"APNs {resp.status_code} for {push_type.value}: {resp.text[:256]}",
                status_code=resp.status_code,
                reason=reason,
            )
        log.info(
            "apns.sent",
            token=_mask_token(token),
            environment=environment.value,
            push_type=push_type.value,
            topic=topic,
            apns_id=resp.headers.get("apns-id"),
        )


def _mask_token(token: str) -> str:
    if len(token) <= 14:
        return f"{token[:4]}...{token[-4:]}"
    return f"{token[:8]}...{token[-6:]}"
