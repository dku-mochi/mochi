"""1단계: 원본 이미지 → Gemini 분석 → artifacts/analysis/{fingerprint}.json

fingerprint = sha256(model + prompt_body)[:8]
item마다 source_hash(이미지 md5)를 저장, 재실행 시 변경된 item만 재분석.

실행 (mochi-backend 디렉토리에서):
  GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \\
  GOOGLE_APPLICATION_CREDENTIALS="C:/Users/dhapr/Downloads/mochi/mochi-gemini-team.json" \\
  PYTHONPATH="C:/Users/dhapr/OneDrive/바탕 화면/git/mochi/mochi-backend" \\
  uv run python "../lab/active/rag-search/analyze.py"
"""

import asyncio
import hashlib
import json
import sys
import unicodedata
from datetime import datetime
from pathlib import Path
from uuid import uuid4

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, str(Path(__file__).parent.parent / "agent-loop-image-eval"))
from lab_gemini_client import LabGeminiClient  # noqa: E402, I001

from app.core.config import get_settings  # noqa: E402
from app.modules.agent.application.orchestrator import AgentOrchestrator  # noqa: E402
from app.modules.agent.domain.analysis import AnalysisResult  # noqa: E402
from app.modules.agent.domain.gateway import AnalysisInput  # noqa: E402
from app.modules.agent.domain.profile import ProfileWindowItem  # noqa: E402
from app.modules.agent.infrastructure.registry import StaticToolRegistry  # noqa: E402
from app.modules.agent.prompts.system_prompts import ACTIVE_PROMPT  # noqa: E402

LAB_ROOT = Path(__file__).parent
IMAGES_DIR = LAB_ROOT.parent.parent / "data" / "legacy"
CASES_PATH = LAB_ROOT / "data" / "cases.json"
ANALYSIS_DIR = LAB_ROOT / "artifacts" / "analysis"
MIME_MAP = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}


def _nfc(s: str) -> str:
    return unicodedata.normalize("NFC", s)


def _find_image(filename: str) -> Path | None:
    """NFC 정규화로 파일명 매칭 (macOS NFD ↔ Windows NFC 차이 흡수)."""
    target = _nfc(filename)
    for f in IMAGES_DIR.iterdir():
        if _nfc(f.name) == target:
            return f
    return None


def _fingerprint() -> str:
    """model + prompt body hash — prompt 본문 변경도 잡는다."""
    model = get_settings().gemini_agent_model
    prompt_body_hash = hashlib.sha256(ACTIVE_PROMPT.body.encode()).hexdigest()[:8]
    raw = f"{model}::{ACTIVE_PROMPT.name}::{prompt_body_hash}"
    return hashlib.sha256(raw.encode()).hexdigest()[:8]


def _source_hash(case: dict) -> str:
    """모든 입력 필드를 하나의 해시로 — 어느 필드가 바뀌어도 감지."""
    h = hashlib.md5()
    if case.get("image"):
        path = _find_image(case["image"])
        if path:
            h.update(path.read_bytes())
    for field in ("url", "text", "user_memo"):
        val = case.get(field)
        if val:
            h.update(val.encode())
    digest = h.hexdigest()
    return digest[:8] if digest != hashlib.md5().hexdigest() else "empty"


def _case_label(case: dict) -> str:
    return case.get("image") or case.get("url") or (case.get("text") or "")[:40]


class _FakeGateway:
    def __init__(self, source: AnalysisInput):
        self._source = source
        self.applied: AnalysisResult | None = None

    async def load_source(self, *, owner_id, mochi_item_id):
        return self._source

    async def apply_analysis(self, *, owner_id, mochi_item_id, result):
        self.applied = result

    async def list_recent_window(self, *, owner_id, limit) -> list[ProfileWindowItem]:
        return []

    async def count_items(self, *, owner_id):
        return 0


def _build_source(case: dict) -> AnalysisInput | None:
    images: tuple = ()
    if case.get("image"):
        path = _find_image(case["image"])
        if path is None:
            print(f"  ⚠️  이미지 파일 없음: {case['image']}")
            return None
        mime = MIME_MAP.get(path.suffix.lower(), "image/png")
        images = ((str(path), mime),)
    return AnalysisInput(
        text=case.get("text"),
        url=case.get("url"),
        user_memo=case.get("user_memo"),
        images=images,
    )


def _serialize(case: dict, result: AnalysisResult, source_hash: str) -> dict:
    return {
        "id": case["id"],
        "source_hash": source_hash,
        "image": case.get("image"),
        "url": case.get("url"),
        "text": case.get("text"),
        "user_memo": case.get("user_memo"),
        "expected_topics": case.get("expected_topics", []),
        "expected_intents": case.get("expected_intents", []),
        "expected_entities": case.get("expected_entities", []),
        "analysis": {
            "model_version": result.model_version,
            "summary": result.summary,
            "needs_review": result.needs_review,
            "importance": result.importance,
            "intent_instances": [
                {
                    "intent_type": str(inst.intent_type),
                    "label": inst.label,
                    "reasoning": inst.reasoning,
                    "lifecycle_kind": inst.lifecycle.kind.value,
                    "payload": {
                        "title": inst.payload.title,
                        "date": inst.payload.date,
                        "time": inst.payload.time,
                        "deadline": inst.payload.deadline,
                        "person": inst.payload.person,
                        "topic": inst.payload.topic,
                        "url": inst.payload.url,
                        "note": inst.payload.note,
                    },
                }
                for inst in result.intent_instances
            ],
            "entities": [
                {"kind": e.kind, "value": e.value} for e in result.entities
            ],
            "review_options": [
                {
                    "intent_type": str(opt.intent_type),
                    "label": opt.label,
                    "reasoning": opt.reasoning,
                }
                for opt in result.review_options
            ],
        },
    }


