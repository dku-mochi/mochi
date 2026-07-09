"""분석 에이전트 eval — 결정적 채점기 (Tier 1).

`lab/active/dacon-schedule-extraction/v23_ab_bench.py` 의 `score_dacon` 8축 채점 로직을
**케이스-구동형**으로 일반화했다. 한 이미지에 하드코딩돼 있던 `CORE`/`FORBIDDEN`/`noise_kw` 를
케이스가 데이터로 들고 오고, 이 모듈은 분석 출력(`finalizeAnalysis` args =
`gemini_agent_client._FINALIZE_PARAMS` 모양)을 그에 대해 채점한다.

순수 함수 — LLM/네트워크/DB 없음. 그래서 hermetic 스냅샷 테스트(`tests/eval/`)와 live 러너
(`eval/run_golden.py`)가 **같은 채점기**를 공유한다(채점 일관성 = 게이트 신뢰성).

채점은 8축이 아니라 "케이스가 명시한 축만" 평가한다 — 단순 분류 케이스는 `intent_set` 하나만,
표 분해 케이스는 recall/forbidden/span 까지. `passed` 는 *적용된* 축이 모두 통과했을 때만 True.

## 케이스 expected 스키마 (모두 optional — 케이스가 검사할 축만 채운다)

    expected = {
      # 분해/분류 — 표·목록 케이스
      "core": [                       # 각 항목마다 ≥1 instance 가 kw 로 잡혀야 함
        {"name": "결과발표",
         "kw": ["결과발표", "예선 결과"],   # 이 중 하나라도 instance 텍스트에 있으면 hit
         "type": "schedule",              # (opt) 잡은 instance 의 기대 intent_type
         "date": "2026-07-27"},           # (opt) payload.date|deadline 의 기대 ISO 날짜
      ],
      "forbidden": [                  # instance 로 만들면 과생성 — 만들면 감점
        {"name": "대회기간(우산span)", "kw": ["대회기간", "참가 기간"]},
      ],
      "noise_kw": ["dacon.io", "58%", "더보기"],   # instance 에 끌어들이면 감점(화면 노이즈)
      "span_allowed": False,          # (opt) False 면 end_date 채운 instance 가 있을 때 감점

      # 단순 분류 케이스 (text_memos 류)
      "intent_set": ["schedule"],     # (opt) 산출된 intent_type 집합이 정확히 이것이어야
      "count_band": {"min": 1, "max": 1},   # (opt) instance 개수 허용 밴드(정확수는 flaky → 밴드)

      "needs_review": False,          # (opt) 기대 needs_review boolean
    }

intent 정의/payload 의미는 `docs/DOMAIN_DESIGN.md` 가 정본 — 이 채점기는 그 정의의 소비자일 뿐
정의를 새로 만들지 않는다.
"""

from __future__ import annotations

from typing import Any

# --- intent_instance 에서 매칭용 텍스트/날짜 뽑기 (score_dacon 과 동일 규칙) ---


def _inst_text(ins: dict[str, Any]) -> str:
    p = ins.get("payload") or {}
    return " ".join(
        str(x)
        for x in [
            p.get("title", ""),
            ins.get("label", ""),
            ins.get("reasoning", ""),
            p.get("note", ""),
        ]
    )


def _date_of(ins: dict[str, Any]) -> str:
    p = ins.get("payload") or {}
    raw = p.get("deadline") or p.get("date") or ""
    return raw[:10] if raw else ""


