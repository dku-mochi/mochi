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


class CandidateDTO(BaseModel):
    """LLM 이 펼친 use case 후보 1개 — label(한국어)/intent/applicability/reasoning."""

    label: str = Field(min_length=1)
    intent: Intent
    applicability: float = Field(ge=0.0, le=1.0)
    reasoning: str = ""


class MultimodalAnalyzeOutput(BaseModel):
    """``finalizeAnalysis`` 가 내는 구조화 분석.

    primary intent / confidence / secondary_intents 는 ``candidates`` 의 applicability 에서
    orchestrator 가 derive 하므로 LLM 출력 필드에 두지 않는다 (단일 원천).
    """

    summary: str
    candidates: list[CandidateDTO] = Field(min_length=1, max_length=3)
    entities: list[ExtractedEntityDTO] = Field(default_factory=list)
    tags: list[str] = Field(default_factory=list)
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
            candidates=[CandidateDTO(label="메모", intent=Intent.MEMO, applicability=0.0)],
            entities=[],
            tags=[],
            importance=3,
            model_version="gemini-3-flash@unwired",
        )
        usage = ToolUsage(tokens_in=0, tokens_out=0, latency_ms=int((time.perf_counter() - started) * 1000))
        return base, usage
