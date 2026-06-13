"""user_profiles.chat_summary — 채팅용 페르소나 프로필.

기존 ``summary`` 는 분석 개인화용(분류 성향). 채팅은 "이 사람이 누구인지"(관심사·취향·맥락)를
별도 관점으로 distill 해 채팅 system prompt 에 배경/톤으로 주입한다 — 용도·프롬프트가 달라
한 행에 두 관점을 nullable 컬럼으로 공존시킨다(라이프사이클이 1:1 이라 테이블 분리 불요).
근거: lab/active/chat-memory-injection 실험에서 분류성향 프로필 그대로 주입(A1)보다
페르소나 재-distill 주입(A2)이 답 품질 우위.

Revision ID: 0020
Revises: 0019
Create Date: 2026-06-13 16:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0020"
down_revision: str | None = "0019"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("user_profiles", sa.Column("chat_summary", sa.String(), nullable=True))


def downgrade() -> None:
    op.drop_column("user_profiles", "chat_summary")
