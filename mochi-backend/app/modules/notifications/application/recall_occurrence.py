"""능동 회수 알림 — occurrence-math (순수함수, DB 무관).

cron 워커(P3)가 active plan 의 "다음 발송할 occurrence" 를 계산하는 핵심 로직을 DB·세션과
분리해 단위테스트 가능하게 둔다. 정본 `journal/proactive-recall/schema.md` §3(lazy 동작)·§4(불변식).

세 trigger(relative / recurring / spaced) 각각 다음 occurrence 의 (stage_seq, occurrence_seq,
fire_at, expires_at) 또는 "더 없음/대기/종료" 신호를 반환한다. 입력은 전부 값(plan stages·anchor·
직전 발송 이력)이라 워커가 DB 에서 읽어 넘긴다 — 이 모듈은 시계도 세션도 모른다.

KST 단일 타임존 전제(codex-1) — whole-day offset/time_hint 의 시각 부여는 KST local 기준.
"""

from dataclasses import dataclass
from datetime import UTC, datetime, time, timedelta, timezone

from app.modules.notifications.domain.recall_plan import (
    AnchorKind,
    Stage,
    TriggerType,
)

# 단일 KST 전제(schema.md §3 codex-1). owner local date·time_hint·whole-day 시각 부여 기준.
KST = timezone(timedelta(hours=9))

# whole-day(시각 미지정) relative offset 또는 recurring/spaced 의 time_hint 가 없을 때 쓰는 기본 발송시각.
# planner §3: 활동 히스토그램 없으면 10~20시 윈도우 — 보수적 기본값 9시.
_DEFAULT_FIRE_HOUR_KST = 9


@dataclass(frozen=True, slots=True)
class NextOccurrence:
    """materialize 대상 1건. fire_at 은 가드 전 "원하는" 시각(가드가 defer/shift 할 수 있다)."""

    stage_seq: int
    occurrence_seq: int
    fire_at: datetime  # tz-aware UTC
    expires_at: datetime | None  # None=만료 없음


def parse_iso_duration(value: str) -> timedelta:
    """부호부 ISO-8601 duration → timedelta. DSL 검증(`_is_valid_duration`)을 통과한 값 전제.

    지원 component: W/D/H/M(분)/S. Y/M(월)은 정확한 일수가 없어 **미지원**(들어오면 ValueError) —
    회수 알림 offset 은 -P15D / -PT2H 류라 월/년 단위는 실제로 안 쓴다(planner §3).
    """
    sign = -1 if value[0] == "-" else 1
    body = value[1:]  # drop sign
    assert body[0] == "P", f"not an ISO duration: {value!r}"
    body = body[1:]
    if "Y" in body or "M" in body.split("T")[0]:
        raise ValueError(f"year/month duration not supported for recall offset: {value!r}")
    days = 0.0
    seconds = 0.0
    date_part, _, time_part = body.partition("T")
    if date_part.endswith("W"):
        days += float(date_part[:-1]) * 7
    elif date_part.endswith("D"):
        days += float(date_part[:-1])
    if time_part:
        num = ""
        for ch in time_part:
            if ch.isdigit():
                num += ch
            elif ch == "H":
                seconds += float(num) * 3600
                num = ""
            elif ch == "M":
                seconds += float(num) * 60
                num = ""
            elif ch == "S":
                seconds += float(num)
                num = ""
    return sign * timedelta(days=days, seconds=seconds)


def _is_whole_day_offset(offset: str) -> bool:
    """T(시각) component 가 없으면 whole-day — time_hint 시각을 입혀야 한다."""
    return "T" not in offset


def _apply_time_hint(day_utc: datetime, time_hint: str | None) -> datetime:
    """target 날짜(UTC aware)의 KST local date 에 time_hint(또는 기본시각)를 입혀 UTC 로 돌려준다."""
    local_date = day_utc.astimezone(KST).date()
    hour, minute = _DEFAULT_FIRE_HOUR_KST, 0
    if time_hint:
        try:
            parts = time_hint.split(":")
            hour, minute = int(parts[0]), int(parts[1]) if len(parts) > 1 else 0
        except (ValueError, IndexError):
            hour, minute = _DEFAULT_FIRE_HOUR_KST, 0
    fire_kst = datetime.combine(local_date, time(hour, minute), tzinfo=KST)
    return fire_kst.astimezone(UTC)


