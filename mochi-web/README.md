---
level: 2
mode: doc
status: active
last_verified: 2026-07-15
confidence: 1.0
owners: [송준서]
description: mochi-web(심사위원용 여정 데모 + BFF)의 빌드·아키텍처·env·시딩 정본. 웹 데모를 만지기 전 여기부터.
---

# mochi-web — 심사위원용 여정 데모 (Next.js 16 + BFF)

무설치 5분 여정으로 모찌의 미션("놓치기 쉬운 순간은 쉽게 남기고, 필요한 기억은 쉽게 떠오른다")을 체험시키는 데모 웹.
심사위원이 페르소나(sena/dohyun/yuna)를 골라 그 사람의 일주일치 기록으로 **기록 → 홈 → 검색 → 질문 → 리마인드(하이라이트) → 마무리**를 밟는다.

| 씬 | 라우트 | 비고 |
| --- | --- | --- |
| S0 랜딩 | `/` | R3F 기억 파편 필드 + 웹 체험 CTA + 데스크톱 TestFlight QR·설치 링크 |
| S1 페르소나 선택 | `/p` | 세 사람을 같은 우선순위로 선택 |
| S2 기록 | `/p/[persona]/capture` | 직접 보내기 + 페르소나·종류별 고유 예시 15건 반응형 그리드(장소 5건 이상, 1.015 hover)·직접 드롭 + 꽂히는 보드 4칸 |
| S3 홈 | `/p/[persona]` | 방금 보낸 기록 우선 확인 + 내 세션 오버레이 합성 |
| S4 검색 | `/p/[persona]/search` | 최근 기록의 넓은 의미 단서 추천 + 자유 검색, 라이브/canned 타일 랭킹 |
| S5 질문 | `/p/[persona]/chat` | 최근 기록의 자연어 회수 질문 + 자유 질문, citation·실행형 proposal |
| S6 리마인드 | `/p/[persona]/recall` | 시드 + 현재 페르소나의 세션 입력만 합성하는 R3F 코버플로우 |
| S7 마무리 | `/finale` | 체험 요약·TestFlight QR·재선택 + 7/20 00:00 KST부터 GitHub QR |

guided 여정은 페르소나 카드의 `?guided=1&new=1` 로 시작한다. `new=1`은 이전 방문자의 세션 입력·대화·통계를 초기화하고, `JourneyRail`은 실제 행동 완료 뒤에만 다음 단계를 연다. 단계별 명시적 건너뛰기, 상단 자유 탐색, 완료 뒤 → 키 이동을 지원한다.

예시 레일의 캡처·링크 썸네일은 `public/seed/examples`에 둔 **정적 데모 자산**이다. iOS 앱이 이미지를 생성해 주는 API는 없다. 예시를 입력 폼에 놓고 전송한 뒤부터는 웹 BFF가 iOS와 같은 `mochi-backend/openapi.json` 계약을 사용하며, 이미지 경로는 `presign → GCS PUT → imageRefs ingest`를 실행한다. 응답 헤더가 `x-mochi-mode: live`면 실제 백엔드 분석, `fallback`이면 같은 wire의 웹 폴백이다.

라이브 상세는 백엔드의 `referenceLinks`를 그대로 우선한다. 쇼핑 이미지에서 `shoppingProductQuery`는 추출됐지만 동일 상품으로 검증된 `role=buy` 링크가 없을 때만, 그 검색어가 입력된 네이버 상품 검색 행을 `지금 할 수 있어요`에 보조로 만든다. 특정 예시 상품 URL을 하드코딩하지 않으며 정확한 구매 링크가 생기면 검색 행은 중복 노출하지 않는다.

장소 상세는 iOS와 같은 `place` 좌표를 네이버 Dynamic Map으로 그린다. `provider=naver_map` 관련 링크는 네이버 지도 이름·민트 액센트·도메인 파비콘으로 표시하며 쇼핑 아이콘으로 추론하지 않는다. 웹 Client ID가 없거나 SDK 인증이 실패하면 가짜 지도 타일을 만들지 않고 네이버 지도 링크만 남긴다.

