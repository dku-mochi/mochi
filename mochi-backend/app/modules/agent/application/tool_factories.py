"""Agent 툴 팩토리 — 타 모듈에 가드 포함 툴 인스턴스를 건네는 허용 진입점.

모듈 경계 규칙(ARCHITECTURE §3.3)상 다른 모듈은 agent ``infrastructure/`` 를 직접
import 할 수 없다 — cross-module 진입은 ``application/`` 까지만. 채팅 web_fetch
(conversations, journal 2026-06-10 PR-4)가 SSRF·redirect 재검증·사이즈·MIME 가드를
**무수정 재사용**하도록 이 팩토리를 경유한다.
"""

from typing import Any

from app.modules.agent.domain.tools import Tool
from app.modules.agent.infrastructure.tools.web_fetch import WebFetchTool


def make_web_fetch_tool() -> Tool[Any, Any]:
    """가드 일체가 적용된 WebFetchTool. 입력은 ``tool.input_model(url=...)`` 로 만든다 —
    소비자가 infrastructure 의 구체 입력 타입을 import 하지 않아도 되게."""
    return WebFetchTool()
