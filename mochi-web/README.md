---
level: 2
mode: doc
status: active
last_verified: 2026-07-08
confidence: 1.0
owners: [송준서]
description: mochi-web(심사위원용 여정 데모 + BFF)의 빌드·아키텍처·env·시딩 정본. 웹 데모를 만지기 전 여기부터.
---

# mochi-web — 심사위원용 여정 데모 (Next.js 16 + BFF)

무설치 5분 여정으로 모찌의 미션("놓치기 쉬운 순간은 쉽게 남기고, 필요한 기억은 쉽게 떠오른다")을 체험시키는 데모 웹.
심사위원이 페르소나(sena/dohyun/yuna)를 골라 그 사람의 일주일치 기록으로 **기록 → 홈 → 검색 → 질문 → 떠오름(클라이맥스) → 피날레**를 밟는다.

| 씬 | 라우트 | 비고 |
| --- | --- | --- |
| S0 랜딩 | `/` | R3F 기억 파편 필드 — CTA hover 시 카피 둘레로 수렴 |
| S1 페르소나 선택 | `/p` | 추천 카드 1장에만 border-beam |
| S2 기록 | `/p/[persona]/capture` | 시나리오 3건 + **라이브 AI 분석**(직접 입력) |
| S3 홈 | `/p/[persona]` | 자유 탐색 허브 |
| S4 검색 | `/p/[persona]/search` | 실검색(라이브) + canned 폴백 |
| S5 질문 | `/p/[persona]/chat` | POST-as-SSE, citation·proposal |
| S6 떠오름 | `/p/[persona]/recall` | 풀스크린 R3F 코버플로우 — 데모의 클라이맥스 |
| S7 피날레 | `/finale` | 여정 요약·아키텍처·QR·재선택 |

guided 여정은 `?guided=1` 로 진입(페르소나 카드 CTA)하며 `JourneyRail`(우하단)이 순서를 안내한다. sessionStorage 유지, → 키 지원.

## 실행·검증

```bash
npm run dev             # 개발 서버 (기본 3000)
npm run typecheck && npm run lint && npm test   # 타입·린트·vitest
npm run build           # prebuild 에서 validate:seed 자동 실행
npx tsx scripts/capture-mocks/shoot.ts [필터]   # 목업 캡처 재촬영
```

Next.js 16 주의: 이 레포의 Next 는 학습 데이터와 다를 수 있다 — 코드 작성 전 `node_modules/next/dist/docs/` 해당 가이드를 읽는다(`AGENTS.md` 규약). `middleware` 는 `proxy.ts`, 동적 params 는 `await params`.

## fallback-first BFF (핵심 규약)

**화면에 보이는 모든 피드는 웹 내장 시드다.** 네트워크는 딱 3개(채팅·검색·라이브 분석)이고,
셋 다 라이브와 **완전히 같은 wire 포맷의 폴백**이 뒤에 선다 — 심사 당일 백엔드·네트워크가 어떤 상태여도 여정은 완결된다.
클라이언트는 라이브/폴백을 구분하지 않는다(`x-mochi-mode: live|fallback` 응답 헤더가 유일한 흔적).

```
클라 훅(useChatStream·useSearch·useLiveAnalysis)
  → /api/bff/*  ── 라이브 가능? ──> 백엔드 프록시 (페르소나 JWT 직서명)
                └─ 불가/실패/초과 ─> 폴백 엔진 (seed/canned — 같은 wire 재생)
```

- **채팅** `POST /api/bff/chat/[conversationId]` (POST-as-SSE): upstream `POST /conversations/{cid}/messages` 패스스루.
  개시(first-byte) 8초 실패 → 폴백 대본으로 응답(헤더도 fallback). 개시 후 inter-event 15초 스톨·오류 →
  **스트림을 끊지 않고 서버가 폴백 이벤트를 이어붙여 완결**(본문이 이미 나갔으면 `done` 만 이어붙임).
  409(동시 run) → 새 conversationId 로 1회 재시도. conversationId 는 uuid allowlist(경로 주입 차단).
- **검색** `POST /api/bff/search`: upstream `POST /search`(12s 타임아웃) 실패 시 canned 폴백.
  citations 의 `mochiItemId`(uuid)는 클라가 `seed/backend-ids.json` 으로 시드 slug 에 매핑해 타일로 렌더.
