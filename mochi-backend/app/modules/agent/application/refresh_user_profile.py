"""사용자 개인화 프로필의 디바운스 갱신 use case.

쓸수록 좋아진다: 누적 항목이 마지막 요약 이후 N개 이상 늘었거나 프로필이 없으면
최근 window 를 재요약해 upsert 한다. 매 ingest 가 아니라 N개마다 → LLM 비용 bound.
사용자가 intent 를 override 하면 그 정정이 다음 window 에 자연히 포함돼 반영된다.
"""

from datetime import datetime
from uuid import UUID

from app.core.logging import get_logger
from app.modules.agent.domain.gateway import MochiItemGateway
from app.modules.agent.domain.profile import (
    UserProfile,
    UserProfileStore,
    UserProfileSummarizer,
)

log = get_logger("agent.profile")


class RefreshUserProfile:
    def __init__(
        self,
        *,
        gateway: MochiItemGateway,
        store: UserProfileStore,
        summarizer: UserProfileSummarizer,
        window_size: int,
        refresh_every_n: int,
        model_version: str,
    ):
        self._gateway = gateway
        self._store = store
        self._summarizer = summarizer
        self._window_size = window_size
        self._refresh_every_n = refresh_every_n
        self._model_version = model_version

    async def run(self, *, owner_id: UUID) -> bool:
        """갱신했으면 True, 디바운스로 skip 했으면 False."""
        total = await self._gateway.count_items(owner_id=owner_id)
        if total == 0:
            return False
        profile = await self._store.get(owner_id=owner_id)
        due = profile is None or (total - profile.items_covered) >= self._refresh_every_n
        if not due:
            return False

        window = await self._gateway.list_recent_window(owner_id=owner_id, limit=self._window_size)
        summary = await self._summarizer.summarize(
            window=window, previous=profile.summary if profile else None
        )
        if not summary:
            return False

        # 채팅용 페르소나도 같은 window 로 distill (LLM 1콜 추가). 부가 산출물이라 실패해도
        # 분류 프로필 저장을 막지 않고, 결과가 비면 이전 값을 유지한다.
        chat_summary = profile.chat_summary if profile else None
        try:
            new_chat = await self._summarizer.summarize_chat(window=window, previous=chat_summary)
            if new_chat:
                chat_summary = new_chat
        except Exception as exc:  # noqa: BLE001
            log.warning("profile.chat_summary_failed", owner_id=str(owner_id), exception=str(exc))

        await self._store.upsert(
            UserProfile(
                owner_id=owner_id,
                summary=summary,
                model_version=self._model_version,
                items_covered=total,
                refreshed_at=datetime.utcnow(),
                chat_summary=chat_summary,
            )
        )
        log.info("profile.refreshed", owner_id=str(owner_id), items_covered=total)
        return True
