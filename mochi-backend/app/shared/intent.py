from enum import StrEnum


class Intent(StrEnum):
    """모찌의 4-Intent 분류. iOS `CoreDomain.Intent` 와 완전히 동일한 문자열 값."""

    SCHEDULE = "schedule"
    TODO = "todo"
    KNOWLEDGE = "knowledge"
    MEMO = "memo"

    @property
    def display_name_ko(self) -> str:
        return {
            Intent.SCHEDULE: "일정",
            Intent.TODO: "할일",
            Intent.KNOWLEDGE: "지식",
            Intent.MEMO: "기록",
        }[self]
