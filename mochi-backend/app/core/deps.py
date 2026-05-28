from functools import lru_cache
from typing import Annotated

from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import get_session
from app.modules.captures.domain.ports import IntentClassifier
from app.modules.captures.infrastructure.gemini_classifier import VertexAIGeminiClassifier

DBSession = Annotated[AsyncSession, Depends(get_session)]


@lru_cache(maxsize=1)
def _intent_classifier_singleton() -> IntentClassifier:
    return VertexAIGeminiClassifier()


def get_intent_classifier() -> IntentClassifier:
    """프로세스당 1개의 Vertex AI client 를 공유한다 — adapter 안에서 lru_cache."""
    return _intent_classifier_singleton()


IntentClassifierDep = Annotated[IntentClassifier, Depends(get_intent_classifier)]
