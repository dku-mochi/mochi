"""쇼핑 상품 식별 실험 (exp1) — 캡처에서 "정확히 어떤 상품인지" 검색 가능한 이름으로 뽑을 수 있는가.

배경:
  홈 주간 정리의 category("쇼핑 후보" 류)로 쇼핑 캡처가 이미 분리된다. 카드 상세에
  구매 링크(검색 상태 URL)를 달려면, 그 전에 캡처(스크린샷/메모)에서 상품을
  *검색어로 쓸 수 있을 만큼* 정확히 식별할 수 있어야 한다. 이 실험이 그 1단계.

방법:
  - 입력: lab/data/screenshot/ 최상위 이미지 전체(쇼핑/비쇼핑 혼재) + 합성 쇼핑 메모 텍스트.
  - 추출: Gemini 가 {is_shopping, product_query(검색창 입력용), specificity, evidence} 구조화 출력.
    모델 2종 비교 — gemini-3.1-flash-lite(프로덕션 agent 동일) vs gemini-3.5-flash.
  - 평가: LLM judge(3.5-flash)가 같은 캡처를 보고 product_match(상품 일치)·searchable
    (이 검색어로 그 상품이 나올까)·is_shopping 판단 적절성을 채점.

실행 (repo 루트에서, ADC + GOOGLE_CLOUD_PROJECT 필요):
  GOOGLE_CLOUD_PROJECT=<proj> uv run --project mochi-backend \\
    python lab/active/shopping-product-link/exp1_product_id.py

결과: lab/active/shopping-product-link/results/exp1_YYYYMMDD_HHMMSS.json
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

# 합성 쇼핑 메모 — text_memos.json 은 일정 위주라 쇼핑 케이스를 여기서 보강.
# 마지막 2건은 비쇼핑 음성 케이스, vague 표기는 의도적 실패 모드(모호 메모).
TEXT_MEMOS = [
    {"memo": "다이슨 에어랩 멀티 스타일러 컴플리트 세일하면 사기", "expect_shopping": True},
    {"memo": "나이키 페가수스 41 270 사이즈", "expect_shopping": True},
    {"memo": "로지텍 MX Master 3S 블프때 보기", "expect_shopping": True},
    {"memo": "에어팟 프로2 지금 거 끊기면 이걸로", "expect_shopping": True},
    {"memo": "신발 예쁜 거 봐둠 (vague)", "expect_shopping": True},
    {"memo": "원피스 검정 그거 (vague)", "expect_shopping": True},
    {"memo": "금요일 코엑스", "expect_shopping": False},
    {"memo": "리액트 useEffect 정리 글 읽기", "expect_shopping": False},
]

EXTRACT_PROMPT = (
    "너는 모찌(개인 기억 비서)의 쇼핑 분석기다. 사용자가 저장한 캡처(스크린샷 또는 메모)를 보고:\n"
    "1) is_shopping: 사용자가 어떤 *상품의 구매*를 고민/계획하는 캡처인가. 장소·일정·학습자료는 아니다.\n"
    "2) product_query: 쇼핑이면, 커머스 검색창에 그대로 입력해 그 상품을 찾을 검색어 —\n"
    "   브랜드+상품명+모델/옵션(색·사이즈 등 식별에 필요한 것만). 한국 커머스 관행 표기.\n"
    "   화면의 마케팅 문구·수식어는 빼고, 상품을 특정하는 토큰만.\n"
    "3) specificity: exact(모델/품번 수준 특정) | category(품목 수준만, 예: '무선 마우스') | unknown.\n"
    "4) evidence: 무엇을 근거로 판단했는지 한 줄.\n"
    "쇼핑이 아니면 product_query 는 null."
)

JUDGE_PROMPT = (
    "너는 평가자다. 첨부 캡처(또는 메모 원문)와, 분석기가 뽑은 상품 식별 결과를 비교해 채점하라.\n"
    "- product_match (1-5): 식별된 상품이 캡처 속 실제 상품과 일치하는가. 5=정확히 그 상품, "
    "3=품목은 맞으나 모델 틀림/누락, 1=다른 상품.\n"
    "- searchable (1-5): product_query 를 쿠팡/네이버쇼핑 검색창에 입력하면 캡처 속 그 상품이 "
    "상위에 나올 것으로 기대되는가.\n"
    "- shopping_call_correct: is_shopping 판단이 적절했는가.\n"
    "쇼핑이 아닌 캡처를 분석기가 쇼핑 아님(is_shopping=false)으로 봤다면 match/searchable 은 5로 둔다."
)


class ProductExtraction(BaseModel):
    is_shopping: bool
    product_query: str | None = None
    specificity: str = Field(pattern="^(exact|category|unknown)$")
    evidence: str


class JudgeScore(BaseModel):
    product_match: int = Field(ge=1, le=5)
    searchable: int = Field(ge=1, le=5)
    shopping_call_correct: bool
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
            cases.append({"kind": "image", "name": p.name, "path": p})
    return cases


def case_parts(case: dict) -> list:
    if case["kind"] == "image":
        return [
            types.Part.from_bytes(
                data=case["path"].read_bytes(),
                mime_type=MIME_MAP[case["path"].suffix.lower()],
            ),
            types.Part.from_text(text="이 스크린샷을 분석하라."),
        ]
    return [types.Part.from_text(text=f"사용자 메모: {case['memo']}")]


def main() -> None:
    c = client()
    cases = image_cases() + [
        {"kind": "text", "name": f"memo: {m['memo']}", **m} for m in TEXT_MEMOS
    ]
    print(f"케이스 {len(cases)}건 (이미지 {sum(1 for x in cases if x['kind']=='image')} / "
          f"메모 {sum(1 for x in cases if x['kind']=='text')})")

    results = []
    for case in cases:
        row: dict = {"case": case["name"], "kind": case["kind"]}
        if case["kind"] == "text":
            row["expect_shopping"] = case["expect_shopping"]
        for model in EXTRACTOR_MODELS:
            try:
                ext = generate(c, model, case_parts(case), EXTRACT_PROMPT, ProductExtraction)
            except Exception as e:  # noqa: BLE001 — 실험: 케이스 단위 실패 기록 후 계속
                row[model] = {"error": str(e)[:200]}
                continue
            entry = ext.model_dump()
            try:
                judge_parts = case_parts(case) + [
                    types.Part.from_text(
                        text=f"분석기 식별 결과: {json.dumps(entry, ensure_ascii=False)}"
                    )
                ]
                judge = generate(c, JUDGE_MODEL, judge_parts, JUDGE_PROMPT, JudgeScore)
                entry["judge"] = judge.model_dump()
            except Exception as e:  # noqa: BLE001
                entry["judge"] = {"error": str(e)[:200]}
            row[model] = entry
        results.append(row)
        q = (row.get(EXTRACTOR_MODELS[-1]) or {}).get("product_query")
        print(f"  ✓ {case['name'][:40]:42s} → {q}")

    # 모델별 요약
    summary = {}
    for model in EXTRACTOR_MODELS:
        rows = [r[model] for r in results if isinstance(r.get(model), dict) and "error" not in r[model]]
        judged = [r["judge"] for r in rows if "judge" in r and "error" not in r["judge"]]
        shopping = [r for r in rows if r["is_shopping"]]
        summary[model] = {
            "cases": len(rows),
            "shopping_detected": len(shopping),
            "exact": sum(1 for r in shopping if r["specificity"] == "exact"),
            "avg_product_match": round(sum(j["product_match"] for j in judged) / max(len(judged), 1), 2),
            "avg_searchable": round(sum(j["searchable"] for j in judged) / max(len(judged), 1), 2),
            "shopping_call_correct": sum(1 for j in judged if j["shopping_call_correct"]),
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
