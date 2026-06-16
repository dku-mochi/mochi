"""캡처 → 플랫폼 게시물 단서 추출 실험 (exp1) — 스크린샷만으로 원문을 찾을 단서를 뽑을 수 있는가.

배경:
  유튜브/X/쓰레드 캡처에서 "그 게시물의 URL"을 best-effort 로 복원하려면, 먼저 캡처에서
  복원에 쓸 단서 — 플랫폼·@handle·채널/작성자·제목·본문·검색어 — 를 정확히 뽑아야 한다.
  youtube-enrich(2026-05-29) 가 YouTube 비전 추출은 이미 검증했고, §5 에서 **채널/@handle
  OCR 오독을 복원의 병목**으로 지목했다. 이 실험의 신규 미지수는 X·Threads 의 handle/본문
  추출 정확도다. exp2(url_recovery)의 1단계.

방법:
  - 입력: lab/data/screenshot/ 최상위 이미지 전체(소셜/비소셜 혼재).
  - 추출: Gemini 가 {platform, is_social_post, handle, author, title, post_text,
    search_query, evidence} 구조화 출력. flash-lite(프로덕션 agent 동일) vs 3.5-flash 비교.
  - 평가: LLM judge(3.5-flash)가 같은 캡처를 보고 platform_correct·handle_match(OCR 정확도)·
    clue_findable(이 단서로 원문을 찾을 수 있을까) 채점.

실행 (repo 루트에서, ADC + GOOGLE_CLOUD_PROJECT 필요):
  GOOGLE_CLOUD_PROJECT=<proj> uv run --project mochi-backend \\
    python lab/active/capture-url-recovery/exp1_recover_id.py

결과: lab/active/capture-url-recovery/results/exp1_YYYYMMDD_HHMMSS.json
"""
import json
import os
import sys
from datetime import datetime
from pathlib import Path

from google import genai
from google.genai import types
from pydantic import BaseModel, Field

sys.stdout.reconfigure(encoding="utf-8")

LAB_ROOT = Path(__file__).parent
DATA_DIR = LAB_ROOT.parent.parent / "data" / "screenshot"
RESULTS_DIR = LAB_ROOT / "results"

EXTRACTOR_MODELS = ["gemini-3.1-flash-lite", "gemini-3.5-flash"]
JUDGE_MODEL = "gemini-3.5-flash"
LOCATION = "global"

MIME_MAP = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}

EXTRACT_PROMPT = (
    "너는 모찌(개인 기억 비서)의 소셜 캡처 분석기다. 사용자가 저장한 스크린샷을 보고 "
    "*원문(게시물/영상)을 다시 찾는 데 쓸 단서*를 정확히 뽑아라:\n"
    "1) platform: youtube | x | threads | none. 화면 UI·로고·레이아웃으로 판단. 소셜이 아니면 none.\n"
    "2) is_social_post: 위 세 플랫폼의 게시물/영상 캡처인가.\n"
    "3) handle: @아이디 (있으면 @ 포함, 글자 그대로 — 추측 금지). 복원의 핵심이니 OCR 을 정확히.\n"
    "4) author: 표시 이름/채널명 (handle 과 다를 수 있음).\n"
    "5) title: 영상 제목 등 (YouTube). 없으면 null.\n"
    "6) post_text: 트윗/쓰레드 본문 텍스트 (있는 만큼).\n"
    "7) search_query: 이 게시물을 검색으로 다시 찾기 위해 입력할 검색어 (작성자+핵심어).\n"
    "8) evidence: 무엇을 근거로 platform/handle 을 판단했는지 한 줄.\n"
    "확실하지 않은 필드는 추측하지 말고 null. handle 은 특히 한 글자라도 틀리면 복원이 깨지니 보수적으로."
)

JUDGE_PROMPT = (
    "너는 평가자다. 첨부 스크린샷과, 분석기가 뽑은 단서를 비교해 채점하라.\n"
    "- platform_correct: platform 판단(youtube/x/threads/none)이 맞는가.\n"
    "- handle_match (1-5): 추출된 handle 이 화면의 실제 @아이디와 글자 그대로 일치하는가. "
    "5=완전 일치, 3=일부 오독, 1=틀림/엉뚱. 화면에 handle 이 없고 분석기도 null 이면 5.\n"
    "- clue_findable (1-5): search_query+handle+title/post_text 로 그 원문을 다시 찾을 수 "
    "있을 것으로 기대되는가. 5=거의 확실, 1=단서 부족으로 불가.\n"
    "- comment: 한 줄 코멘트 (특히 handle 오독이 있으면 지적).\n"
    "소셜이 아닌 캡처를 분석기가 none 으로 봤다면 handle_match·clue_findable 은 5 로 둔다."
)