스크린샷 탭의 사용자 제공 캡처는 화면 내용을 카드 제목과 장소 폴백에 함께 반영한다. 세나는 단국대 교육·용인 맛집·EDC 일정, 도현은 판교 회식·개발 강의·PyCon·러닝, 유나는 성수 베이커리·카페·클래스, 연남동 피자·제주 숙소와 알로 요가 아이코닉 쇼퍼 토트백처럼 각 이미지에서 확인되는 실제 이름과 위치를 사용한다.

최근 기록의 검색·질문 추천은 `src/lib/retrievalSuggestions.ts` 한 곳에서 분석 결과의 제목·요약·카테고리·Intent·장소를 읽어 만든다. 예시 id별 문구를 저장하지 않는다. 검색은 정확 제목보다 넓은 의미 단서를, 질문은 그 단서로 일정·장소·마감·핵심을 되묻는 자연스러운 문장을 만든다. 추천을 누른 뒤 검색 실행은 실제 백엔드 `/search`를 그대로 사용한다.

TestFlight 공유 링크는 `src/lib/productLinks.ts`가 단일 소유하고 `public/qr-testflight.svg`는 그 링크를 인코딩한 정적 QR이다. 랜딩에서는 웹 체험을 방해하지 않는 보조 크기로, 마무리에서는 실제 앱 설치를 다음 행동으로 제시하는 주 CTA로 사용한다.

## 실행·검증

```bash
npm run dev             # 개발 서버 (기본 3000)
npm run typecheck && npm run lint && npm test   # 타입·린트·vitest
npm run build           # prebuild 에서 validate:seed 자동 실행
npx tsx scripts/capture-mocks/shoot.ts [필터]   # 목업 캡처 재촬영
node scripts/generate-example-captures.mjs      # 기록 예시 캡처·링크 썸네일 재생성
```

Next.js 16 주의: 이 레포의 Next 는 학습 데이터와 다를 수 있다 — 코드 작성 전 `node_modules/next/dist/docs/` 해당 가이드를 읽는다(`AGENTS.md` 규약). `middleware` 는 `proxy.ts`, 동적 params 는 `await params`.

## fallback-first BFF (핵심 규약)

**화면에 보이는 모든 피드는 웹 내장 시드 + 내 세션 오버레이다.** 네트워크는 딱 3개(채팅·검색·라이브 분석)이고,
셋 다 라이브와 **완전히 같은 wire 포맷의 폴백**이 뒤에 선다 — 심사 당일 백엔드·네트워크가 어떤 상태여도 여정은 완결된다.
클라이언트는 라이브/폴백을 구분하지 않는다(`x-mochi-mode: live|fallback` 응답 헤더가 유일한 흔적).

- **세션 오버레이**(`src/lib/liveOverlay.ts`): S2 에서 직접 보낸 라이브 분석 결과는 sessionStorage 에
  쌓여 이 브라우저의 홈(모자이크·할일·캘린더·주간 카운트)·검색·상세(`live-` slug)에 시드처럼 합성된다.
  페르소나 백엔드 계정은 모든 방문자가 공유하므로 **남의 기록은 절대 화면에 얹지 않는다** — 화면에
  얹는 라이브 데이터는 "내가 이 세션에 보낸 것"뿐이다. 스크린샷은 업로드와 별개로 로컬 썸네일
  (data URL)을 저장해 타일에 실이미지를 그린다.
- **여정 원장**(`src/lib/journeySession.ts`): 기록·홈·검색·질문·리마인드의 완료/건너뜀과 대표 기록을
  현재 탭에 기록한다. 피날레는 이 원장만으로 문구를 만들며, 새 체험은 이전 원장과 오버레이를 함께 비운다.

```
클라 훅(useChatStream·useSearch·useLiveAnalysis)
  → /api/bff/*  ── 라이브 가능? ──> 백엔드 프록시 (페르소나 JWT 직서명)
                └─ 불가/실패/초과 ─> 폴백 엔진 (seed/canned — 같은 wire 재생)
```

