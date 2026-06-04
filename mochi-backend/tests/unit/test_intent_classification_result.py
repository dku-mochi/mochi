"""``_to_analysis_result`` — LLM 출력(DTO)을 도메인 결과로 1:1 분해 검증 (2026-06-04 빅뱅).

derive(argmax/confidence/secondary)는 폐기됐다 — LLM 이 ``intent_instances``·``needs_review``·
``review_options`` 를 직접 낸다. 저장하는 instance 는 모두 active. 같은 type 다중 보존.
"""

from app.modules.agent.application.orchestrator import _to_analysis_result
from app.shared.intent import Intent


def _payload(
    *,
    instances: list[tuple[Intent, str]] | None = None,
    needs_review: bool = False,
    review_options: list[tuple[Intent, str]] | None = None,
    payload: dict | None = None,
) -> dict:
    insts = instances if instances is not None else [(Intent.TODO, "회신")]
    return {
        "summary": "s",
        "needs_review": needs_review,
        "intent_instances": [
            {"intent_type": i.value, "payload": payload or {}, "label": label, "reasoning": "-"}
            for i, label in insts
        ],
        "review_options": [
            {"intent_type": i.value, "label": label, "reasoning": "-"}
            for i, label in (review_options or [])
        ],
        "entities": [],
        "importance": 3,
        "model_version": "m",
    }


def test_instances_are_decoded_1to1() -> None:
    r = _to_analysis_result(_payload(instances=[(Intent.TODO, "회신"), (Intent.KNOWLEDGE, "참고")]))
    assert tuple(i.intent_type for i in r.intent_instances) == (Intent.TODO, Intent.KNOWLEDGE)
    assert r.intent_instances[0].label == "회신"
    assert r.needs_review is False


def test_same_type_multiple_instances_preserved() -> None:
    """같은 type 다중 instance 가 보존된다(dedup 안 함 — 위계 폐기)."""
    r = _to_analysis_result(_payload(instances=[(Intent.TODO, "A"), (Intent.TODO, "B")]))
    assert len(r.intent_instances) == 2
    assert all(i.intent_type is Intent.TODO for i in r.intent_instances)


def test_needs_review_and_review_options_passthrough() -> None:
    r = _to_analysis_result(
        _payload(
            instances=[(Intent.MEMO, "나중에 확인")],
            needs_review=True,
            review_options=[(Intent.TODO, "할 일로 등록"), (Intent.KNOWLEDGE, "참고 저장")],
        )
    )
    assert r.needs_review is True
    assert tuple(o.intent_type for o in r.review_options) == (Intent.TODO, Intent.KNOWLEDGE)
    assert r.review_options[0].label == "할 일로 등록"


def test_payload_typed_fields_extracted() -> None:
    r = _to_analysis_result(
        _payload(
            instances=[(Intent.SCHEDULE, "마감")],
            payload={"title": "장학금 신청", "deadline": "2026-06-20 18:00"},
        )
    )
    assert r.intent_instances[0].payload.title == "장학금 신청"
    assert r.intent_instances[0].payload.deadline == "2026-06-20 18:00"
    assert r.intent_instances[0].payload.note is None


def test_empty_instances_allowed_when_review() -> None:
    """instance 0개도 유효(모호 케이스). needs_review 가 신호이고 후보는 review_options 로."""
    r = _to_analysis_result(
        {
            "summary": "s",
            "needs_review": True,
            "intent_instances": [],
            "review_options": [{"intent_type": "todo", "label": "x", "reasoning": "-"}],
            "model_version": "m",
        }
    )
    assert r.intent_instances == ()
    assert r.needs_review is True
    assert len(r.review_options) == 1