async def main() -> None:
    ANALYSIS_DIR.mkdir(parents=True, exist_ok=True)
    cases = json.loads(CASES_PATH.read_text(encoding="utf-8"))
    fp = _fingerprint()
    out_path = ANALYSIS_DIR / f"{fp}.json"
    model = get_settings().gemini_agent_model

    existing: dict[str, dict] = {}
    if out_path.exists():
        prev = json.loads(out_path.read_text(encoding="utf-8"))
        existing = {item["id"]: item for item in prev.get("items", [])}

    # cases.json에서 삭제된 ID는 artifact에서도 제거
    current_ids = {c["id"] for c in cases}
    existing = {k: v for k, v in existing.items() if k in current_ids}

    print(f"fingerprint={fp}  model={model}  prompt={ACTIVE_PROMPT.name}")
    print(f"cases={len(cases)}  cached={len(existing)}\n")

    llm = LabGeminiClient()
    tools = StaticToolRegistry()
    owner_id = uuid4()
    results = dict(existing)

    for case in cases:
        cid = case["id"]
        curr_hash = _source_hash(case)

        if cid in results:
            if results[cid].get("source_hash") == curr_hash:
                # source 불변 — expected 라벨만 최신 cases.json 값으로 동기화
                for field in ("expected_intents", "expected_topics", "expected_entities"):
                    results[cid][field] = case.get(field, [])
                print(f"[skip ] {cid}")
                continue
            print(f"[stale] {cid}  source changed, re-analyzing")
            results.pop(cid)  # 실패 시 stale entry 없도록 먼저 제거

        source = _build_source(case)
        if source is None:
            continue

        gateway = _FakeGateway(source)
        orch = AgentOrchestrator(llm=llm, tools=tools, max_steps=8, gateway=gateway)

        print(f"[run  ] {cid}  {_case_label(case)}", flush=True)
        try:
            async for _ in orch.run(uuid4(), owner_id):
                pass
        except Exception as exc:
            print(f"  ⚠️  ERROR: {exc}")
            continue

        if gateway.applied is None:
            print("  ⚠️  결과 없음")
            continue

        r = gateway.applied
        intents = [str(i.intent_type) for i in r.intent_instances]
        intent_ok = all(i in intents for i in case.get("expected_intents", []))
        print(f"  → intent={intents}  intent_ok={intent_ok}  summary={r.summary[:50]}")
        results[cid] = _serialize(case, r, curr_hash)

    def _topic_in_output(topic: str, item: dict) -> bool:
        """expected_topic이 Gemini 출력 어딘가에 포함되는지 — 소문자 부분 문자열 비교."""
        a = item["analysis"]
        t = topic.lower()
        candidates = [
            a.get("summary", ""),
            *(inst.get("label") or "" for inst in a["intent_instances"]),
            *(inst.get("payload", {}).get("topic") or "" for inst in a["intent_instances"]),
            *(e["value"] for e in a.get("entities", [])),
        ]
        return any(t in c.lower() for c in candidates if c)

    # analysis_quality: expected vs actual 비교 요약
    quality_rows = []
    for item in results.values():
        a = item["analysis"]
        actual_intents = {inst["intent_type"] for inst in a["intent_instances"]}
        actual_entities = {e["value"] for e in a["entities"]}
        expected_intents = set(item.get("expected_intents", []))
        expected_entities = set(item.get("expected_entities", []))
        expected_topics = item.get("expected_topics", [])

        intent_recall = (
            len(actual_intents & expected_intents) / len(expected_intents)
            if expected_intents else None
        )
        entity_recall = (
            len(actual_entities & expected_entities) / len(expected_entities)
            if expected_entities else None
        )
        topic_hits = sum(1 for t in expected_topics if _topic_in_output(t, item))
        topic_recall = topic_hits / len(expected_topics) if expected_topics else None

        quality_rows.append({
            "id": item["id"],
            "intent_recall": round(intent_recall, 2) if intent_recall is not None else None,
            "entity_recall": round(entity_recall, 2) if entity_recall is not None else None,
            "topic_recall": round(topic_recall, 2) if topic_recall is not None else None,
            "intent_ok": intent_recall == 1.0 if intent_recall is not None else None,
        })

    evaluated = [r for r in quality_rows if r["intent_recall"] is not None]
    avg_intent_recall = (
        round(sum(r["intent_recall"] for r in evaluated) / len(evaluated), 3)
        if evaluated else None
    )
    topic_evaluated = [r for r in quality_rows if r["topic_recall"] is not None]
    avg_topic_recall = (
        round(sum(r["topic_recall"] for r in topic_evaluated) / len(topic_evaluated), 3)
        if topic_evaluated else None
    )

    artifact = {
        "fingerprint": fp,
        "created_at": datetime.now().isoformat(),
        "model": model,
        "prompt_name": ACTIVE_PROMPT.name,
        "item_count": len(results),
        "analysis_quality": {
            "avg_intent_recall": avg_intent_recall,
            "avg_topic_recall": avg_topic_recall,
            "pass_rate": round(
                sum(1 for r in evaluated if r["intent_ok"]) / len(evaluated), 3
            ) if evaluated else None,
            "items": quality_rows,
        },
        "items": list(results.values()),
    }
    out_path.write_text(json.dumps(artifact, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\n📊 Analysis quality — intent_recall={avg_intent_recall}  topic_recall={avg_topic_recall}")
    print(f"✅ {out_path}  ({len(results)}개)")


if __name__ == "__main__":
    asyncio.run(main())