- **채팅** `POST /api/bff/chat/[conversationId]` (POST-as-SSE): upstream `POST /conversations/{cid}/messages` 패스스루.
  개시(first-byte) 8초 실패 → 폴백 대본으로 응답(헤더도 fallback). 개시 후 inter-event 15초 스톨·오류 →
  **스트림을 끊지 않고 서버가 폴백 이벤트를 이어붙여 완결**(본문이 이미 나갔으면 `done` 만 이어붙임).
  409(동시 run) → 새 conversationId 로 1회 재시도. conversationId 는 uuid allowlist(경로 주입 차단).
  최근 기록에서 만든 추천 질문은 live context를 함께 보내며, 라이브 답변이 그 기록 citation을 빠뜨린 경우에만 BFF가
  근거 카드를 보강한다. 자유 질문과 기존 페르소나 추천에는 이 보강을 적용하지 않는다.
- **proposal 실행** `POST /api/bff/chat/[conversationId]/proposals/[proposalId]`: 대화 스냅샷에서 proposal ID와
  서버 저장 payload를 재검증한 뒤, 일정·메모 생성은 iOS와 같은 `POST /mochi_items`를 실행하고 성공 뒤 status를 영속한다.
  공유 페르소나의 기존 기록을 바꾸는 수정·삭제와 브라우저가 예약할 수 없는 기기 알림은 preview로 응답한다.
  폴백 일정·메모는 세션 오버레이 항목을 반환한다.
- **검색** `POST /api/bff/search`: upstream `POST /search`(12s 타임아웃) 실패 시 canned 폴백.
  citations 의 `mochiItemId`(uuid)는 클라가 `seed/backend-ids.json` 으로 시드 slug 에 매핑해 타일로 렌더
  (내 세션 오버레이의 라이브 uuid 도 slug 로 되살린다 — 매핑에 없는 id, 즉 남의 기록은 버린다).
  문장 답변은 S5 채팅의 몫 — `/search` 계약에 `answer` 필드가 없다(2026-07-14 제거, iOS 도 citations 만 쓴다).
  클라는 문구 일치(literal)를 앞세우고 citations 로 보강한다. 최근 기록에서 만든 넓은 추천 검색은 live context를
  폴백에만 전달해, 라이브 하이브리드 검색이 불가할 때도 현재 방문자의 같은 세션 기록으로 정직하게 강등한다.
- **라이브 분석** `POST /api/bff/ingest` → `GET /api/bff/ingest/{id}/stream?p={persona}` → `GET /api/bff/items/{id}?p={persona}`:
  실 ingest(Idempotency-Key 는 입력 내용 해시 — 재전송 중복 방지) → 진행 SSE 프록시(스톨 시 `final` 이어붙임) →
  본문 재조회(분석 완료 전이면 짧게 폴링). 폴백 id 는 `fb.` prefix 에 입력을 인코딩 — 서버 무상태.
- **이미지 캡처** `POST /api/bff/ingest/image` (multipart `image`+`persona`+`memo?`): 서버가 백엔드
  `presign → GCS PUT → imageRefs ingest` 3단을 대행(버킷 CORS 불필요, Idempotency-Key 는 이미지 sha 기반).
  클라는 업로드 전 긴 변 2000px JPEG 로 다운스케일(`src/lib/captureImage.ts` — UI 는 webp 도 받아 JPEG 재인코딩).
  서버 수용은 JPEG/PNG 만, 8MB 상한.
  이후 진행 SSE·본문 재조회는 위 라이브 분석과 같은 경로. 라이브 불가 시 메모 텍스트 폴백으로 강등.
- **rate limit**(`lib/bff/ratelimit.ts`): 인메모리 토큰버킷(chat 6/분·search 10/분·ingest 4/분, `MOCHI_INGEST_PER_MINUTE` 오버라이드).
  초과는 429 가 아니라 **폴백 강등**.
- **킬스위치**: `MOCHI_FORCE_FALLBACK=1` — 전 라우트가 라이브를 건너뛴다.

wire 계약 정본은 `mochi-backend/openapi.json`(⓪-tier). 수기 미러는 `src/lib/api/wire.ts`,
본문 citation 마커(`【item:uuid】`, 반각·8자리 축약 허용)는 iOS `ChatMarkup` 과 동일 정책(`src/components/chat/ChatMarkup.tsx`). 축약 마커는 현재 턴의 owner-scoped 기록 조회 결과와 유일하게 일치할 때만 백엔드가 전체 UUID로 복구하며, 웹·iOS는 citation 이벤트와 유일하게 맞는 마커만 뱃지로 렌더한다.

