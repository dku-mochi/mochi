"""GCS V4 Signed URL 발급 어댑터 (``CaptureImageStorage`` 구현체).

클라이언트가 Signed PUT URL 로 GCS 에 직접 업로드한다 — 서버는 이미지 bytes 를 만지지 않는다.
서명은 키 파일 없이 impersonated service account(IAM signBlob)로 수행한다 (ADC → SA token).

- object_key 컨벤션: ``{prefix}/{owner_id}/{sha256}.{ext}`` — content-addressed, 멱등.
- Gemini 가 ``gs://{bucket}/{object_key}`` 로 직접 읽으므로 다운로드 경로는 없다.
"""

import asyncio
from datetime import datetime, timedelta
from functools import lru_cache
from uuid import UUID

from google.auth import default as google_auth_default
from google.auth import impersonated_credentials
from google.cloud import storage

from app.core.config import get_settings
from app.modules.mochi_items.domain.ports import ObjectStat, SignedDownload, SignedUpload

_EXT = {"image/png": "png", "image/jpeg": "jpg"}
_SIGN_SCOPES = ["https://www.googleapis.com/auth/devstorage.read_write"]


@lru_cache(maxsize=1)
def _client() -> storage.Client:
    return storage.Client(project=get_settings().google_cloud_project)


@lru_cache(maxsize=1)
def _signer_credentials(signer_email: str) -> impersonated_credentials.Credentials:
    """ADC 를 source 로 SA 를 impersonate — generate_signed_url 이 signBlob 으로 서명."""
    source, _ = google_auth_default()
    return impersonated_credentials.Credentials(  # type: ignore[no-untyped-call]
        source_credentials=source,
        target_principal=signer_email,
        target_scopes=_SIGN_SCOPES,
    )


class GCSSignedUrlIssuer:
    """``CaptureImageStorage`` 구현 — V4 Signed PUT URL 발급."""

    def __init__(self, *, bucket: str, prefix: str, signer_email: str, ttl_seconds: int):
        self._bucket = bucket
        self._prefix = prefix
        self._signer_email = signer_email
        self._ttl = ttl_seconds

    async def issue_upload_url(self, *, owner_id: UUID, sha256: str, mime_type: str) -> SignedUpload:
        ext = _EXT.get(mime_type, "bin")
        object_key = f"{self._prefix}/{owner_id}/{sha256}.{ext}"
        url = await asyncio.to_thread(self._sign_put, object_key, mime_type)
        return SignedUpload(
            object_key=object_key,
            upload_url=url,
            expires_at=datetime.utcnow() + timedelta(seconds=self._ttl),
        )

    def _sign_put(self, object_key: str, mime_type: str) -> str:
        blob = _client().bucket(self._bucket).blob(object_key)
        url: str = blob.generate_signed_url(
            version="v4",
            expiration=timedelta(seconds=self._ttl),
            method="PUT",
            content_type=mime_type,
            credentials=_signer_credentials(self._signer_email),
        )
        return url

    async def issue_download_url(self, *, object_key: str) -> SignedDownload:
        url = await asyncio.to_thread(self._sign_get, object_key)
        return SignedDownload(
            download_url=url,
            expires_at=datetime.utcnow() + timedelta(seconds=self._ttl),
        )

    def _sign_get(self, object_key: str) -> str:
        blob = _client().bucket(self._bucket).blob(object_key)
        url: str = blob.generate_signed_url(
            version="v4",
            expiration=timedelta(seconds=self._ttl),
            method="GET",
            credentials=_signer_credentials(self._signer_email),
        )
        return url

    async def stat(self, *, object_key: str) -> ObjectStat | None:
        return await asyncio.to_thread(self._stat_sync, object_key)

    def _stat_sync(self, object_key: str) -> ObjectStat | None:
        # get_blob 은 객체 metadata(HEAD)를 가져온다(없으면 None) — bytes 다운로드 아님.
        blob = _client().bucket(self._bucket).get_blob(object_key)
        if blob is None:
            return None
        return ObjectStat(size=blob.size or 0, content_type=blob.content_type)
