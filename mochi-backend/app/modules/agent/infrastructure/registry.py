from app.modules.agent.domain.ports import ToolRegistry
from app.modules.agent.domain.tools import Tool, ToolName
from app.modules.agent.infrastructure.tools.embedding import EmbedTool
from app.modules.agent.infrastructure.tools.multimodal_analyze import MultimodalAnalyzeTool
from app.modules.agent.infrastructure.tools.web_fetch import WebFetchTool


class StaticToolRegistry(ToolRegistry):
    def __init__(self) -> None:
        self._tools: dict[ToolName, Tool] = {
            ToolName.MULTIMODAL_ANALYZE: MultimodalAnalyzeTool(),
            ToolName.EMBED: EmbedTool(),
            ToolName.WEB_FETCH: WebFetchTool(),
        }

    def get(self, name: ToolName) -> Tool:
        return self._tools[name]

    def all(self) -> list[Tool]:
        return list(self._tools.values())