## env 계약 (`.env.local`)

| 키 | 용도 |
| --- | --- |
| `MOCHI_BACKEND_URL` | 백엔드 오리진(`/api/v1` 유무 무관 — 자동 정규화) |
| `MOCHI_JWT_SECRET` | 백엔드 `AUTH_ACCESS_SECRET` 와 동일값 — HS256 직서명 |
| `MOCHI_PERSONA_UUID_SENA/_DOHYUN/_YUNA` | 페르소나 실계정 user UUID |
| ~~`MOCHI_DEMO_USER_ID`~~ | **폐지 (2026-07-10)** — 공용 폴백 계정이 페르소나 검색·채팅을 남의 기록으로 답하게 만들어 제거. UUID 미설정이면 해당 페르소나는 라이브 대신 canned 폴백 |
| `MOCHI_FORCE_FALLBACK` | `1` 이면 라이브 전면 차단 |
| `MOCHI_INGEST_PER_MINUTE` | ingest 버킷 용량 (기본 4) |
| `NEXT_PUBLIC_NAVER_MAP_CLIENT_ID` | 네이버 Dynamic Map 공개 Client ID. 브라우저 SDK에 노출되며 NCP Web 서비스 URL 제한으로 보호 |

미설정이면 해당 경로만 자동 폴백 — **env 없이도 데모는 완주 가능**(오프라인 완결).

## 백엔드 시딩 (P7 — 페르소나 계정에 실데이터)

```bash
# 0) (사람) prod DB 에 user row 3건 삽입 → UUID 를 위 env 에 등록
npm run seed:backend              # confirmedInstances 결정론 시딩 + 건수·검색 스모크
npm run seed:backend -- --smoke   # 채팅 1턴 스모크까지
npm run seed:cleanup              # 방문자 라이브 기록 정리 (dry-run 기본, --apply 로 삭제)
# 1) 산출된 seed/backend-ids.json(uuid↔slug) 커밋
# 2) (사람) mochi-backend scripts/backfill_embeddings.py 실행 — 검색 인덱싱
```

- Idempotency-Key `{persona}:{slug}:{내용해시8}` — 재실행 멱등 + 시드 내용이 바뀌면 새 아이템(무음 stale 방지).
  내용 변경 재시딩 시 구 아이템은 백엔드에 남으니 수동 정리. 매핑 파일은 전량 성공 시에만 기록된다.
- `MochiItemCreateRequest` 에 `capturedAt` 이 없다 → **시간축(며칠 전·D-day)은 웹 시드 단독 소유**.
  시드는 전부 상대값(`capturedDaysAgo`/`dateInDays`/`deadlineInDays`)이고 절대화는 렌더/시딩 시점에만.

## 시드·디자인 규칙 (요약)

- 시드 계약: `seed/schema.ts`(zod) — 렌더와 시더 겸용. `npm run validate:seed` 가 빌드 게이트.
- 날짜 계산은 무조건 `kstParts()`/`midnight()`(`src/lib/seedRuntime.ts`) — 로컬 타임존 API 직접 호출 금지.
- 색은 `src/app/globals.css @theme` 브랜드 토큰만(iOS `HomeDesign.swift` 1:1). 새 색 금지.
- 피드 카드는 `tiles/ItemTile`, intent 칩은 `INTENT_META`, 회수 이유는 `REASON_META`, 등장 모션은 `RiseIn`.
- 4-Intent 메타 비노출 — "분류했어요" 카피 금지, 분류는 행동(할일·캘린더·지식·기록에 꽂힘)으로만.
- 사용자 노출 카피에 em dash(—)·원문자(①) 금지 — 마침표·쉼표·가운뎃점·하이픈만 (AI 티 나는 기호 배제).
- `public/brand/mochi-hello.png` 는 어디에도 쓰지 않는다(어울리는 자리가 없다 — 2026-07-10 결정). 마스코트는 절제: 저장 모먼트(cheer)·빈 상태(question)·네비 로고(mochi2)만.
- R3F: 텍스트를 WebGL 에 넣지 않는다. `Environment` preset 금지(CDN 페치 — 오프라인 데모 깨짐), 조명은 라이트 3개.
  reduce-motion·no-WebGL 은 전 씬 정적 폴백(기능 손실 0).
