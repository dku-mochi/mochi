"""ResourceFinder 라이브 baseline — 실제 스크린샷을 본 메인 orchestrator 가 두 tool
(findReferenceUrls / recoverYoutubeUrl)을 잘 부르는지 + 결과가 좋은지 측정.

핵심 불변식 (journal 2026-06-14 §6): **app import only, 프롬프트/스키마 리터럴 0.**
  프로덕션 `AgentOrchestrator` + `GeminiAgentClient` + `StaticToolRegistry` 를 그대로 돌린다
  (divergence 0 — 안 그러면 라이브가 또 다른 mock). 이 harness 가 더하는 것은 두 가지뿐:
    1) 로컬 스크린샷 inline 주입(GCS 우회) — agent-loop-image-eval 의 `LabGeminiClient` 재사용.
    2) tool 의 input/output 가로채기 — app tool 을 얇게 감싸기만(프롬프트 없음).

입력: lab/data/screenshot_prod/manifest.jsonl + images/  (사용자 정리본 39건).
출력: results/baseline_YYYYMMDD_HHMMSS.json (per-case: source_app · tool_calls(input/output) ·
      최종 분석 · manifest ground truth). judge(Claude 서브에이전트)는 부모가 별도로 채점.

실행 (repo 루트에서):
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \\
    uv run --directory mochi-backend python ../lab/active/agent-loop-resource-eval/run_baseline.py
  (.env 의 NAVER_CLIENT_ID/SECRET·TAVILY_API_KEY 로드, Vertex ADC 필요)
"""
import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any
from uuid import uuid4

# app import only — 이 harness 는 프롬프트/스키마를 갖지 않는다.
# 실행 cwd 와 무관하게 app 패키지(mochi-backend)와 lab_gemini_client 를 찾도록 경로 고정.
sys.path.insert(0, str(Path(__file__).parents[3] / "mochi-backend"))
sys.path.insert(0, str(Path(__file__).parents[1] / "agent-loop-image-eval"))
from lab_gemini_client import LabGeminiClient  # noqa: E402  (로컬 이미지 inline 주입 재사용)

from app.modules.agent.application.orchestrator import AgentOrchestrator  # noqa: E402
from app.modules.agent.domain.analysis import AnalysisResult  # noqa: E402
from app.modules.agent.domain.gateway import AnalysisInput  # noqa: E402
from app.modules.agent.domain.ports import ToolRegistry  # noqa: E402
from app.modules.agent.domain.profile import ProfileWindowItem  # noqa: E402
from app.modules.agent.domain.tools import Tool, ToolName, ToolUsage  # noqa: E402
from app.modules.agent.infrastructure.registry import StaticToolRegistry  # noqa: E402

HERE = Path(__file__).parent
DATA_DIR = HERE.parents[1] / "data" / "screenshot_prod"
MANIFEST = DATA_DIR / "manifest.jsonl"
IMAGES = DATA_DIR / "images"
RESULTS_DIR = HERE / "results"
MAX_STEPS = 8
CONCURRENCY = 4


class _RecordingTool(Tool[Any, Any]):
    """app tool 을 감싸 input(메인이 넘긴 인자)·output(검색 결과)을 sink 에 기록.

    프롬프트/스키마 없음 — inner tool 에 위임만 한다(divergence 0 유지).
    """

    def __init__(self, inner: Tool[Any, Any], sink: list[dict[str, Any]]):
        self._inner = inner
        self._sink = sink
        self.name = inner.name
        self.input_model = inner.input_model
        self.output_model = inner.output_model

    async def run(self, payload: Any) -> tuple[Any, ToolUsage]:
        out, usage = await self._inner.run(payload)
        self._sink.append(
            {"tool": self.name.value, "input": payload.model_dump(mode="json"),
             "output": out.model_dump(mode="json")}
        )
        return out, usage

    def schema(self) -> dict[str, Any]:
        return self._inner.schema()


class _RecordingRegistry(ToolRegistry):
    def __init__(self, base: ToolRegistry, sink: list[dict[str, Any]]):
        self._wrapped: dict[ToolName, Tool[Any, Any]] = {
            t.name: _RecordingTool(t, sink) for t in base.all()
        }

    def get(self, name: ToolName) -> Tool[Any, Any]:
        return self._wrapped[name]

    def all(self) -> list[Tool[Any, Any]]:
        return list(self._wrapped.values())


