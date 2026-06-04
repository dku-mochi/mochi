"""MochiItem aggregate root — instance 모델 검증 (2026-06-04 빅뱅).

분류 결과는 worker(`apply_analysis`)가 ``intent_instances`` 로 채운다. 위계(primary/secondary)·
applicability·swap_primary 는 폐기됐다 — 저장된 instance 는 곧 active, 같은 type 다중 허용.
"""

from app.modules.mochi_items.domain.entities import IngestChannel, IngestSource, MochiItem
from app.modules.mochi_items.domain.value_objects import IntentInstance, IntentPayload, ReviewOption
from app.shared.intent import Intent


def _source(channel: IngestChannel = IngestChannel.SCREENSHOT) -> IngestSource:
    return IngestSource(channel=channel)


def test_default_is_empty_for_unclassified_ingestion() -> None:
    """일반 ingestion(분석 전) 은 instance 가 비고 needs_review=False."""
    item = MochiItem(id=_source().id, source=_source())
    assert item.intent_instances == ()
    assert item.needs_review is False
    assert item.review_options == ()
    assert item.intent_types == ()


def test_intent_types_dedupes_preserving_order() -> None:
    """같은 type 다중 instance 여도 intent_types 는 distinct(출현 순서 보존)."""
    source = _source()
    item = MochiItem(
        id=source.id,
        source=source,
        intent_instances=(
            IntentInstance(intent_type=Intent.TODO, label="회신"),
            IntentInstance(intent_type=Intent.TODO, label="구매"),  # 같은 type 둘
            IntentInstance(intent_type=Intent.KNOWLEDGE, label="참고"),
        ),
    )
    assert item.intent_types == (Intent.TODO, Intent.KNOWLEDGE)


def test_same_type_multiple_instances_allowed() -> None:
    """한 캡쳐가 todo instance 를 여러 개 가질 수 있다(위계 폐기)."""
    source = _source()
    item = MochiItem(
        id=source.id,
        source=source,
        intent_instances=(
            IntentInstance(intent_type=Intent.TODO, payload=IntentPayload(title="A")),
            IntentInstance(intent_type=Intent.TODO, payload=IntentPayload(title="B")),
        ),
    )
    assert len(item.intent_instances) == 2
    assert all(i.intent_type is Intent.TODO for i in item.intent_instances)


def test_needs_review_carries_review_options() -> None:
    """모호 케이스 — memo instance 1개 저장 + needs_review + review_options 후보."""
    source = _source()
    item = MochiItem(
        id=source.id,
        source=source,
        intent_instances=(IntentInstance(intent_type=Intent.MEMO, label="나중에 확인"),),
        needs_review=True,
        review_options=(
            ReviewOption(intent_type=Intent.TODO, label="할 일로 등록"),
            ReviewOption(intent_type=Intent.KNOWLEDGE, label="참고 저장"),
        ),
    )
    assert item.needs_review is True
    assert item.intent_types == (Intent.MEMO,)
    assert len(item.review_options) == 2
