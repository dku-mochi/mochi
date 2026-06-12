import base64
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
from app.modules.conversations.domain.ports import ChatLLMClient
from app.modules.conversations.infrastructure.gemini_chat_client import GeminiChatClient
from app.modules.mochi_items.domain.ports import CaptureImageStorage
from app.modules.mochi_items.infrastructure.gcs_storage import GCSSignedUrlIssuer
from app.modules.notifications.domain.ports import APNsClient
from app.modules.notifications.infrastructure.apns_client import HttpxAPNsClient
from app.shared.voyage import VoyageClient

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
def _chat_llm_singleton() -> ChatLLMClient:
    return GeminiChatClient()


def get_chat_llm() -> ChatLLMClient:
    """채팅 run 용 Gemini 스트리밍 클라이언트 (프로세스당 1개)."""
    return _chat_llm_singleton()


@lru_cache(maxsize=1)
def _profile_summarizer_singleton() -> UserProfileSummarizer:
    return GeminiProfileSummarizer()


def get_profile_summarizer() -> UserProfileSummarizer:
    """개인화 프로필 요약기 (프로세스당 1개)."""
    return _profile_summarizer_singleton()


@lru_cache(maxsize=1)
def _apns_client_singleton() -> APNsClient | None:
    settings = get_settings()
    if not settings.apns_auth_key_p8_base64:
        return None
    p8_pem = base64.b64decode(settings.apns_auth_key_p8_base64).decode()
    return HttpxAPNsClient(
        team_id=settings.apns_team_id,
        key_id=settings.apns_key_id,
        p8_pem=p8_pem,
    )


def get_apns_client() -> APNsClient | None:
    """APNs HTTP/2 클라이언트 (프로세스당 1개). p8 미설정 시 ``None`` → push no-op."""
    return _apns_client_singleton()


@lru_cache(maxsize=1)
def _voyage_client_singleton() -> VoyageClient | None:
    settings = get_settings()
    if not settings.voyage_api_key:
        return None
    return VoyageClient(
        settings.voyage_api_key,
        embedding_model=settings.voyage_embedding_model,
        embedding_dim=settings.voyage_embedding_dim,
        rerank_model=settings.voyage_rerank_model,
    )


def get_voyage_client() -> VoyageClient | None:
    """Voyage 임베딩·리랭크 클라이언트 (프로세스당 1개). 키 미설정 시 ``None`` —
    vector·rerank 경로가 비활성화되고 검색은 BM25/키워드로 degrade 한다."""
    return _voyage_client_singleton()
