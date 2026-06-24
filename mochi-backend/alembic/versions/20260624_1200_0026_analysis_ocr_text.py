"""mochi_items.analysis_ocr_text — 분석 전용 ephemeral OCR 텍스트.

iOS Vision OCR 이 캡처에서 뽑은 화면 transcript. **영속 데이터가 아니라 분석 입력 전용**이라
추론(analyzed)이 끝나면 같은 트랜잭션에서 NULL 로 비운다(`repository.apply_analysis`,
영구 실패 DLQ 도 NULL). 검색 인덱스·API Response·채팅 상세 어디에도 싣지 않는다 —
민감 게이트는 영속 텍스트(`text`)에만, 이 컬럼은 노출/인덱스/잔류 없음(PRIVACY §1.1).
nullable String — 분석 전까지만 값이 있고 그 뒤로는 NULL.

Revision ID: 0026
Revises: 0025
Create Date: 2026-06-24 12:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0026"
down_revision: str | None = "0025"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("mochi_items", sa.Column("analysis_ocr_text", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("mochi_items", "analysis_ocr_text")