class CaptureRecovery(BaseModel):
    platform: str = Field(pattern="^(youtube|x|threads|none)$")
    is_social_post: bool
    handle: str | None = None
    author: str | None = None
    title: str | None = None
    post_text: str | None = None
    search_query: str | None = None
    evidence: str


class JudgeScore(BaseModel):
    platform_correct: bool
    handle_match: int = Field(ge=1, le=5)
    clue_findable: int = Field(ge=1, le=5)
    comment: str


def client() -> genai.Client:
    return genai.Client(
        vertexai=True,
        project=os.environ["GOOGLE_CLOUD_PROJECT"],
        location=LOCATION,
    )


def generate(c: genai.Client, model: str, parts: list, system: str, schema) -> BaseModel:
    resp = c.models.generate_content(
        model=model,
        contents=[types.Content(role="user", parts=parts)],
        config=types.GenerateContentConfig(
            system_instruction=system,
            response_mime_type="application/json",
            response_schema=schema,
            temperature=0.0,
        ),
    )
    return schema.model_validate_json(resp.text)


def image_cases() -> list[dict]:
    cases = []
    for p in sorted(DATA_DIR.iterdir()):
        if p.is_file() and p.suffix.lower() in MIME_MAP:
            cases.append({"name": p.name, "path": p})
    return cases


def case_parts(case: dict) -> list:
    return [
        types.Part.from_bytes(
            data=case["path"].read_bytes(),
            mime_type=MIME_MAP[case["path"].suffix.lower()],
        ),
        types.Part.from_text(text="이 스크린샷을 분석하라."),
    ]


def main() -> None:
    c = client()
    cases = image_cases()
    if not cases:
        print(f"이미지 없음 — {DATA_DIR} 에 스크린샷을 두어라.")
        sys.exit(1)
    print(f"케이스 {len(cases)}건 (이미지)")

    results = []
    for case in cases:
        row: dict = {"case": case["name"]}
        for model in EXTRACTOR_MODELS:
            try:
                ext = generate(c, model, case_parts(case), EXTRACT_PROMPT, CaptureRecovery)
            except Exception as e:  # noqa: BLE001 — 실험: 케이스 단위 실패 기록 후 계속
                row[model] = {"error": str(e)[:200]}
                continue
            entry = ext.model_dump()
            try:
                judge_parts = case_parts(case) + [
                    types.Part.from_text(
                        text=f"분석기 추출 단서: {json.dumps(entry, ensure_ascii=False)}"
                    )
                ]
                judge = generate(c, JUDGE_MODEL, judge_parts, JUDGE_PROMPT, JudgeScore)
                entry["judge"] = judge.model_dump()
            except Exception as e:  # noqa: BLE001
                entry["judge"] = {"error": str(e)[:200]}
            row[model] = entry
        results.append(row)
        last = row.get(EXTRACTOR_MODELS[-1]) or {}
        print(f"  ✓ {case['name'][:40]:42s} → {last.get('platform')} / {last.get('handle')}")

    # 모델별 요약
    summary = {}
    for model in EXTRACTOR_MODELS:
        rows = [r[model] for r in results if isinstance(r.get(model), dict) and "error" not in r[model]]
        judged = [r["judge"] for r in rows if "judge" in r and "error" not in r["judge"]]
        social = [r for r in rows if r["is_social_post"]]
        by_platform: dict[str, int] = {}
        for r in social:
            by_platform[r["platform"]] = by_platform.get(r["platform"], 0) + 1
        summary[model] = {
            "cases": len(rows),
            "social_detected": len(social),
            "by_platform": by_platform,
            "platform_correct": sum(1 for j in judged if j["platform_correct"]),
            "avg_handle_match": round(sum(j["handle_match"] for j in judged) / max(len(judged), 1), 2),
            "avg_clue_findable": round(sum(j["clue_findable"] for j in judged) / max(len(judged), 1), 2),
        }

    RESULTS_DIR.mkdir(exist_ok=True)
    out = RESULTS_DIR / f"exp1_{datetime.now():%Y%m%d_%H%M%S}.json"
    out.write_text(
        json.dumps({"summary": summary, "results": results}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print("\n=== 요약 ===")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n결과 저장: {out}")


if __name__ == "__main__":
    main()
