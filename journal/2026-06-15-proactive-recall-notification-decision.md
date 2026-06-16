---
level: 3
mode: log
status: draft
last_verified: 2026-06-15
confidence: 0.78
owners: [송준서]
title: 능동 회수 알림(notification) — "푸시 금지"를 폐기하고 "누르고 싶은 알림"에 이르기까지
description: 능동 회수의 앱-밖 획득 장치인 notification 설계 결정·근거 로그. Claude×codex 토론과 송준서 교정으로 design.md의 "트랙 C 푸시 절대 금지"가 폐기되고, notification이 트랙 C의 메인 능동 발화 장치가 된 과정을 "왜" 중심으로 담는다. 핵심: 앱 켜기조차 싫어하는 사용자에겐 앱-안 카드만으론 회수가 발화하지 않아 능동성이 자기모순으로 죽는다 → notification이 부르되 "애매하면 안 보낸다"(저품질 = 정체성 손상). hook produces(저장 시 후보 생산) / cron decides(주기 재평가 후 발송) 역할 분담, 발송·보류 판정 기준, 위험 통제가 본문. 능동 회수 알림·스케줄러·발송 빌더를 구현하기 전 읽어라. 미승인 — committed PROPOSAL·design 의 푸시 정책 정정이 선행. 자매: 2026-06-15-proactive-recall-ux-decision.md(홈/회수 UX, landing 표면). 선행: -design.md·-tech-design.md.
---

# 능동 회수 알림(notification) 설계 — 2026-06-15

> 코드 변경 없음(설계만). 자매 문서 `…-ux-decision.md`가 **앱-안 회수 표면**(홈 한 칸 → 자세히 → 기록 상세)을 다룬다면, 이 문서는 **앱-밖 획득 장치**(notification)를 다룬다. 둘은 "notification이 부른다 → landing(회수 표면)으로 착지"로 이어진다. **미구현 — 설계 근거 기록.**

---

## 0. TL;DR

- `design.md §4`의 **"트랙 C 푸시 절대 금지, 카드만"** 원칙을 **폐기**한다.
- 이유: 앱 켜기조차 싫어하는 사용자에게 **앱-안 카드만이면 앱을 켜야 회수가 발화** → 사용자가 안 켜니 회수가 안 일어남 → "모찌가 능동적으로 떠올려준다"는 미션이 **자기모순으로 죽는다.** 능동성은 앱 밖에서 부르는 notification에서만 나온다.
- 단 "푸시함"이 아니라 **"메인 발화 장치 = notification, 극도로 제한된 고신뢰 패키지만 배달"**. 원칙은 *"좋은 푸시를 만든다"*가 아니라 **"애매하면 안 보낸다"** — 가장 큰 위험은 스팸(빈도)이 아니라 **저품질("모찌가 헛소리한다")로 인한 정체성 손상**이다.
- 구조: **hook produces / cron decides** — 저장 시 hook이 후보만 생산, 주기적 cron이 발송 여부를 판정.

---

## 1. 왜 notification이 메인인가 (송준서 교정)

- 송준서: **"사용자는 키보드 두들기는 걸 싫어한다"** → 채팅을 메인 회수 장치로 둘 수 없다(타이핑 비용). **"앱 켜는 것조차 싫어할 것이다"** → 앱-안 카드만으론 회수가 사용자에게 도달하지 않는다.
- 그러니 사용자를 회수로 데려오는 유일한 능동 표면은 **"누르고 싶은" notification**이다. 들어오면 → 예전(3일~1년 폭) 기록을 *모찌가 미리 정리한 형태*로 제공해 리마인드 + 체류시간을 늘린다.
- 채팅 회수(T2)는 이미 구현돼 있고 보조다 — 새 1순위가 아니다.

---

## 2. "트랙 C 푸시 금지" 폐기 — 미션과의 모순 (codex ACCEPT)

- `design.md §4`: 시급한 트랙 B(약속·마감)만 푸시, 트랙 A·C는 "홈 섹션 + digest, 푸시 금지"(알림 피로 = 앱 삭제 우려).
- 그러나 트랙 C를 앱-안 카드로만 두면 **"열어보면 정리돼 있다"**이지 **"모찌가 떠올려준다"**가 아니다. 미션(`PRODUCT.md §1.5` — 회수의 능동 주체는 모찌)과 정면 충돌.
- codex 판정: **폐기.** 단 "트랙 C도 푸시한다"가 아니라 **"메인 능동 발화 장치는 notification이고, notification은 극도로 제한된 고신뢰 recall package만 배달한다"**로 바꾼다. 알림 피로의 해법은 "푸시 안 함"이 아니라 **"누를 가치 있는 것만 푸시"** — 품질을 극한으로 올려 피로를 통제.

---

## 3. "누르고 싶은 알림" 판정 기준 (핵심 — "애매하면 안 보낸다")

송준서의 4원칙(구체적 가치 프리뷰 / 희소성 / 미완결 호기심 / 타이밍)은 *필요조건*이고, codex가 충분조건을 보강했다. 발송은 화이트리스트가 아니라 **게이트 통과 + 애매하면 보류**다.

### 보낸다 (모두 충족 시)
- push 권한 있음
- 최근 24시간 내 트랙 C 푸시 없음 (하루 캡)
- 최근 7일 내 같은 theme/item 푸시 없음 (cooldown)
- candidate age가 **3일 ~ 1년** 범위 (너무 최신도 너무 오래도 아님)
- `revisit_score`(재방문가치) 임계 이상
- `context_boost`(현재 관련성) 또는 importance 임계 이상
- **notification preview에 구체 명사 1~2개** 포함 ("마우스 2개" "RAG 자료 3개" — generic 금지)
- **landing package가 이미 생성됨** — 누른 뒤 빈 화면/검색 결과 목록이면 **발송 금지**
- 같은 날 트랙 B(마감·일정) 푸시가 있으면 트랙 C는 **양보**

