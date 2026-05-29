from typing import Any

from app.modules.agent.domain.ports import ToolRegistry
from app.modules.agent.domain.tools import Tool, ToolName
from app.modules.agent.infrastructure.tools.web_fetch import WebFetchTool


class StaticToolRegistry(ToolRegistry):
    """Agent loop 가 LLM 에 광고하는 호출 가능 도구.

    Arch2 — LLM 이 분석가다: 분류·요약·엔티티는 모델이 ``finalizeAnalysis`` 로 직접
    저술하므로 호출 도구로 둘 필요가 없고, embedding 은 결정적 후처리(INDEXED, 범위 외)다.
    따라서 LLM 이 능동적으로 부를 도구는 URL 그라운딩용 ``webFetch`` 하나뿐.
    (`MultimodalAnalyzeTool`/`EmbedTool` 클래스는 스키마 재사용·향후 wire 를 위해 보존.)
    """

    def __init__(self) -> None:
        self._tools: dict[ToolName, Tool[Any, Any]] = {
            ToolName.WEB_FETCH: WebFetchTool(),
        }

    def get(self, name: ToolName) -> Tool[Any, Any]:
        return self._tools[name]

    def all(self) -> list[Tool[Any, Any]]:
        return list(self._tools.values())
