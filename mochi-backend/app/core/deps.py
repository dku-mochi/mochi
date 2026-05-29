from functools import lru_cache
from typing import Annotated

from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.db import get_session
from app.modules.agent.domain.ports import LLMClient
from app.modules.agent.domain.profile import UserProfileSummarizer
from app.modules.agent.infrastructure.gemini_agent_client import GeminiAgentClient
from app.modules.agent.infrastructure.gemini_profile_summarizer import GeminiProfileSummarizer
from app.modules.mochi_items.domain.ports import CaptureImageStorage
from app.modules.mochi_items.infrastructure.gcs_storage import GCSSignedUrlIssuer

DBSession = Annotated[AsyncSession, Depends(get_session)]


@lru_cache(maxsize=1)
def _capture_storage_singleton() -> CaptureImageStorage | None:
    settings = get_settings()
    if not settings.gcs_capture_bucket or not settings.gcs_signer_service_account:
        return None
    return GCSSignedUrlIssuer(
        bucket=settings.gcs_capture_bucket,
        prefix=settings.gcs_capture_prefix,
        signer_email=settings.gcs_signer_service_account,
        ttl_seconds=settings.gcs_signed_url_ttl_seconds,
    )


def get_capture_storage() -> CaptureImageStorage | None:
    """캡처 이미지 Signed URL 발급기 (프로세스당 1개). 미설정 시 ``None`` → presign 503."""
    return _capture_storage_singleton()


CaptureImageStorageDep = Annotated[CaptureImageStorage | None, Depends(get_capture_storage)]


@lru_cache(maxsize=1)
def _agent_llm_singleton() -> LLMClient:
    return GeminiAgentClient()


def get_agent_llm() -> LLMClient:
    """Agent loop 용 Gemini function-calling 클라이언트 (프로세스당 1개)."""
    return _agent_llm_singleton()


@lru_cache(maxsize=1)
def _profile_summarizer_singleton() -> UserProfileSummarizer:
    return GeminiProfileSummarizer()


def get_profile_summarizer() -> UserProfileSummarizer:
    """개인화 프로필 요약기 (프로세스당 1개)."""
    return _profile_summarizer_singleton()