### 참는다 (하나라도 해당 시)
- "저장한 걸 다시 보세요" 수준의 generic copy밖에 못 만들 때
- 후보가 1개뿐인데 다시 볼 이유가 약할 때
- 최근에 사용자가 이미 열어본 item일 때
- 이전에 같은 카드가 노출됐는데 무시(dismiss)됐을 때
- LLM이 이유를 만들었지만 근거 item이 약할 때
- 푸시 후 들어갈 정리 화면(landing)이 준비 안 됐을 때

> **landing readiness가 가장 영리한 제약** — "누르면 정리된 화면이 준비돼 있어야 발송"은 송준서의 *체류시간* 목표와 직결된다. notification과 landing은 **한 쌍**으로 생성돼야 한다.

---

## 4. hook produces / cron decides (역할 분담)

`tech-design.md §2.2`의 "트랙 C = 분석 후단 hook only, 별도 cron 없음"은 notification과 구조적으로 안 맞는다 — hook은 *사용자가 저장할 때만* 돌지만, notification의 본질은 *사용자가 아무것도 안 해도 모찌가 먼저 부르는 것*이라 조건 스캐너(cron)가 필수다.

- **Hook (후보 생산)**: 분석 완료 후 embedding/entity/summary 기반 related candidates 생성, decision 후보 계산, candidate/reason 저장. **즉시 push 안 함** (저장 직후 in-app 회수에는 사용 가능).
- **Cron (발송 판단)**: 하루 1~수 회 사용자별 scan → `재방문가치 × context_boost` 재계산 → cooldown/dismiss/opened 반영 → 트랙 B와 충돌 조정 → push candidate를 notification package로 승격 → 실제 발송 또는 dry-run 로그.

> 거창한 분산 스케줄러 불필요 — 기존 outbox 폴링 패턴을 시간축으로 확장한 경량 cron(main.py lifespan worker)이면 충분. 원칙만 "hook only" → **"hook produces, cron decides"**로 바뀐다.

---

## 5. 우선순위 (3턴→4턴에서 재정렬)

토론 초반 "T2 채팅 1순위"는 폐기됐다(채팅 = 타이핑, 이미 구현). 최종:

1. **Notification Recall Loop** — 조건 스캐너 + 발송 적격성 + preview 생성 + 발송 로그/cooldown
2. **Recall Landing Package** — 누르면 들어가는 정리 화면 (= 자매 journal의 회수 자세히/상세)
3. **Home Reminder 한 칸** — notification inbox 성격 (앱 안에서 남은 회수)
4. **decision_compare** — 단 비교 데모는 자매 journal에서 overfit으로 폐기됨 (notification 카드 타입으로도 신중)
5. **T1 저장 직후 회수** — 후보 생산기 + 보조 delight
6. **T2 채팅 회수** — 이미 구현, 보조. 결과를 cron의 context signal로 환류

---

## 6. 가장 큰 위험과 통제

**가장 큰 위험은 스팸(빈도)이 아니라 저품질(정체성)이다.** "모찌가 헛소리한다"는 한 번이면 신뢰가 깨진다. 통제:

- 하루 최대 1건, 주 최대 3건
- 같은 theme 7~14일 cooldown
- 트랙 B 일정 푸시와 같은 날 충돌 시 트랙 C 양보/후순위
- generic copy 금지 / landing package 없는 푸시 금지
- **dry-run 모드** — 후보·문구·점수를 로그로 먼저 확인하고 발송 0으로 튜닝
- demo 계정(실데이터 103개)으로 threshold 수동 튜닝
- LLM copy는 근거 item의 title/entity/summary에서 **증거 있는 말만** (과장 금지)
- **발송 로그 테이블**: `reason`·`score`·`candidate_ids`·`copy`·`sent_at`·`opened_at`·`dismissed_at`
- **서버 kill switch** 필수
- 야간 무음 + 활동 시간대

---

## 7. 미해결 / 기존 문서 정합 (정정 필요 — 미반영)

**미해결:**
- preview copy 품질(구체 vs generic 비율) — 실데이터 flash-lite 생성으로 실측 후 임계 튜닝(lab 후속).
- cron 주기·발송 임계(revisit_score·context_boost)·decay 실측.
- landing package의 풍부함(사전 정리 A-3 깊이) — notification preview와 landing 양쪽.

**정합 폭포 (committed/선행 정정, 팀 합의 선행):**
- `design.md §4` "트랙 C 푸시 절대 금지" → **폐기**(notification 메인, 품질 게이트로 피로 통제).
- `tech-design.md §2.2` "트랙 C hook only, cron 없음" → **"hook produces / cron decides"**, 경량 cron 신설.
- `tech-design.md §5` 발송 경로 — `SendAnalysisNotification`(분석완료 전용 하드코딩) 외에 **회수 알림용 새 빌더**(텍스트 템플릿 + collapse_id) 필요(이미 §5에 메모).
- committed `docs/PROPOSAL_PROACTIVE_RECALL.md §5/§7`("푸시는 일정·마감만" / "무분별한 푸시 안 함") → **재프레이밍**: 미션상 푸시가 오히려 정합하며, "무분별"이 아니라 "누르고 싶은 질"로 통제한다는 서술로.