class _FakeGateway:
    """DB 없이 orchestrator 를 돌리는 in-memory gateway (agent_loop_live_test 패턴)."""

    def __init__(self, source: AnalysisInput):
        self._source = source
        self.applied: AnalysisResult | None = None

    async def load_source(self, *, owner_id: Any, mochi_item_id: Any) -> AnalysisInput:
        return self._source

    async def apply_analysis(self, *, owner_id: Any, mochi_item_id: Any, result: AnalysisResult) -> None:
        self.applied = result

    async def list_recent_window(self, *, owner_id: Any, limit: int) -> list[ProfileWindowItem]:
        return []

    async def count_items(self, *, owner_id: Any) -> int:
        return 0


def _load_cases() -> list[dict[str, Any]]:
    return [json.loads(line) for line in MANIFEST.read_text(encoding="utf-8").splitlines() if line.strip()]


def _to_input(row: dict[str, Any]) -> AnalysisInput:
    img_path = IMAGES / row["file"]
    return AnalysisInput(
        text=row.get("text"),
        url=row.get("url"),
        user_memo=row.get("user_memo"),
        images=((str(img_path), "image/jpeg"),),
    )


async def _run_one(row: dict[str, Any]) -> dict[str, Any]:
    sink: list[dict[str, Any]] = []
    gateway = _FakeGateway(_to_input(row))
    registry = _RecordingRegistry(StaticToolRegistry(), sink)
    orch = AgentOrchestrator(llm=LabGeminiClient(), tools=registry, max_steps=MAX_STEPS, gateway=gateway)

    events: list[str] = []
    error: str | None = None
    try:
        async for ev in orch.run(uuid4(), uuid4()):
            events.append(ev.kind)
    except Exception as exc:  # noqa: BLE001 — 케이스 단위 실패 기록 후 계속
        error = f"{type(exc).__name__}: {str(exc)[:200]}"

    a = gateway.applied
    analysis = None
    if a is not None:
        analysis = {
            "summary": a.summary,
            "category": a.category,
            "needs_review": a.needs_review,
            "intents": [i.intent_type.value for i in a.intent_instances],
            "entities": [{"kind": e.kind, "value": e.value} for e in a.entities],
        }
    return {
        "file": row["file"],
        "source_app": row.get("source_app"),
        "label_ko": row.get("label_ko"),
        "gt_summary": row.get("summary"),      # 프로덕션 분석 당시 summary (judge ground truth)
        "gt_category": row.get("category"),
        "events": events,
        "tool_calls": sink,
        "analysis": analysis,
        "error": error,
    }


async def main() -> None:
    cases = _load_cases()
    print(f"▶ {len(cases)} 스크린샷 — 실제 orchestrator loop (max_steps={MAX_STEPS})")
    sem = asyncio.Semaphore(CONCURRENCY)

    async def guarded(row: dict[str, Any]) -> dict[str, Any]:
        async with sem:
            r = await _run_one(row)
            tools = [c["tool"] for c in r["tool_calls"]]
            print(f"  · {r['file'][:24]:26s} [{str(r['source_app'])[:10]:>10}] "
                  f"tools={tools or '-'}" + (f"  ERR:{r['error'][:40]}" if r["error"] else ""))
            return r

    results = await asyncio.gather(*(guarded(row) for row in cases))

    # 요약 — tool 호출률 / 카테고리 / recover 발동
    finder = [r for r in results if any(c["tool"] == ToolName.RESOURCE_FINDER.value for c in r["tool_calls"])]
    recover = [r for r in results if any(c["tool"] == ToolName.RECOVER_YOUTUBE_URL.value for c in r["tool_calls"])]
    finder_useful = [r for r in finder
                     if any(c["tool"] == ToolName.RESOURCE_FINDER.value and c["output"].get("useful")
                            for c in r["tool_calls"])]
    recover_ok = [r for r in recover
                  if any(c["tool"] == ToolName.RECOVER_YOUTUBE_URL.value and c["output"].get("recovered")
                         for c in r["tool_calls"])]
    yt_cases = [r for r in results if r.get("source_app") == "YouTube"]
    errors = [r for r in results if r["error"]]
    summary = {
        "cases": len(results),
        "errors": len(errors),
        "finder_call_rate": round(len(finder) / max(len(results), 1), 2),
        "finder_useful": len(finder_useful),
        "recover_call_rate": round(len(recover) / max(len(results), 1), 2),
        "recover_ok": len(recover_ok),
        "youtube_cases": len(yt_cases),
        "youtube_recover_called": len([r for r in yt_cases if r in recover]),
    }

    RESULTS_DIR.mkdir(exist_ok=True)
    out = RESULTS_DIR / f"baseline_{datetime.now():%Y%m%d_%H%M%S}.json"
    out.write_text(json.dumps({"summary": summary, "results": results}, ensure_ascii=False, indent=2),
                   encoding="utf-8")
    print("\n=== 요약 ===")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n결과 저장: {out}")


if __name__ == "__main__":
    asyncio.run(main())
