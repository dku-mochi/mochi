"""Agent ↔ MochiItem 모듈 사이의 얇은 outbound port.

orchestrator 는 이 포트에만 의존해 (1) 분석 입력을 로드하고, (2) 분석 결과를
write-back 하고, (3) 개인화 프로필용 최근 window 를 읽는다. 구현체
(`infrastructure/mochi_item_gateway.py`)가 `mochi_items.application` 경계를 통해
실제 저장소에 접근한다 — orchestrator 는 infrastructure 를 모른다 (테스트는 fake 주입).

프레임워크 의존 없음 (domain layer).
"""

from dataclasses import dataclass
from typing import Protocol
from uuid import UUID

from app.modules.agent.domain.analysis import AnalysisResult
from app.modules.agent.domain.profile import ProfileWindowItem


@dataclass(frozen=True, slots=True)
class AnalysisInput:
    """LLM 분석에 필요한 한 MochiItem 의 원천 콘텐츠."""

    text: str | None
    url: str | None
    user_memo: str | None
    # image_object_keys 는 blob storage wire 이후 추가 (현재 워커엔 이미지 bytes 없음).


class MochiItemGateway(Protocol):
    async def load_source(
        self, *, owner_id: UUID, mochi_item_id: UUID
    ) -> AnalysisInput | None: ...

    async def apply_analysis(
        self, *, owner_id: UUID, mochi_item_id: UUID, result: AnalysisResult
    ) -> None: ...

    async def list_recent_window(
        self, *, owner_id: UUID, limit: int
    ) -> list[ProfileWindowItem]: ...

    async def count_items(self, *, owner_id: UUID) -> int: ...
