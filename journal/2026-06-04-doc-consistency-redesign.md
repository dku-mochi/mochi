---
level: 3
mode: log
status: draft
last_verified: 2026-06-04
confidence: 0.6
owners: [송준서]
title: 문서 정합성 재설계 제안 — 의존 graph.json + 문서 수명 규칙
description: 문서 정합성 시스템 재설계 제안(L3 ephemeral). 충돌 응답 프로토콜·소유 경계·의존 graph.json+validator·memory 라우팅·문서 수명 규칙을 바꾸기 전 읽어라. 미승인 — 결정 승인 시 canonical(WORKFLOW/CLAUDE/DOMAIN)로 harvest 후 이 파일 삭제 가능. lab/doc-graph 프로토타입 검증 통과(2026-06-04).
---

# 문서 정합성 재설계 제안 (v3 · L3 ephemeral)

> **위치 정정:** 이 문서는 redesign 제안이라 `docs/`(canonical)가 아니라 `journal/`(L3)에 있어야 한다. v1·v2 는 `docs/DOC_CONSISTENCY_REDESIGN.md`에 있었으나 그 자체가 §4 규칙 위반이었다 — 옮기고 docs/ 원본은 삭제했다.
> **수명:** 미승인 제안. **결정이 승인되면 canonical(WORKFLOW/CLAUDE/DOMAIN)로 harvest 한 뒤 이 파일은 삭제 가능.** 그 전까지 staging.
> **톤:** 박수 없음. 결함·한계·트레이드오프 위주.

---

## 0. TL;DR

코드 요청 시 문서와 다른 스키마가 들어가고(P1), 문서 수정 요청에 막다른 거부를 하며(P2), 변경 견적을 과대평가하고(P3), 같은 L2 문서간 의존(P4)·내용 결합(P5)이 규칙 밖이며, 공유 결정이 AI 로컬 memory에만 남는다(P6).

**채택(지금):** 충돌-제안 프로토콜(P2·P3) · 참조-비복제 소유 경계(P5) · **의존 `graph.json` + validator**(P4·P1 보조) · memory→repo 라우팅(P6) · **문서 수명 규칙**(쓰레기장 방지).

**핵심 결정 — 메커니즘은 의존 graph.json:** frontmatter 엣지(v1)·산문표(v2)를 버리고 **중앙 의존 JSON + validator**로 간다. JSON이 둘보다 나은 *유일한* 근거는 **기계 검증 가능**이고, 그 validator가 lab에 실재하며 검증을 통과했다(§2). validator 없는 graph.json은 만들 가치 없다.

**한계(정직):** validator는 *구조적* 드리프트(죽은 path·dangling·self-loop)만 잡는다. *의미적* 드리프트(refactor 후 엣지가 더는 사실 아님)는 못 잡아 — doc-guardian(AI) 주기 패스가 보완. 코퍼스가 작아서(§4) 그 패스가 싸다.

---

## 1. 문제 카탈로그

| # | 증상 | 근본 원인 | 채택 |
|---|---|---|---|
| P1 | 코드 요청 시 문서와 다른 스키마 | 문서 grounding이 ③(읽기 선택), 직접 요청 시 doc-guardian 건너뜀 | §3.3 표/JSON + 워크플로 (부분) |
| P2 | 문서 수정 요청 → 막다른 거부 | 문서를 *수정 불가 법*으로 취급 | §3.1 |
| P3 | 변경 과대 견적 | 견적을 사람 팀 캘린더 cadence에 앵커링 | §3.1 |
| P4 | 같은 L2 ARCH↔DOMAIN 동기화 누락 | level이 수직만, 수평 의존성 규칙 없음 | §3.3 graph.json |
| P5 | 기획·아키텍처에 스키마 노출(강한 결합) | 같은 사실 복제, 소유 경계 부재 | §3.2 |
| P6 | 공유 결정이 AI 로컬 memory에만 | memory 공유 불가인데 project 지식이 거기 | §3.4 |

---

