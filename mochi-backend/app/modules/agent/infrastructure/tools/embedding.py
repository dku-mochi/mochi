import time

from pydantic import BaseModel

from app.modules.agent.domain.tools import Tool, ToolName, ToolUsage


class EmbedInput(BaseModel):
    text: str
    model_version: str | None = None


class EmbedOutput(BaseModel):
    vector: list[float]
    model_version: str


class EmbedTool(Tool[EmbedInput, EmbedOutput]):
    """Vertex AI text-embedding-005 호출. 실제 구현은 PR-2에서 추가."""

    name = ToolName.EMBED
    input_model = EmbedInput
    output_model = EmbedOutput

    async def run(self, payload: EmbedInput) -> tuple[EmbedOutput, ToolUsage]:
        started = time.perf_counter()
        # TODO: aiplatform / google-genai 클라이언트 호출
        vector = [0.0] * 768
        usage = ToolUsage(tokens_in=len(payload.text), tokens_out=0, latency_ms=int((time.perf_counter() - started) * 1000))
        return EmbedOutput(vector=vector, model_version=payload.model_version or "text-embedding-005"), usage
