"""월간 정리(monthly digest) LLM outbound port.

agent 모듈의 function-calling ``LLMClient`` 와 별개 — 단발 structured-output 1회 호출용.
카테고리 정규화(fine→coarse 매핑)와 "모찌의 한마디"(greeting)를 한 번에 받는다.
domain layer 라 google/sqlalchemy 등 인프라 의존 없이 Protocol + DTO 만 둔다.
"""

from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True, slots=True)
class DigestInputItem:
    """LLM 에 보낼 그 달 항목 1건 — fine category + 대표 텍스트(요약).

    raw 캡처 본문은 보내지 않는다(PRIVACY 최소전송 — 프로필 요약기와 동일 원칙).
    """

    category: str | None
    title: str | None


@dataclass(frozen=True, slots=True)
class CategoryGroup:
    """fine 카테고리들을 묶은 coarse 그룹 (파편화 정규화 결과)."""

    coarse: str
    fines: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class MonthlyDigestLLMResult:
    greeting: str
    category_groups: tuple[CategoryGroup, ...]


class MonthlyDigestLLM(Protocol):
    """그 달 항목을 받아 greeting + 카테고리 재그룹핑을 1회 생성한다.

    ``known_categories`` 는 기존에 자주 쓰인 정규화 라벨 — 재사용을 우선해 달별 흔들림을 줄인다.
    LLM 은 item id 를 다루지 않는다(매핑 적용은 application 이 fine→coarse dict 로 수행).
    """

    async def generate(
        self,
        *,
        items: list[DigestInputItem],
        item_count: int,
        known_categories: list[str],
    ) -> MonthlyDigestLLMResult: ...
