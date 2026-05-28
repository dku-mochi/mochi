---
description: 오늘 날짜의 journal 항목을 생성하거나 갱신한다 (하루 작업 로그)
argument-hint: [주제 한 줄]
---

오늘(`date +%Y-%m-%d`)의 작업 로그를 `journal/` 에 기록한다.

1. 오늘 날짜를 구한다.
2. `journal/<YYYY-MM-DD>-<주제>.md` 가 이미 있으면 이어 쓰고, 없으면 `journal/README.md` 의 템플릿으로 새로 만든다. 주제는 `$ARGUMENTS` (없으면 오늘 한 일에서 한 줄로 요약).
3. 이번 세션에서 실제로 한 일·결정·다음 할 일을 채운다. **대화 맥락에서 직접 작성**하고, 추측으로 채우지 않는다.
4. 의미 있는 코드/문서 변경이 있었다면 `docs/CHANGELOG.md` 에도 §6 규칙대로 한 줄 추가했는지 확인한다 (journal 은 과정, CHANGELOG 는 결과).

journal 은 L3(자주 바뀜) 문서다. 가볍게, 다음 사람이 0 부터 이어받을 수 있을 정도로만.