## 2. 메커니즘 — 의존 graph.json + validator (lab 프로토타입 검증됨)

`graph.json` = [JSON Graph Format](https://jsongraphformat.info/) 계열(nodes+edges). **권위가 아니라 docs/code 위의 검증가능한 지도.** 단일 권위 방향: docs/code=영토(진실), JSON=지도(재생성 가능, 권위 아님). → 진실의 다중화가 아님.

**왜 frontmatter(v1)·산문표(v2)보다 나은가 — 한 가지뿐:**
- co-locate 구멍 없음: 중앙 JSON은 문서·코드(`openapi.json`, `alembic/`)를 균일 참조. (frontmatter는 코드에 못 붙음.)
- 양방향 staleness 없음: 엣지를 한 곳에 1회 기재, 역방향은 *질의*지 복제 아님.
- **기계 검증 가능:** validator가 구조적 드리프트를 잡는다. ← JSON의 유일한 실질 우위.

**프로토타입 (`lab/doc-graph/`):**
- `graph.json` — canonical 문서 4 + 코드표면 6, 엣지 11. 실제 repo 경로.
- `validate_graph.py` — node path 실존·dangling edge·self-loop = ERROR(exit 1); orphan·cycle·중복 = WARN(exit 0). stdlib only.
- `graph.broken.json` — 음성 테스트 fixture.

**검증 결과(2026-06-04):**
```
(1) graph.json     → VERDICT: PASS (2 warnings)  exit 0
    WARN: orphan DesignSystem(⓪ 단일원천, 의도적) / cycle ARCHITECTURE<->DOMAIN_DESIGN(P4 양방향, 의도적)
(2) graph.broken   → VERDICT: FAIL (3 errors)    exit 1
    죽은 path / dangling edge / self-loop 전부 검출
```
→ JSON의 존재 근거(검증)가 실제로 작동함을 확인. cycle을 *에러가 아닌 정보*로 다루는 게 핵심 — P4의 ARCH↔DOMAIN 양방향 결합은 정당하기 때문.

**한계:** §0 참고 — 의미적 드리프트는 못 잡음.

---

## 3. 지금 채택 (산문 2 + JSON 1 + 수동 1)

> codex 교정(§7): 그래프도 hook도 P1을 *해결*하지 못한다 — AI가 참조한 뒤에야 돕는다. P1의 진짜 고리는 워크플로 준수(doc-guardian 먼저). graph.json은 그 참조를 *검증가능*하게 만들 뿐.

### 3.1 충돌 "제안" 프로토콜 → P2·P3 (CLAUDE.md §1 한 단락, 승인 후)
요청이 committed 문서와 충돌하면 — **거부하지 말고 제안:** (1) 어느 문서 어느 부분 충돌, (2) 해결안 A=문서 수정 시 graph.json 따라 영향 항목, (3) 해결안 B=요청 조정, (4) 결정 요청. 견적은 **"AI 편집 시간"과 "사람 합의·검토 리드타임"을 분리** — 자기 처리량 과소평가 금지.

### 3.2 참조-비복제 소유 경계 → P5 (산문 규칙)
| 문서 | 단일 소유 | 금지 |
|---|---|---|
| PRODUCT(L1) | 사용자 문제·미션·컨셉 | 스키마·테이블·API 필드 |
| DOMAIN_DESIGN(L2) | 엔티티·스키마·상태머신·DDL | — (스키마 정본) |
| ARCHITECTURE(L2) | 토폴로지·데이터흐름·계약 | DB 컬럼 나열 → "DOMAIN §N대로" 참조 |
| PRIVACY(L2) | 민감캡처 감지·마스킹 | 스키마 컬럼 정의 |

> **실측 보정(2026-06-04):** P5 결합은 가정보다 약하다. grep 결과 `PRODUCT.md` 1토큰(깨끗), `ARCHITECTURE.md` 24× `mochi_items`는 *엔티티 이름 참조*(허용)지 *컬럼/DDL 복제*(위반)가 아님. → 이 규칙은 *예방용*으로만 둔다. 대대적 리팩토링 불필요.

### 3.3 의존 graph.json + validator → P4·P1 보조 — **보류 (HELD, §9)**
§2 프로토타입은 작성·검증됐으나 **채택하지 않는다.** 실측 결과 (a) WORKFLOW §3 공유표면 목록과 이중 원천이고(graph가 §3의 부분집합 — 라우팅 누락), (b) 살아있는 P1(intent 5컬럼↔flat 타겟)에서 graph 기여 0 — DOMAIN 산문이 이미 invariant를 관리한다. 선결조건·근거는 §9.

### 3.4 memory → repo 수동 정리 → P6
라우팅 규칙(CLAUDE.md 한 줄): "project 지식(결정·도메인 사실·상태)은 docs/journal, memory엔 user/feedback만." 수동 이동: `schema-bigbang-redesign-decision`→DOMAIN 근거절, `gemini-model-cost-preference`→backend README, `ios-merge-from-dev`→journal. 자동화 안 함.

---

## 4. 문서 수명 규칙 (신규 — 쓰레기장 방지)

근거: 문서가 많아지면 쓰레기장이 된다. canonical 코퍼스는 작고 안정해야 — 그래야 graph.json도 작고 검증이 싸다(§2). 두 부류를 구분한다:

| 부류 | 예 | 위치 | 수명 |
|---|---|---|---|
| **canonical** | PRODUCT·DOMAIN·ARCHITECTURE·PRIVACY·WORKFLOW | `docs/` | 영속. 갱신은 하되 삭제 안 함 |
| **process 기록** | daily 로그·handoff | `journal/` | 보존 (과정·상태 = 비가역 history, /sprint-end가 archive) |
| **decision scaffolding** | redesign·refactor·이 문서 | `journal/` | **결정 harvest 후 삭제 가능** |

**핵심 구분:** daily/handoff는 *무슨 일이 있었나*(history)라 지우면 손실 → 보존. redesign/refactor 제안은 *결정을 위한 발판*이라, 결정이 canonical로 graduate하면 중복 → 삭제 가능. **단 "삭제"는 "harvest 후"다** — 먼저 결정·근거를 canonical(WORKFLOW/CLAUDE/DOMAIN/CHANGELOG)에 옮기고, 그 다음 발판을 치운다. 안 그러면 "왜"가 사라진다.

**graph.json 노드 규칙:** canonical + 코드표면만. ephemeral(이 문서·INTENT_REDESIGN)은 노드 아님 → 코퍼스 작게 유지. (참고: `INTENT_REDESIGN.md`도 flat-intents 구축·harvest 후 같은 운명. 지금 건드리지 않음.)

---

## 5. 이 세션 실행 상태

**완료:**
- 이 문서 `docs/` → `journal/` 이동, `docs/DOC_CONSISTENCY_REDESIGN.md` 삭제.
- `lab/doc-graph/` 프로토타입 작성: `graph.json`(실 경로 10노드/11엣지) + `validate_graph.py` + `graph.broken.json`.
- validator 검증: 실 그래프 PASS / 깨진 fixture FAIL — 양방향 확인(§2).
- **실측 검토(2026-06-04):** coupling grep(P5 약함 확인) · intent drift 확인 · 노드 churn · WORKFLOW §3 중복 확인 → §3.2 *예방용*으로 강등, §3.3 graph **보류**(§9).
- **L1 반영안 §8 작성**(충돌-제안 · 소유경계 · 수명 · memory 라우팅, ready-to-apply) + memory 라우팅 규칙 즉시 기록([[project-knowledge-to-repo-not-memory]]).

**적용됨 (추가, 2026-06-04 owner 승인):**
- §8 블록 A·B → `CLAUDE.md §1` + `docs/WORKFLOW.md §2.1~2.3` 반영. `AGENTS.md` 미러 동기화.

**남음 (대기):**
- memory 이관(§8 블록 C) — 승인 후 harvest (목적지 일부가 canonical).
- §3.3 graph.json: **보류(§9).** 선결조건 3개 충족 전 repo 승격 금지.

---

## 6. 미해결 (사람 선택)

1. **graph.json 채택 여부 (§9 HELD):** 선결조건 (a)§3 이중원천 해소 (b)validator 배선 (c)테스트 우선 비교 — 충족시켜 채택할지, 폐기할지.
2. **결정의 repo 집:** 관련 L2 근거절 접어넣기 vs 신규 `docs/DECISIONS.md`. (권장: 접어넣기)
3. **borderline reminder hook:** 공유표면 편집 시 정본 한 줄 띄우는 ③ 넛지 — 지금 만들지. (P1 통증 강도에 따라)
4. **이 제안의 결정을 언제 canonical로 harvest하고 이 파일을 삭제할지.**

---

## 7. 진화 기록 (냉정)

- **v1**(`docs/`, frontmatter 의존 그래프 + edit-hook 중심) — **과설계.** 코드 노드는 frontmatter가 없어 co-locate 불가(논리 구멍), 양방향 엣지 staleness. codex가 8개 지적(아래).
- **v2**(산문표로 축소, 그래프·hook 제출 후로) — **과교정.** "D-41이니 하네스 만지지 마라"는 P3(자기 과소평가)를 프로젝트 스케일에 적용한 것. 코드가 싸면 가치는 *의사결정 일관성*으로 이동하고, 하네스가 그 기반이다. → "지을지"는 투자가 맞고, "무엇을"만 설계 건전성으로 고른다.
- **v3**(이 문서) — 의존 **graph.json + validator**로 정착. frontmatter·산문표보다 나은 유일 근거=검증가능성, 그 검증기를 실제로 만들어 통과시킴. + 문서 수명 규칙으로 코퍼스를 작게 유지해 graph 유지 비용을 낮춤.

**codex 리뷰(2026-06-04) 반영:** co-locate 불가·양방향 staleness → 중앙 JSON으로 해소. hook "②승격"은 ③ 넛지로 정정. cascade "동기화 필수/승인" 차단 문구 → 알림으로 강등. "문서=원천/무단 코드" 강주장 → 공동 권위+문서가 동점 결정자로 톤다운. *단* codex의 "그래프 만들지 마라"는 *AI가 bookkeeping을 한다*는 전제(Karpathy LLM Wiki)에선 약화 — JSON+validator는 AI 유지가 싸다. 그래서 v3는 codex보다 한 칸 더 지으려 했다 — **단 적용 전 실측 검토(§8·§9)에서 graph.json은 "보류"로 정정**됐다. 확실한 이점은 행동·수명 규칙에 있고, graph는 선결조건 충족 전까지 lab 보존.

---

## 8. L1 반영 — 블록 A·B **적용 완료** (2026-06-04, owner 승인)

> **블록 A·B 는 2026-06-04 반영됨** — `CLAUDE.md §1`(충돌-제안·견적 분리), `docs/WORKFLOW.md §2.1~2.3`(소유경계·수명·memory 라우팅). owner(송준서) 명시 승인 · `AGENTS.md` 미러 `/sync-agents` 재생성. 다른 두 owner 동의는 사후 확인. **블록 C(memory 이관)는 목적지 일부가 canonical이라 대기.** 아래는 harvest 기록 — A·B는 이 doc 정리 시 함께 삭제.

### 블록 A → `CLAUDE.md` §1 (Think Before Coding) 미션 문단 뒤에 추가

```markdown
**문서와 충돌하면 거부하지 말고 제안한다.** 요청이 committed 문서와 어긋날 때: (1) 어느 문서 어느 부분과 충돌하는지 짚고, (2) 문서를 고치는 길(+폭포 영향)과 (3) 요청을 조정하는 길을 함께 제시한 뒤, (4) 사람의 결정을 받아 의존 항목을 함께 수정한다. 문서는 법이 아니라 함께 고치는 산출물이다. 단 *substantive* 한 충돌에만 — 사소한 것까지 매번 묻지 않는다.

**변경 견적은 "AI 편집 시간"과 "사람 합의·검토 리드타임"을 분리해 말한다.** "편집 자체는 10분, 다만 공유표면이라 팀 합의가 선행" 처럼. 자기 처리량을 과소평가하지 않는다.
```

### 블록 B → `docs/WORKFLOW.md` §2 에 §2.1~2.3 추가 (적용됨 — 아래는 적용 텍스트)

```markdown
### 2.4 참조하되 복제하지 마라 (정보 소유 경계)
각 사실은 정확히 한 문서가 소유한다. 다른 문서는 이름으로 *참조*할 뿐 내용을 *복제*하지 않는다.
- PRODUCT(L1): 사용자 문제·미션·컨셉 — 스키마/필드 금지
- DOMAIN_DESIGN(L2): 엔티티·스키마·상태머신·DDL (스키마 정본)
- ARCHITECTURE(L2): 토폴로지·데이터흐름·계약 — DB 컬럼 나열 대신 "DOMAIN §N대로" 참조
- PRIVACY(L2): 민감캡처 정책 — 스키마 컬럼 금지
엔티티 *이름* 참조는 허용. *컬럼/DDL 복제*만 위반. (실측상 현재 위반은 경미 — 예방 규칙.)

### 2.5 문서 수명 — canonical vs ephemeral
- canonical(`docs/` 안정 문서): 영속. 갱신하되 삭제 안 함.
- process 기록(`journal/` daily·handoff): 보존(무슨 일이 있었나=history). `/sprint-end`가 archive.
- decision scaffolding(`journal/` redesign·refactor 제안): **결정을 canonical(WORKFLOW/CLAUDE/DOMAIN/CHANGELOG)로 harvest 한 뒤 삭제.** "삭제"는 항상 "harvest 후".
- redesign/refactor 제안은 `docs/`(canonical)에 두지 않고 `journal/`(L3)에 둔다.

### 2.6 project 지식은 repo, AI memory엔 개인 작업방식만
공유돼야 할 것(결정·도메인 사실·상태)은 docs/journal에 쓴다. AI 로컬 memory는 머신 로컬이라 팀에 안 보이므로 user/feedback("이 사람과 어떻게 일하나")만 둔다.
```

### 블록 C → memory 이관 체크리스트 (승인 후 harvest)

| memory | 목적지 | 비고 |
|---|---|---|
| `schema-bigbang-redesign-decision` | 이미 CHANGELOG 2026-06-03 + DOMAIN §4.4 | repo에 존재 → harvest 시 memory 제거 |
| `gemini-model-cost-preference` | `mochi-backend/README.md` (모델 선택 근거) | 신규 반영 |
| `ios-merge-from-dev` | `journal/` (작업 상태) | |
| `quality-over-change-avoidance` · `user-prefers-explore-before-choosing` · `code-review-not-forced` | memory 유지 | 개인 작업방식 |
| 라우팅 규칙 자체 | 블록 B §2.6 + [[project-knowledge-to-repo-not-memory]] | 이미 기록됨 |

---

## 9. graph.json — 보류 (HELD)

실측 검토 결과 선결조건 3개 미충족이라 **채택하지 않는다**:
- **(a) WORKFLOW §3과 이중 원천.** graph.json 노드 = §3 공유표면의 *부분집합*(라우팅 `app/api.py`·`RootFeature`, `CoreNetworking` 누락). 같은 사실 두 곳 → drift 위험. §3 단일원천화 *또는* graph가 §3 대체+누락 채움이 선결.
- **(b) validator 미배선.** `/ship` precheck나 CI에 안 걸면 아무도 안 돌려 죽은 파일.
- **(c) P1은 graph(③ reminder)보다 테스트(② 확장)가 더 확실.** 살아있는 P1(intent 5컬럼↔flat)에서 graph 기여 0 — `openapi-check.sh`·`test_module_boundaries.py` 류 확장이 더 확실. 비교 선행.

프로토타입은 `lab/doc-graph/`에 보존(README HELD 명시). **결정 전 repo 승격 금지.**
