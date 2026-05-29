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


class MultimodalAnalyzeOutput(BaseModel):
    summary: str
    intent: Intent
    secondary_intents: list[Intent] = Field(default_factory=list)
    entities: list[ExtractedEntityDTO] = Field(default_factory=list)
    tags: list[str] = Field(default_factory=list)
    importance: int = 3
    confidence: float = 0.0
    model_version: str


class MultimodalAnalyzeTool(Tool[MultimodalAnalyzeInput, MultimodalAnalyzeOutput]):
    """Gemini 3 멀티모달 분석 진입점.

    실제 구현은 google-genai의 generate_content + function calling을 사용한다.
    여기서는 인터페이스 계약과 사용자 메모 보정 정책만 확정.
    """

    name = ToolName.MULTIMODAL_ANALYZE
    input_model = MultimodalAnalyzeInput
    output_model = MultimodalAnalyzeOutput

    async def run(self, payload: MultimodalAnalyzeInput) -> tuple[MultimodalAnalyzeOutput, ToolUsage]:
        started = time.perf_counter()
        # TODO: Vertex AI Gemini 3 multimodal call. 응답에서 intent / entities / actions 추출.
        base = MultimodalAnalyzeOutput(
            summary="",
            intent=Intent.MEMO,
            entities=[],
            tags=[],
            importance=3,
            confidence=0.0,
            model_version="gemini-3-flash@unwired",
        )
        if payload.user_memo:
            base.confidence = min(1.0, base.confidence + 0.1)
        usage = ToolUsage(tokens_in=0, tokens_out=0, latency_ms=int((time.perf_counter() - started) * 1000))
        return base, usage