def resolve_anchor_time(
    *,
    anchor: AnchorKind,
    deadline_value: str | None,
    event_date_value: str | None,
    saved_at: datetime,
) -> datetime | None:
    """relative anchor 심볼 → 실제 기준 시각(UTC aware). 파싱 실패/없음 = None.

    schema.md §1: anchor 값은 캐시하지 않고 cron 이 발송 때 최신 payload 를 조회한다(여기 인자로 받음).
    deadline/event_date 는 free-text(payload.deadline / payload.date[+time]) — KST naive 가정.
    saved_at 은 item.created_at(UTC 저장)이라 그대로.
    """
    if anchor is AnchorKind.SAVED_AT:
        return _ensure_utc(saved_at)
    raw = deadline_value if anchor is AnchorKind.DEADLINE else event_date_value
    if not raw:
        return None
    return _parse_anchor_datetime(raw)


def _parse_anchor_datetime(raw: str) -> datetime | None:
    """free-text 마감/일정 문자열 → UTC aware. naive 면 KST 로 해석(사용자 체감 날짜)."""
    text = raw.strip()
    if not text:
        return None
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M", "%Y-%m-%d", "%Y/%m/%d", "%Y.%m.%d"):
            try:
                parsed = datetime.strptime(text, fmt)
                break
            except ValueError:
                continue
        else:
            return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=KST)
    return parsed.astimezone(UTC)


