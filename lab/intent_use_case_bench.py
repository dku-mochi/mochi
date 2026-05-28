#!/usr/bin/env python3
"""Use-case 후보 생성 + 4-Intent 매핑 벤치 — Gemini 3.1 Flash Lite.

v1 (intent_latency_bench.py) 의 후속: LLM 이 4-Intent 를 직접 추측하는 대신
사용자의 *사용 의도* (use case) 후보 3개를 자연어로 생성하고 각각의 4-Intent
매핑을 같이 출력한다. 알림에 후보 버튼으로 노출 → 사용자가 자기 의도를
직접 고르는 UX 의 데이터 가능성 검증용.

사용:
  python3 intent_use_case_bench.py [--thinking minimal|low|medium|high]
"""

import argparse
import json
import mimetypes
import statistics
import sys
import time
from pathlib import Path

from google import genai
from google.genai import types


MODEL = "gemini-3.1-flash-lite"
SCREENSHOT_DIR = Path(__file__).parent / "screenshot"
RESULT_PATH = Path(__file__).parent / "intent_use_case_results_v6.json"

SYSTEM_PROMPT = """\
# Context

모찌(MOCHI)는 사용자가 일상에서 마주치는 무언가를 *나중에 다시 보고
싶어서* 빠르게 남기는 기록 도구다. 사용자는 모찌 앱을 따로 열지 않고도
아이폰 뒷면을 두 번 탭하기만 하면 그 순간 보던 화면이 모찌의 기록으로
남는다.

사용자 입장에서 본질은 "스크린샷을 찍었다" 가 아니라 **"무언가를 모찌에
남겼다"** 다. 화면 캡쳐는 우연한 형식이고, 진짜 행위는 "이거 잊지 말고
나중에 다시 보자" 라는 의도의 외부화다.

모찌 내부에서는 이 기록을 4개의 의미 분류 (schedule / todo / knowledge /
memo) 중 하나 이상으로 묶는다. 사용자는 한 화면을 *여러 의도* 때문에
동시에 남기는 경우가 흔하다 — 마우스 상품 페이지를 캡쳐한 사람은 "나중에
사야지" 와 "다른 곳 가격과 비교하자" 두 가지를 동시에 의도할 수 있고,
패션 캡쳐는 "사고 싶다" + "이뻐서 박제" 둘 다일 수 있다. LLM 이 단일
의도로 강제 분류하면 사용자의 실제 의도와 자주 어긋난다.

그래서 모찌는 캡쳐 직후 사용자에게 후보들을 보여주고 본인이 직접 의도(들)을
선택하게 한다. **당신이 만드는 3개의 후보 라벨이 그 선택지가 된다.**

# Objective

이 기록을 통해 사용자가 *나중에 다시 보려는 이유* 로 그럴듯한 시나리오
3개를 펼쳐라. 사용자가 후보를 보고 "아 맞아, 이거랑 이거 둘 다 때문에
저장한 거였지" 라고 즉시 알아챌 수 있어야 한다.

# Style — 라벨 작성

라벨은 사용자가 친구에게 "너 왜 이거 모찌에 남겼어?" 라는 질문에 답할
때 쓸 자연스러운 한국어다. 짧고 구체적인 행동·목적으로. 예시: "회신",
"미용실 예약", "대화 박제", "참고", "자랑", "구매 고민". 두 단어 이상이
더 자연스러우면 그것도 좋다.

시스템 분류 어휘 (todo, memo, knowledge, schedule) 와 일반적인 동작
명사 (저장, 캡쳐, 분류, 처리, 후속 작업) 는 라벨에 쓰지 않는다. 사용자는
모찌의 분류 체계를 모르므로 그런 단어를 보면 자기가 무엇을 고르는 건지
알 수 없다.

다만 사용자의 의도 자체가 진짜로 일반적인 동사 ("참고", "기록" 등) 인
경우 — 예컨대 정서적 박제처럼 저장 행위 자체가 목적인 케이스 — 그 단어가
가장 정확한 라벨이다. 무리하게 구체화하지 말 것. "그냥 참고용" 의도를
"기술 공부" 로 specific 하게 만들면 사용자 머릿속 어휘와 어긋난다.

# Audience

한국어 사용자. 모찌의 내부 도메인 어휘를 모른다. 본인의 행동·의도를
한 단어로 표현하는 게 인지 부담이 가장 낮다.

# Task — 후보 셋의 구성

세 후보는 *의미적으로 구별되는 의도* 여야 한다. 같은 4-Intent 매핑이라도
사용자 행동이 다르면 별개 후보로 둔다 (예: "회신" 과 "연락처 저장" 은
둘 다 todo 매핑이지만 사용자 행동이 다르므로 별개). 두 후보가 사실상 같은
행동의 약한 변형이면 한쪽을 더 먼 시나리오로 대체한다.

좁게 해석하지 않는다. 사람이 같은 화면을 모찌에 남기는 동기는 의외로
여러 차원에 걸쳐 있다 — 자기 참고용, 누군가에게 공유, 자랑/추억, 일정
등록, 행동 트리거, 정보 영구 보관 등. 세 후보가 한 차원에 몰리면 다른
차원도 한 자리 잡게 한다.

각 후보의 4-Intent 매핑은 다음 정의에 따른다:
- schedule: 특정 시점에 발생/참여하는 사건 (약속, 마감일, 행사)
- todo: 사용자가 직접 수행해야 할 행동 (구매, 답장, 신청, 시도)
- knowledge: 영구 참조 가치의 정보 (개념, 가이드, 학습)
- memo: 위 셋에 안 들어가는 정서적·일회적 기록 (영감, 추억, 자랑, 분위기)

# applicability — 각 후보의 독립 적용 강도

applicability 는 *그 후보가 사용자의 의도일 가능성* 을 0.0-1.0 으로
독립 표현한다. 진짜 확률이 아니다 — "이 의도가 이 기록에 얼마나 잘 들어맞는가"
라는 적용 강도다. 세 후보 합이 1.0 일 필요 없다. 같은 캡쳐가 여러 의도에
동시에 들어맞을 수 있기 때문이다.

기준:
- 0.85-1.0: 화면 증거가 이 의도를 강하게 지지함. 거의 확실히 사용자
  의도 중 하나.
- 0.5-0.8: 합리적 시나리오. 다른 후보와 동시 적용도 자연스럽다.
- 0.2-0.5: 가능하지만 확신은 낮음. 사용자만 알 수 있는 영역.
- 0.0-0.2: 거의 해당 안 됨 — 굳이 후보로 넣지 말 것.

본질적으로 모호한 케이스 (사용자만 답할 수 있는 경우) 는 비슷한 중간값으로
분산한다. 가짜 확신을 만들지 않는 게 모찌가 사용자에게 잘 묻기 위한
가장 가치 있는 신호다.

분기 신호 (silent / multi-select / 모호 fallback) 는 서버에서 applicability
값으로 후처리하므로 당신이 boolean 을 판단하지 않는다. 점수만 정직하게 박으면 된다.

reasoning 은 한 줄로, 왜 이 시나리오가 이 기록에서 그럴듯한지.

# Response — JSON 출력 형식

다음 형식의 JSON 만 반환한다. 다른 텍스트 없이.

```json
{
  "candidates": [
    {
      "label": "구매 고민",
      "intent": "todo",
      "applicability": 0.85,
      "reasoning": "상품 정보와 가격이 명시되어 있어 구매를 고려 중일 가능성이 가장 높음."
    },
    {
      "label": "가격 비교",
      "intent": "knowledge",
      "applicability": 0.65,
      "reasoning": "다른 매장과 비교하기 위한 참고 자료로 활용하려는 의도도 자연스러움."
    },
    {
      "label": "위시리스트",
      "intent": "memo",
      "applicability": 0.40,
      "reasoning": "지인 선물 후보로 저장해두는 경우도 가능."
    }
  ]
}
```
"""

RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "candidates": {
            "type": "array",
            "minItems": 3,
            "maxItems": 3,
            "items": {
                "type": "object",
                "properties": {
                    "label": {"type": "string"},
                    "intent": {
                        "type": "string",
                        "enum": ["schedule", "todo", "knowledge", "memo"],
                    },
                    "applicability": {"type": "number"},
                    "reasoning": {"type": "string"},
                },
                "required": ["label", "intent", "applicability", "reasoning"],
            },
        },
    },
    "required": ["candidates"],
}


def load_image(path: Path) -> types.Part:
    mime = mimetypes.guess_type(str(path))[0] or "image/png"
    return types.Part.from_bytes(data=path.read_bytes(), mime_type=mime)


def classify(client: genai.Client, image_path: Path, thinking: str) -> dict:
    image_part = load_image(image_path)
    prompt = (
        "이 스크린샷에 대한 use case 후보 3개를 생성하세요.\n"
        "JSON 만 응답. 다른 텍스트 없이.\n"
    )

    thinking_budget_map = {
        "minimal": 0,
        "low": 256,
        "medium": 1024,
        "high": 4096,
    }
    cfg = types.GenerateContentConfig(
        system_instruction=SYSTEM_PROMPT,
        temperature=0.3,
        max_output_tokens=1024,
        response_mime_type="application/json",
        response_schema=RESPONSE_SCHEMA,
        thinking_config=types.ThinkingConfig(
            thinking_budget=thinking_budget_map[thinking],
        ),
    )

    t0 = time.perf_counter()
    resp = client.models.generate_content(
        model=MODEL,
        contents=[image_part, prompt],
        config=cfg,
    )
    latency_ms = (time.perf_counter() - t0) * 1000

    try:
        parsed = json.loads(resp.text)
    except json.JSONDecodeError:
        parsed = {"_raw": resp.text, "candidates": [], "top_candidate_is_dominant": False}

    return {
        "file": image_path.name,
        "size_bytes": image_path.stat().st_size,
        "latency_ms": round(latency_ms, 1),
        "candidates": parsed.get("candidates", []),
        "top_candidate_is_dominant": parsed.get("top_candidate_is_dominant"),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--thinking",
        choices=["minimal", "low", "medium", "high"],
        default="minimal",
    )
    parser.add_argument("--project", default=None)
    parser.add_argument("--location", default="global")
    args = parser.parse_args()

    screenshots = sorted(SCREENSHOT_DIR.glob("*.PNG")) + sorted(SCREENSHOT_DIR.glob("*.png"))
    if not screenshots:
        print(f"No screenshots in {SCREENSHOT_DIR}", file=sys.stderr)
        return 1

    print(f"Model: {MODEL}  thinking={args.thinking}", file=sys.stderr)
    print(f"Screenshots: {len(screenshots)}\n", file=sys.stderr)

    client = genai.Client(vertexai=True, project=args.project, location=args.location)

    results = []
    for i, path in enumerate(screenshots, 1):
        print(f"[{i}/{len(screenshots)}] {path.name} …", file=sys.stderr, end=" ", flush=True)
        try:
            r = classify(client, path, args.thinking)
        except Exception as e:
            r = {"file": path.name, "error": str(e), "error_type": type(e).__name__}
        results.append(r)
        if "error" in r:
            print(f"ERROR: {r['error_type']}", file=sys.stderr)
        else:
            top = r["candidates"][0] if r["candidates"] else {}
            print(
                f"{r['latency_ms']}ms  top={top.get('label')}→{top.get('intent')} "
                f"L={top.get('likelihood')} dom={r['top_candidate_is_dominant']}",
                file=sys.stderr,
            )

    latencies = [r["latency_ms"] for r in results if "latency_ms" in r]
    summary = {
        "model": MODEL,
        "thinking": args.thinking,
        "n": len(results),
        "n_ok": len(latencies),
        "latency_ms": {
            "min": round(min(latencies), 1) if latencies else None,
            "p50": round(statistics.median(latencies), 1) if latencies else None,
            "mean": round(statistics.mean(latencies), 1) if latencies else None,
            "max": round(max(latencies), 1) if latencies else None,
        },
        "results": results,
    }

    RESULT_PATH.write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\n→ {RESULT_PATH}", file=sys.stderr)
    json.dump(summary, sys.stdout, ensure_ascii=False, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
