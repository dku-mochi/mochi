from functools import lru_cache
from typing import Annotated

from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import get_session
from app.modules.agent.domain.ports import LLMClient
from app.modules.agent.domain.profile import UserProfileSummarizer
from app.modules.agent.infrastructure.gemini_agent_client import GeminiAgentClient
from app.modules.agent.infrastructure.gemini_profile_summarizer import GeminiProfileSummarizer
from app.modules.mochi_items.domain.ports import IntentClassifier
from app.modules.mochi_items.infrastructure.gemini_classifier import VertexAIGeminiClassifier

DBSession = Annotated[AsyncSession, Depends(get_session)]


@lru_cache(maxsize=1)
def _intent_classifier_singleton() -> IntentClassifier:
    return VertexAIGeminiClassifier()


def get_intent_classifier() -> IntentClassifier:
    """프로세스당 1개의 Vertex AI client 를 공유한다 — adapter 안에서 lru_cache."""
    return _intent_classifier_singleton()


IntentClassifierDep = Annotated[IntentClassifier, Depends(get_intent_classifier)]


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
