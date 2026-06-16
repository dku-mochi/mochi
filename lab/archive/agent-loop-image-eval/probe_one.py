"""단일 이미지 → agent loop 1회. V21 트리거 검증용 — tools_called + entities(특히 reference_url) 덤프.

Run (cwd=mochi-backend):
  uv run python ../lab/active/agent-loop-image-eval/probe_one.py /Users/jun/Downloads/IMG_8722.PNG
"""
import asyncio
import json
import sys
from pathlib import Path
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).parent))
from lab_gemini_client import LabGeminiClient  # noqa: E402

from app.modules.agent.application.orchestrator import AgentOrchestrator  # noqa: E402
from app.modules.agent.domain.gateway import AnalysisInput  # noqa: E402
from app.modules.agent.infrastructure.registry import StaticToolRegistry  # noqa: E402

from eval import _FakeGateway  # noqa: E402  (같은 디렉토리 하네스 재사용)

IMG = sys.argv[1] if len(sys.argv) > 1 else "/Users/jun/Downloads/IMG_8722.PNG"
MIME = "image/png"


async def main() -> None:
    source = AnalysisInput(text=None, url=None, user_memo=None, images=[(IMG, MIME)])
    gw = _FakeGateway(source)
    orch = AgentOrchestrator(
        llm=LabGeminiClient(), tools=StaticToolRegistry(), max_steps=8, gateway=gw
    )
    tools: list[str] = []
    async for ev in orch.run(uuid4(), uuid4()):
        if ev.kind == "tool_started":
            tools.append(ev.payload["name"])
        elif ev.kind == "tool_finished":
            print(f"  [tool_finished] {ev.payload}")
    a = gw.applied
    print("\n" + "=" * 80)
    print("TOOLS CALLED:", tools)
    print("findReferenceUrls 호출?:", "✅ YES" if "findReferenceUrls" in tools else "❌ NO")
    if a is None:
        print("분석 결과 없음")
        return
    print("SUMMARY:", a.summary)
    print("INTENTS:", [(i.intent_type.value, i.label) for i in a.intent_instances])
    refs = [e for e in a.entities if e.kind == "reference_url"]
    print(f"\nreference_url entities (메인이 저장한 형태): {len(refs)}개")
    for e in refs:
        is_json = False
        try:
            is_json = isinstance(json.loads(e.value), dict)
        except Exception:
            pass
        print(f"  • is_json_dict={is_json}  raw={e.value[:80]!r}")

    # 끝단 검증: 관대해진 repository._reference_links 를 통과해 iOS-facing 링크로 살아남는가.
    from datetime import UTC, datetime  # noqa: E402
    from app.modules.mochi_items.domain.entities import IngestChannel  # noqa: E402
    from app.modules.mochi_items.infrastructure.orm import EntityRow, MochiItemRow  # noqa: E402
    from app.modules.mochi_items.infrastructure.repository import _reference_links  # noqa: E402

    row = MochiItemRow(owner_id=uuid4(), channel=IngestChannel.SCREENSHOT.value,
                       url=None, text=None, user_memo=None, captured_at=datetime.now(UTC))
    row.id = uuid4()
    for e in a.entities:
        row.entities.append(EntityRow(mochi_item_id=row.id, kind=e.kind, value=e.value, mochi_item=row))
    links = _reference_links(row)
    print(f"\n→ repository._reference_links 통과 후 iOS 링크: {len(links)}개 (드롭 0 이어야 함)")
    for ln in links:
        print(f"  ✓ [{ln.provider}/{ln.role}] u={ln.usefulness} {ln.label}  {ln.url[:60]}")
    other = [(e.kind, e.value[:60]) for e in a.entities if e.kind != "reference_url"]
    print("기타 entities:", other)


asyncio.run(main())
