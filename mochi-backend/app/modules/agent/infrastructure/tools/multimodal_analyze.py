import time

from pydantic import BaseModel, Field

from app.modules.agent.domain.tools import Tool, ToolName, ToolUsage
from app.shared.intent import Intent


class MultimodalAnalyzeInput(BaseModel):
    text: str | None = None
    image_object_keys: list[str] = Field(default_factory=list)
    user_memo: str | None = None


class ExtractedEntityDTO(BaseModel):
    kind: str
    value: str


class IntentPayloadDTO(BaseModel):
    """instance 의 구조화 속성 — 전부 optional typed field (lab FINDINGS §19)."""

    title: str | None = None
    date: str | None = None
    time: str | None = None
    end_date: str | None = None
    end_time: str | None = None
    deadline: str | None = None
    person: str | None = None
    topic: str | None = None
    url: str | None = None
    note: str | None = None


class IntentInstanceDTO(BaseModel):
    """LLM 이 저장하기로 한 의도 1개 — 저장되면 곧 active. 점수/위계 없음."""

    intent_type: Intent
    payload: IntentPayloadDTO = Field(default_factory=IntentPayloadDTO)
    label: str = ""
    reasoning: str = ""


class ReviewOptionDTO(BaseModel):
    """needs_review=true 일 때 제시할 미확정 후보 (instance 아님 — DB 미영속, API projection)."""

    intent_type: Intent
    label: str = ""
    reasoning: str = ""


class MultimodalAnalyzeOutput(BaseModel):
    """``finalizeAnalysis`` 가 내는 구조화 분석 (2026-06-04 빅뱅).

    - ``intent_instances``: 저장할 것만(곧 active). 같은 type 다중 허용.
    - ``needs_review``: LLM holistic boolean — 사용자에게 물을지.
    - ``review_options``: needs_review 일 때 제시할 미확정 후보(DB 미영속).
    점수(applicability)·대표(primary)·confidence·threshold 폐기.
    """

    summary: str
    category: str | None = None
    needs_review: bool = False
    intent_instances: list[IntentInstanceDTO] = Field(default_factory=list)
    review_options: list[ReviewOptionDTO] = Field(default_factory=list)
    entities: list[ExtractedEntityDTO] = Field(default_factory=list)
    importance: int = 3
    model_version: str


class MultimodalAnalyzeTool(Tool[MultimodalAnalyzeInput, MultimodalAnalyzeOutput]):
    """Gemini 3 멀티모달 분석 진입점 (현재 미배선 — 스키마 보존용).

    실제 분석은 orchestrator 의 agentic 루프(``finalizeAnalysis``)가 수행한다.
    """

    name = ToolName.MULTIMODAL_ANALYZE
    input_model = MultimodalAnalyzeInput
    output_model = MultimodalAnalyzeOutput

    async def run(self, payload: MultimodalAnalyzeInput) -> tuple[MultimodalAnalyzeOutput, ToolUsage]:
        started = time.perf_counter()
        base = MultimodalAnalyzeOutput(
            summary="",
            category="기타",
            needs_review=False,
            intent_instances=[IntentInstanceDTO(intent_type=Intent.MEMO, label="메모")],
            review_options=[],
            entities=[],
            importance=3,
            model_version="gemini-3-flash@unwired",
        )
        usage = ToolUsage(tokens_in=0, tokens_out=0, latency_ms=int((time.perf_counter() - started) * 1000))
        return base, usage
