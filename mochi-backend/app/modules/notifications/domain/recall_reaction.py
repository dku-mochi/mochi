"""능동 회수 알림 반응 수집(P5) 도메인 — 반응 종류 + outbox 반응 포트.

정본 `journal/proactive-recall/notification-agent.md` §5(반응 수집·codex-6 멱등)·§6(신호) /
`ux-ui.md` §4("그만" scope 1:1 codex-7) / `schema.md` §2(outbox opened_at/dismissed_at).

신호 의미(§6): opened 만 양성. dismissed/stop=명시 부정. 안 누름 ≠ negative. 여기선 기록만(학습 후속).

프레임워크 import 금지(sqlalchemy 는 infrastructure 한정 — 모듈 경계테스트).
"""

from abc import ABC, abstractmethod
from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass
from enum import StrEnum
from uuid import UUID


class ReactionKind(StrEnum):
    """알림 반응 종류 — iOS 가 보고하는 3종.

    - opened: 알림 탭(양성 신호). spaced 면 회수 소생 트리거(HIGH-2).
    - dismissed: soft 부정(cooldown 신호). 멱등.
    - stop: "이 기억 그만" 영구 부정 → plan cancelled(codex-7 1:1).
    """

    OPENED = "opened"
    DISMISSED = "dismissed"
    STOP = "stop"


@dataclass(frozen=True, slots=True)
class SentRecallEvent:
    """status='sent' 인 outbox 반응 대상 행의 식별·소생 정보.

    멱등 분기(0행 UPDATE 후 404 vs no-op)와 spaced 소생(HIGH-2)에 필요한 필드만 담는다.
    """

    event_id: UUID
    kind: str  # deadline | nudge | spaced | recall
    plan_id: UUID | None
    source_item_id: UUID | None
    source_intent_id: UUID | None


class RecallReactionRepositoryPort(ABC):
    """notification_outbox 반응 컬럼 갱신 + stop 의 plan cancel. owner-scoped, first-write-wins.

    멱등·보안(codex-6): 모든 갱신은 `(event_id, owner_id)` + `status='sent'` 인 행만 atomic UPDATE
    가드로 친다. 남의 event_id 조작·중복 탭 방어. P3+P4 worker 와 별개 파일(worker 비접촉).
    """

    @abstractmethod
    async def find_sent_event(self, *, event_id: UUID, owner_id: UUID) -> SentRecallEvent | None:
        """`(event_id, owner_id)` + `status='sent'` 인 행 조회. 없으면 None(→ 404 분기·소생 컨텍스트)."""

    @abstractmethod
    async def mark_opened(self, *, event_id: UUID, owner_id: UUID) -> int:
        """`opened_at IS NULL` 인 sent 행에만 `opened_at=now()`. 갱신된 행수(0=이미 opened/없음)."""

    @abstractmethod
    async def mark_dismissed(self, *, event_id: UUID, owner_id: UUID) -> int:
        """`dismissed_at IS NULL` 인 sent 행에만 `dismissed_at=now()`. 갱신된 행수(0=이미 dismissed/없음)."""

    @abstractmethod
    async def cancel_plan(self, *, plan_id: UUID, owner_id: UUID) -> None:
        """stop 시 그 outbox 의 plan 을 영구 취소(status='cancelled', cancel_reason='user_dismiss').

        owner-scope 가드 — cross-tenant cancel 차단. plan_id NULL(트랙C)이면 호출하지 않는다.
        같은 plan 의 미발송 outbox(pending/deferred)도 skipped(cancelled) 로 대칭 정리한다.
        """

    @abstractmethod
    async def bump_plan_next_eligible(self, *, plan_id: UUID, owner_id: UUID) -> None:
        """active plan 의 next_eligible_at 을 now 로 당겨 다음 materialize tick 에서 즉시 재평가시킨다.

        spaced veto("이번 회차만") 후 다음 occurrence 를 곧바로 만들기 위해(occurrence 는 이미
        user_veto skip). owner-scope + status='active' 가드. plan_id NULL(트랙C)이면 호출 안 함.
        """

    @abstractmethod
    async def skip_recall_outbox(self, *, event_id: UUID, owner_id: UUID) -> None:
        """트랙 C(plan 없는 recall 직행) stop 시 그 sent outbox 행을 skipped(cancelled) 로 종결.

        plan 이 없어 cancel_plan 으로 못 거르는 트랙 C 를 피드에서 영구 제외한다 — 피드 쿼리는
        status IN ('pending','sent') 만 후보로 보므로, skipped 면 재fetch(앱 재시작)에도 다시
        안 뜬다(codex-7 stop=영구). owner-scope + status='sent' 가드.
        """

    # ---- 피드 반응(item 기준) — event 가 없거나 pending 인 피드 카드용 (부활 버그 수정) ----

    @abstractmethod
    async def open_recall_rows_for_item(self, *, owner_id: UUID, item_id: UUID) -> int:
        """피드 open 시 그 item 의 kind='recall' pending/sent 행 전부에 opened_at 기록.

        pending 행은 skipped(opened) 로 종결까지 — 이미 열어본 카드의 뒷북 푸시 방지 + 피드
        후보(status IN pending/sent)에서 제외. sent 행은 opened_at 만(피드 쿼리의 opened 필터가
        제외). 전부를 치는 이유: 최신 행만 치면 그 아래 옛 sent 미open 행이 후보로 재부상한다.
        갱신된 행수 반환(0=칠 행 없음, 정상)."""

    @abstractmethod
    async def list_active_spaced_plan_ids(self, *, owner_id: UUID, source_item_id: UUID) -> list[UUID]:
        """그 item 을 소스로 갖는 active spaced plan id 목록 — 피드 stop 의 트랙 A plan cancel 용.

        plan_kind='spaced' 한정 — deadline/nudge plan 은 회수 피드가 아닌 예정 알림 표면의
        veto 가 담당한다(표면 1:1)."""

    @abstractmethod
    async def stop_recall_rows_for_item(self, *, owner_id: UUID, item_id: UUID) -> int:
        """피드 stop 시 그 item 의 kind='recall' pending/sent 행 전부를 skipped(cancelled) 종결.

        dismissed_at 도 채워 트랙 C 재생성 dismiss-cooldown 신호(last_dismissed_for_intent)를
        보존한다. 갱신된 행수 반환."""

    @abstractmethod
    def savepoint(self) -> AbstractAsyncContextManager[None]:
        """best-effort 부수효과(spaced 소생)를 감쌀 트랜잭션 savepoint(중첩 트랜잭션).

        안에서 DB 에러가 나도 이 savepoint 만 롤백되고 outer 트랜잭션(이미 flush 된 opened_at)은
        aborted 되지 않아 라우터의 commit 이 PendingRollbackError 없이 성공한다(codex P1#4).
        infra 는 `session.begin_nested()`. 예외는 그대로 전파(호출부 try/except 가 격리 책임).
        """