def score_case(output: dict[str, Any], expected: dict[str, Any]) -> dict[str, Any]:
    """분석 출력 1건을 케이스 expected 에 대해 결정적으로 채점한다.

    반환 dict 는 채점한 각 축 + ``passed``(적용된 모든 축 통과 시 True, 검사 축이 없으면 None).
    """
    insts = output.get("intent_instances") or []
    n = len(insts)
    result: dict[str, Any] = {"n": n}
    applied: list[bool] = []  # 적용된 축들의 통과 여부 → passed 집계

    # 1) Recall + 잡은 core 의 type/date 정확도 ----------------------------------
    core = expected.get("core") or []
    if core:
        hits: dict[str, dict | None] = {}
        for spec in core:
            hits[spec["name"]] = next(
                (ins for ins in insts if any(k in _inst_text(ins) for k in spec["kw"])),
                None,
            )
        recall = sum(1 for v in hits.values() if v is not None)
        result["recall"] = f"{recall}/{len(core)}"
        result["recall_detail"] = {k: (v is not None) for k, v in hits.items()}
        applied.append(recall == len(core))

        type_ok = True
        date_check: dict[str, list] = {}
        for spec in core:
            ins = hits[spec["name"]]
            if ins is None:
                continue
            if spec.get("type") and ins.get("intent_type") != spec["type"]:
                type_ok = False
            if spec.get("date"):
                got = _date_of(ins)
                date_check[spec["name"]] = [got or "(empty)", got == spec["date"]]
        if any(s.get("type") for s in core):
            result["type_ok"] = type_ok
            applied.append(type_ok)
        if date_check:
            date_ok = all(v[1] for v in date_check.values())
            result["date_check"] = date_check
            result["date_accuracy"] = date_ok
            applied.append(date_ok)

    # 2) 과생성 — forbidden 을 instance 로 만들었나 -------------------------------
    forbidden = expected.get("forbidden") or []
    if forbidden:
        over = [
            spec["name"]
            for spec in forbidden
            if any(any(k in _inst_text(ins) for k in spec["kw"]) for ins in insts)
        ]
        result["over"] = over
        applied.append(not over)

    # 3) 화면 노이즈 내성 --------------------------------------------------------
    noise_kw = expected.get("noise_kw") or []
    if noise_kw:
        noise = any(any(k in _inst_text(ins) for k in noise_kw) for ins in insts)
        result["noise"] = noise
        applied.append(not noise)

    # 4) span 오용 — span 불허인데 end_date 채움 (정보성 기간을 instance 화) ------
    if expected.get("span_allowed") is False:
        span_misuse = any((ins.get("payload") or {}).get("end_date") for ins in insts)
        result["span_misuse"] = span_misuse
        applied.append(not span_misuse)

    # 5) intent_set — 단순 케이스: 산출 intent_type 집합 정확 일치 ----------------
    if expected.get("intent_set") is not None:
        got_set = sorted({ins.get("intent_type") for ins in insts})
        want_set = sorted(set(expected["intent_set"]))
        ok = got_set == want_set
        result["intent_set"] = {"got": got_set, "want": want_set, "ok": ok}
        applied.append(ok)

    # 6) 분해 개수 밴드 (정확수는 flash-lite 변동에 flaky → 밴드로) ----------------
    band = expected.get("count_band")
    if band:
        ok = band["min"] <= n <= band["max"]
        result["count_ok"] = ok
        applied.append(ok)

    # 7) needs_review --------------------------------------------------------------
    if "needs_review" in expected:
        got = output.get("needs_review")
        ok = got == expected["needs_review"]
        result["needs_review"] = got
        result["needs_review_ok"] = ok
        applied.append(ok)

    result["passed"] = all(applied) if applied else None
    return result


def score_tool_gating(called_tools: list[str], expected: dict[str, Any]) -> dict[str, Any]:
    """tool-gating 케이스 채점 — 어떤 tool 을 불렀나/안 불렀나.

    expected = {"must_call": ["findReferenceUrls"], "must_not_call": ["platformContext"]}
    분석 출력으로는 측정 불가(루프 안에서 일어남) — orchestrator 가 캡처한 tool 호출 이름 목록
    (run_golden 의 tool-gating 모드)을 받는다.
    """
    must = expected.get("must_call") or []
    must_not = expected.get("must_not_call") or []
    called = set(called_tools)
    must_ok = all(t in called for t in must)
    must_not_ok = all(t not in called for t in must_not)
    return {
        "called": sorted(called),
        "must_call_ok": must_ok,
        "must_not_call_ok": must_not_ok,
        "passed": must_ok and must_not_ok,
    }
