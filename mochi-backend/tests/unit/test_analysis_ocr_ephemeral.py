"""ephemeral OCR(`analysis_ocr_text`) 불변식 — 분석 입력 주입 + 추론 후 삭제.

ephemeral OCR 은 iOS Vision OCR 화면 transcript 로, 분석 컨텍스트로만 쓰고 추론이 끝나면
지운다(영속/노출/인덱스 없음, PRIVACY §1.1). 여기서 검증하는 불변식:
1. orchestrator 가 source.text(사용자 명시 공유)와 **분리된 별도 블록**으로 주입한다(신뢰도 다름).
2. 값이 없으면 블록을 만들지 않는다.
3. apply_analysis 가 lifecycle=analyzed 와 같은 트랜잭션에서 컬럼을 NULL 로 비운다(삭제 훅).
4. API 계약: Create 에만 alias(analysisOcrText) 로 받고, Response/Update 엔 필드 자체가 없다(누수 차단).

repository SQL/raw UPDATE(DLQ) 의 owner-scope·문법은 프로젝트 컨벤션대로 코드 리뷰가 담당한다 —
DLQ(`mochi_item_worker` 영구 실패시 analysis_ocr_text=NULL)는 raw SQL 이라 누수 grep 게이트 + 리뷰로 본다.
삭제 훅(3)은 row 객체 변이라 fake 세션으로 단위 검증한다.
"""

from uuid import uuid4

import pytest

from app.modules.agent.application.orchestrator import _initial_user_text
from app.modules.agent.domain.gateway import AnalysisInput
from app.modules.mochi_items.infrastructure.orm import MochiItemRow
from app.modules.mochi_items.infrastructure.repository import PostgresMochiItemRepository
from app.modules.mochi_items.presentation.schemas import (
    MochiItemCreateRequest,
    MochiItemResponse,
    MochiItemUpdateRequest,
)

_OCR = "예매번호 A1234  좌석 G7  2026-07-01 19:30  카드 1234-5678-9012-3456"


def test_ocr_injected_as_block_separate_from_source_text() -> None:
    text = _initial_user_text(
        AnalysisInput(
            text="사용자가 적어 보낸 메모",
            url=None,
            user_memo=None,
            analysis_ocr_text=_OCR,
            images=(("gs://bucket/o.jpg", "image/jpeg"),),
        )
    )
    # OCR 은 자기 라벨 블록으로 들어가고, source.text 와 한 덩이로 섞이지 않는다(신뢰도 분리).
    assert "# 화면 텍스트 (OCR)" in text
    assert _OCR in text
    assert "내용:\n사용자가 적어 보낸 메모" in text
    # OCR 블록은 "내용:" 블록과 다른 블록(빈 줄 구분) — 같은 줄에 이어붙지 않는다.
    assert "사용자가 적어 보낸 메모\n예매번호" not in text


def test_no_ocr_block_when_absent() -> None:
    text = _initial_user_text(
        AnalysisInput(text="t", url=None, user_memo=None, analysis_ocr_text=None)
    )
    assert "# 화면 텍스트 (OCR)" not in text


class _FakeScalars:
    def __init__(self, row: MochiItemRow) -> None:
        self._row = row

    def one_or_none(self) -> MochiItemRow:
        return self._row


class _FakeSession:
    """apply_analysis 가 만지는 면만 흉내 — select 결과로 미리 만든 row 를 돌려준다.

    delete()/add()/flush() 는 no-op. row 객체 자체의 속성 변이(삭제 훅)를 실제로 관찰한다.
    """

    def __init__(self, row: MochiItemRow) -> None:
        self._row = row

    async def scalars(self, _stmt: object) -> _FakeScalars:
        return _FakeScalars(self._row)

    async def execute(self, _stmt: object) -> None:
        return None

    def add(self, _obj: object) -> None:
        return None

    async def flush(self) -> None:
        return None


@pytest.mark.asyncio
async def test_apply_analysis_clears_ephemeral_ocr() -> None:
    owner = uuid4()
    row = MochiItemRow(owner_id=owner, channel="screenshot", analysis_ocr_text=_OCR)
    row.id = uuid4()
    repo = PostgresMochiItemRepository(_FakeSession(row))  # type: ignore[arg-type]

    await repo.apply_analysis(
        owner_id=owner,
        mochi_item_id=row.id,
        intent_instances=(),
        needs_review=False,
        review_options=(),
        summary="요약",
        category=None,
        importance=3,
        model_version="classify_and_act@v26",
        entities=(),
    )

    # 추론 완료 → ephemeral 입력은 같은 트랜잭션에서 사라진다.
    assert row.analysis_ocr_text is None
    assert row.lifecycle_kind == "analyzed"


def test_create_request_accepts_ocr_alias() -> None:
    req = MochiItemCreateRequest.model_validate({"channel": "screenshot", "analysisOcrText": _OCR})
    assert req.analysis_ocr_text == _OCR


def test_response_and_update_have_no_ocr_field() -> None:
    # Response/Update 에 필드 자체가 없어야 한다 — 검색·노출 표면으로 OCR 이 새지 않게(구조적 차단).
    assert "analysis_ocr_text" not in MochiItemResponse.model_fields
    assert "analysis_ocr_text" not in MochiItemUpdateRequest.model_fields