- **라이브 분석** `POST /api/bff/ingest` → `GET /api/bff/ingest/{id}/stream?p={persona}` → `GET /api/bff/items/{id}?p={persona}`:
  실 ingest(Idempotency-Key 는 입력 내용 해시 — 재전송 중복 방지) → 진행 SSE 프록시(스톨 시 `final` 이어붙임) →
  본문 재조회(분석 완료 전이면 짧게 폴링). 폴백 id 는 `fb.` prefix 에 입력을 인코딩 — 서버 무상태.
- **rate limit**(`lib/bff/ratelimit.ts`): 인메모리 토큰버킷(chat 6/분·search 10/분·ingest 4/분, `MOCHI_INGEST_PER_MINUTE` 오버라이드).
  초과는 429 가 아니라 **폴백 강등**.
- **킬스위치**: `MOCHI_FORCE_FALLBACK=1` — 전 라우트가 라이브를 건너뛴다.

wire 계약 정본은 `mochi-backend/openapi.json`(⓪-tier). 수기 미러는 `src/lib/api/wire.ts`,
본문 citation 마커(`【item:uuid】`, 반각 허용)는 iOS `ChatMarkup` 과 동일 정책(`src/components/chat/ChatMarkup.tsx`).

## env 계약 (`.env.local`, 전부 서버 전용 — 클라 비노출)

| 키 | 용도 |
| --- | --- |
| `MOCHI_BACKEND_URL` | 백엔드 오리진(`/api/v1` 유무 무관 — 자동 정규화) |
| `MOCHI_JWT_SECRET` | 백엔드 `AUTH_ACCESS_SECRET` 와 동일값 — HS256 직서명 |
| `MOCHI_PERSONA_UUID_SENA/_DOHYUN/_YUNA` | 페르소나 실계정 user UUID |
| `MOCHI_DEMO_USER_ID` | (dev 편의) 페르소나 UUID 미설정 시 공용 폴백 계정 |
| `MOCHI_FORCE_FALLBACK` | `1` 이면 라이브 전면 차단 |
| `MOCHI_INGEST_PER_MINUTE` | ingest 버킷 용량 (기본 4) |

미설정이면 해당 경로만 자동 폴백 — **env 없이도 데모는 완주 가능**(오프라인 완결).

## 백엔드 시딩 (P7 — 페르소나 계정에 실데이터)

```bash
# 0) (사람) prod DB 에 user row 3건 삽입 → UUID 를 위 env 에 등록
npm run seed:backend              # confirmedInstances 결정론 시딩 + 건수·검색 스모크
npm run seed:backend -- --smoke   # 채팅 1턴 스모크까지
# 1) 산출된 seed/backend-ids.json(uuid↔slug) 커밋
# 2) (사람) mochi-backend scripts/backfill_embeddings.py 실행 — 검색 인덱싱
```

- Idempotency-Key `{persona}:{slug}:v1` — 재실행 안전(중복 생성 없음).
- `MochiItemCreateRequest` 에 `capturedAt` 이 없다 → **시간축(며칠 전·D-day)은 웹 시드 단독 소유**.
  시드는 전부 상대값(`capturedDaysAgo`/`dateInDays`/`deadlineInDays`)이고 절대화는 렌더/시딩 시점에만.

## 시드·디자인 규칙 (요약)

- 시드 계약: `seed/schema.ts`(zod) — 렌더와 시더 겸용. `npm run validate:seed` 가 빌드 게이트.
- 날짜 계산은 무조건 `kstParts()`/`midnight()`(`src/lib/seedRuntime.ts`) — 로컬 타임존 API 직접 호출 금지.
- 색은 `src/app/globals.css @theme` 브랜드 토큰만(iOS `HomeDesign.swift` 1:1). 새 색 금지.
- 피드 카드는 `tiles/ItemTile`, intent 칩은 `INTENT_META`, 회수 이유는 `REASON_META`, 등장 모션은 `RiseIn`.
- 4-Intent 메타 비노출 — "분류했어요" 카피 금지, 분류는 행동(체크리스트·캘린더·서재에 꽂힘)으로만.
- R3F: 텍스트를 WebGL 에 넣지 않는다. `Environment` preset 금지(CDN 페치 — 오프라인 데모 깨짐), 조명은 라이트 3개.
  reduce-motion·no-WebGL 은 전 씬 정적 폴백(기능 손실 0).