def _ensure_utc(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def next_relative_occurrence(
    *,
    stage: Stage,
    anchor_time: datetime,
    now: datetime,
    grace: timedelta,
    already_materialized: bool,
) -> NextOccurrence | None:
    """relative(다단/상대시간) 다음 occurrence. 단발(occurrence_seq=1).

    target = anchor_time + offset(부호부). whole-day offset 이면 target 날짜의 time_hint 시각,
    T 포함이면 계산된 시각 그대로. 이미 materialize 됐으면 None(중복 방지). target 이 과거+유예 초과면
    expires_at 을 now 로 세팅해 워커가 stale skip 하도록 신호한다(여전히 NextOccurrence 반환).
    """
    if already_materialized:
        return None
    offset = parse_iso_duration(stage.trigger.offset or "")
    target = anchor_time + offset
    if _is_whole_day_offset(stage.trigger.offset or ""):
        target = _apply_time_hint(target, stage.time_hint)
    expires_at: datetime | None = None
    if target < now - grace:
        # 발송 적기를 놓침 — 워커가 stale 처리. expires_at=target+grace(이미 지남)로 명시.
        expires_at = target + grace
    return NextOccurrence(
        stage_seq=stage.seq,
        occurrence_seq=1,
        fire_at=target,
        expires_at=expires_at,
    )


def next_recurring_occurrence(
    *,
    stage: Stage,
    base: datetime,
    last_occurrence_seq: int | None,
    until_time: datetime | None,
) -> NextOccurrence | None:
    """recurring(마감없는 주기) 다음 occurrence. 반응 무관 — 간격(interval_days)만 본다.

    occurrence_seq 는 0-base(occurrence0 = base + 1×interval). N = last+1(없으면 0).
    max_occurrences·until_anchor(until_time) 로 종료. 더 없으면 None(plan done 후보).
    """
    interval = stage.trigger.interval_days or 0
    if interval <= 0:
        return None
    next_n = 0 if last_occurrence_seq is None else last_occurrence_seq + 1
    max_occ = stage.trigger.max_occurrences
    if max_occ is not None and next_n >= max_occ:
        return None
    fire_at = _ensure_utc(base) + timedelta(days=interval * (next_n + 1))
    if until_time is not None and fire_at > _ensure_utc(until_time):
        return None
    return NextOccurrence(
        stage_seq=stage.seq,
        occurrence_seq=next_n,
        fire_at=fire_at,
        expires_at=None,
    )


@dataclass(frozen=True, slots=True)
class SpacedState:
    """직전 spaced occurrence 의 식별·반응 — 전진 판단 입력(schema.md §4 #1: 반응 기준, sent_at 아님).

    ``vetoed`` 는 user_veto 로 skip 된 occurrence(발송 전 사용자가 "이번 회차만 건너뛰기") —
    반응(opened)은 아니지만 명시적 "다음은 받겠다" 신호라 전진시킨다(§4 #1 예외). 이때 ``fire_at``
    (veto 된 칸의 예정 시각)이 다음 occurrence 의 전진 base 가 된다(opened_at 이 없으므로).
    """

    occurrence_seq: int
    sent_at: datetime | None
    opened_at: datetime | None
    dismissed_at: datetime | None
    fire_at: datetime | None = None
    vetoed: bool = False


# spaced 전진/대기/종료 신호.
SPACED_DONE = "done"  # dismissed → terminal(소멸)
SPACED_WAIT = "wait"  # sent 됐지만 미반응 → 전진 안 함(페널티 없음)


def next_spaced_occurrence(
    *,
    stage: Stage,
    base: datetime,
    last: SpacedState | None,
) -> NextOccurrence | str | None:
    """spaced(지식 정착) 다음 occurrence — **전진은 반응 기준**(schema.md §4 #1).

    반환:
      - NextOccurrence: materialize 할 다음 칸.
      - SPACED_DONE: 직전 occurrence 가 dismissed → plan terminal.
      - SPACED_WAIT: 직전이 sent 됐으나 미반응 → 대기(전진 안 함, 안누름≠negative).
      - None: schedule_days 소진(모두 발송·반응 완료) → plan done 후보.

    occurrence0 = base + schedule_days[0]. occurrence i>0 은 occurrence(i-1) 이 opened 일 때만,
    fire_at = opened_at + (schedule_days[i] - schedule_days[i-1]).

    예외(§4 #1): 직전이 user_veto("이번 회차만 건너뛰기")면 opened 없이도 다음 칸으로 전진하되,
    base 는 veto 된 칸의 예정 시각(fire_at)을 써 원래 간격을 유지한다("다음 회차는 예정대로").
    """
    schedule = stage.trigger.schedule_days or []
    if not schedule:
        return None
    if last is None:
        return NextOccurrence(
            stage_seq=stage.seq,
            occurrence_seq=0,
            fire_at=_ensure_utc(base) + timedelta(days=schedule[0]),
            expires_at=None,
        )
    if last.dismissed_at is not None:
        return SPACED_DONE
    next_i = last.occurrence_seq + 1
    if next_i >= len(schedule):
        return None  # 마지막 칸까지 발송·반응 완료
    gap_days = schedule[next_i] - schedule[next_i - 1]
    if last.vetoed:
        # user_veto("이번 회차만 건너뛰기") — opened 없이도 다음 칸으로 전진(§4 #1 예외).
        # base 는 veto 된 칸의 예정 시각(fire_at) → 원래 간격대로 "다음 회차는 예정대로".
        base_veto = last.fire_at or (_ensure_utc(base) + timedelta(days=schedule[last.occurrence_seq]))
        return NextOccurrence(
            stage_seq=stage.seq,
            occurrence_seq=next_i,
            fire_at=_ensure_utc(base_veto) + timedelta(days=gap_days),
            expires_at=None,
        )
    if last.opened_at is None:
        return SPACED_WAIT  # sent 됐지만 미반응 — 전진 보류(페널티 없음)
    return NextOccurrence(
        stage_seq=stage.seq,
        occurrence_seq=next_i,
        fire_at=_ensure_utc(last.opened_at) + timedelta(days=gap_days),
        expires_at=None,
    )


def stage_trigger_type(stage: Stage) -> TriggerType:
    """편의 — 워커 분기용."""
    return stage.trigger.type
