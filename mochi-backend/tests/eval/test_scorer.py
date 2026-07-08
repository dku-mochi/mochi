"""eval 결정적 채점기(eval/scorer.py) hermetic 테스트.

live LLM 없이 채점 로직만 검증한다 — `make test` 에 자연 편입되는 ② CI 게이트.
채점기가 잘못되면 게이트 전체가 잘못되므로, 각 축이 통과/실패를 제대로 가르는지 고정한다.
"""

import sys
from pathlib import Path

# eval/ 는 app 패키지 밖이라 경로 주입 (run_golden 과 동일 방식)
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "eval"))

from scorer import score_case, score_tool_gating  # noqa: E402


def _inst(intent_type: str, title: str, **payload) -> dict:
    return {"intent_type": intent_type, "payload": {"title": title, **payload}, "label": "", "reasoning": ""}


def test_intent_set_match_passes():
    out = {"intent_instances": [_inst("schedule", "오후 3시 치과")], "needs_review": False}
    assert score_case(out, {"intent_set": ["schedule"], "count_band": {"min": 1, "max": 1}})["passed"] is True


def test_intent_set_mismatch_fails():
    out = {"intent_instances": [_inst("schedule", "오후 3시 치과")]}
    assert score_case(out, {"intent_set": ["todo"]})["passed"] is False


def test_overcount_fails():
    out = {"intent_instances": [_inst("memo", "a"), _inst("memo", "b")]}
    assert score_case(out, {"count_band": {"min": 1, "max": 1}})["passed"] is False


def test_recall_all_core_and_dates_passes():
    out = {"intent_instances": [
        _inst("todo", "기획서 제출", deadline="2026-07-07"),
        _inst("schedule", "결과발표 확인", date="2026-07-27"),
    ]}
    exp = {"core": [
        {"name": "기획서", "kw": ["기획서"], "type": "todo", "date": "2026-07-07"},
        {"name": "결과발표", "kw": ["결과발표"], "type": "schedule", "date": "2026-07-27"},
    ]}
    r = score_case(out, exp)
    assert r["recall"] == "2/2"
    assert r["date_accuracy"] is True
    assert r["type_ok"] is True
    assert r["passed"] is True


def test_missing_core_fails_recall():
    out = {"intent_instances": [_inst("todo", "기획서 제출", deadline="2026-07-07")]}
    exp = {"core": [
        {"name": "기획서", "kw": ["기획서"]},
        {"name": "결과발표", "kw": ["결과발표"]},
    ]}
    assert score_case(out, exp)["passed"] is False


def test_forbidden_overgeneration_fails():
    out = {"intent_instances": [_inst("todo", "참가접수 마감 확인")]}
    exp = {"forbidden": [{"name": "참가접수", "kw": ["참가접수"]}]}
    r = score_case(out, exp)
    assert r["over"] == ["참가접수"]
    assert r["passed"] is False


def test_span_misuse_fails():
    out = {"intent_instances": [_inst("schedule", "여름 할인기간", date="2026-07-01", end_date="2026-07-31")]}
    assert score_case(out, {"span_allowed": False})["passed"] is False


def test_wrong_date_fails():
    out = {"intent_instances": [_inst("schedule", "결과발표", date="2026-07-28")]}
    exp = {"core": [{"name": "결과발표", "kw": ["결과발표"], "date": "2026-07-27"}]}
    assert score_case(out, exp)["date_accuracy"] is False


def test_needs_review_axis():
    out = {"intent_instances": [_inst("memo", "흐릿한 캡처")], "needs_review": True}
    assert score_case(out, {"needs_review": True})["needs_review_ok"] is True
    assert score_case(out, {"needs_review": False})["needs_review_ok"] is False


def test_tool_gating():
    assert score_tool_gating(["findReferenceUrls"], {"must_call": ["findReferenceUrls"]})["passed"] is True
    assert score_tool_gating(["platformContext"], {"must_not_call": ["platformContext"]})["passed"] is False
    assert score_tool_gating([], {"must_call": ["findReferenceUrls"]})["passed"] is False


def test_no_axis_returns_none():
    # 검사할 축이 하나도 없으면 passed=None (게이트 대상 아님)
    assert score_case({"intent_instances": []}, {})["passed"] is None
