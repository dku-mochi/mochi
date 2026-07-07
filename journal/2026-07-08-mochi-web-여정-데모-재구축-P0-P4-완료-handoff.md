# mochi-web 여정 데모 전면 재구축 — Handoff (2026-07-08)

## 0. TL;DR (한 화면)

- **브랜치 `feat/web-journey`** (develop에서 분기, 커밋 3개). 기존 mochi-web 전체 삭제 후 백지 재구축.
- **컨셉**: 심사위원(5~10분)이 페르소나(sena/dohyun/yuna)를 골라 기록→홈→검색→채팅→**떠오름(클라이맥스)** 를 여정으로 체험. 승인된 플랜: `~/.claude/plans/cozy-mapping-tiger.md` — **다음 세션 필독 1순위**.
- **P0~P4 완료** (스캐폴드·시드·홈·상세·R3F 코버플로우·BFF 폴백·채팅·검색·기록 씬). 빌드/린트/타입/테스트(21) 전부 그린, 각 씬 Playwright 육안 검증 완료.
- **남은 것**: P5(라이브 백엔드 프록시+이어붙임), P6(S0 랜딩 R3F·S1 페르소나 선택·JourneyRail·S7 피날레 — **`/p` 와 `/` 가 아직 자리표시자**), P7(백엔드 시딩·Vercel 배포·docs 동기화·CHANGELOG).
- 데모는 현재 **오프라인 완결** 상태(fallback-first 전략 달성): `npm run dev` 후 `/p/sena` 진입하면 전 씬 작동.

## 1. 대화 흐름 — 어떻게 여기까지 왔는가

1. 사용자 요구: "여정 느낌" 데모 웹, 페르소나별 기록·검색·채팅·분류 체험, **최상급 디자인**, mochi-web 삭제 후 재구축, iOS 를 정본으로, 3D/인터랙션/디자인 스킬 설치.
2. 플랜 모드에서 iOS·백엔드·docs 3방향 탐색(핵심 발견 아래 §4) → 사용자 결정 3개 확정: **하이브리드 데이터 / 웹 네이티브 재해석 / 데스크톱 우선+Vercel**.
3. Plan 에이전트를 Opus 로 돌리다 사용자 지시로 **중단 → Fable 재기동**(기존 mochi-web 참조 금지 명시). 이후 "**3D 입체감 격상**" 지시 반영 (iOS 정본은 2D여도 웹은 3D).
4. 스킬 4종 설치 완료(사용자 Reload 완료): `core-3d-animation`·`meta-skills` 번들(threejs/r3f/gsap-scrolltrigger/motion-framer/web3d-integration-patterns/modern-web-design), `design-taste-frontend`, `design-motion-principles`.
5. P0→P4 순차 구현, P3 후 codex 리뷰(§3) 반영.

## 2. 현재 코드 상태

**작동**: `cd mochi-web && npm run dev` → `/p/sena`(홈) `/p/sena/capture` `/search` `/chat` `/recall` `/items/[slug]` 전부 동작. `npm run build` 무경고.

커밋 (develop..feat/web-journey):
- `19eb974` 스캐폴드·시드 60건·홈·상세·R3F 코버플로우 (1/2)
- `83607d6` codex 반영 — KST 고정·접근성
- `bdfa356` P4 — BFF 폴백·채팅·검색·기록 씬

mochi-ios/mochi-backend 에는 **이 세션의 변경 없음** (기존 워킹트리 변경 8파일은 이전 세션 것 — system_prompts.py 등, 건드리지 말 것).

### 디렉터리 지도 (다음 세션이 헤매지 않도록)

```
mochi-web/
  seed/schema.ts            zod 계약 (SeedItem·recall·canned) — 백엔드 시더와 겸용
  seed/personas/{sena,dohyun,yuna}.ts   60건 아이템+회수 13건 (시간축은 전부 상대값!)
  seed/canned/*.ts          폴백 채팅 스크립트 6개·검색 9개
  seed/backend-ids.json     {} 자리표시자 — P7 시더가 uuid↔slug 채움
  scripts/capture-mocks/    목업 캡처 파이프라인 (templates.ts 10종 + manifest 22장 + shoot.ts)
  scripts/validate-seed.ts  prebuild 에 연결됨
  src/lib/seedRuntime.ts    시드→화면 파생 (KST 고정! kstParts/midnight 만 사용)
  src/lib/coverflowMath.ts  iOS RecallHeroView 수식 이식 (vitest 대조표 있음)
  src/lib/api/wire.ts       SSE wire 계약 (백엔드 openapi 정본과 동형)
  src/lib/sse/parse.ts      분절 안전 SSE 파서 (라이브/폴백 공용)
  src/lib/bff/{sse,fallback}.ts   서버측 폴백 엔진 (같은 wire 포맷 재생)
  src/lib/hooks/            useChatStream·useSearch·useLiveAnalysis
  src/app/api/bff/          chat/[cid]·search·ingest·ingest/[id]/stream·items/[id]
  src/components/
    primitives/  RiseIn(스태거 등장)·Pressable(0.97)·RollingNumber·IntentChip(INTENT_META)·
                 ReasonChip(REASON_META+glow색)·ToolStatusPill·TypingDots
    tiles/ItemTile.tsx      3변형 카드(스크린샷 풀블리드/링크 퍼플/메모 버터+인용) — 피드 공용
    journey/  PersonaProvider(usePersona: persona·now·items·todo토글)·SceneNav(상단 탭)
    home/ search/ chat/ capture/ recall/ detail/   씬별 컴포넌트
  src/app/globals.css       @theme 토큰 — HomeDesign.swift 1:1 (기본 팔레트 제거됨,
                            브랜드 색만 존재: purple/ink/sky/butter/mint/blush/peach/lavender)
```

## 3. codex 검증 결과 (P3 시점 리뷰)

`/codex review` 실행 — P1 2건, P2 3건. **전부 처리됨**:
- [P1] 타임존 로컬 의존 → `kstParts()` 로 Asia/Seoul 고정, `TZ=UTC npx vitest run` 으로 검증 ✅
- [P1] SceneNav 404 (capture/search/chat 미구현) → P4에서 라우트 구현으로 해소 ✅ (**단 `/p` 와 로고 링크는 P6 전까지 404** — 잔여)
- [P2] reduce-motion 인터스티셜 스킵 ✅ / 도트 tablist→버튼+aria-current ✅ / 캘린더 셀 aria-label ✅

P4 diff 는 codex 리뷰 **아직 안 받음** — 다음 세션 시작 시 P4 범위로 한 번 받고 시작 권장 (거대 diff 는 타임아웃 나므로 `git diff 83607d6...HEAD -- mochi-web/src` 스코프로).

## 4. 결정 / trade-off (왜 이렇게 됐는가)

1. **fallback-first**: 화면 피드는 전부 웹 내장 시드, 네트워크는 채팅·검색·라이브분석 3개뿐이며 셋 다 **라이브와 동일 wire 포맷의 폴백**이 뒤에 있다. 클라이언트는 모드를 모른다(`x-mochi-mode` 헤더로만 구분). → 심사 당일 리스크 구조적 제거.
2. **iOS 코버플로우는 실은 평면**(RecallHeroView `maxTilt=0`) — 수식(x/scale/opacity)만 이식하고 웹에서 깊이·틸트·RoundedBox 두께·ContactShadows 로 3D 격상. R3F 는 현재 recall 씬만, 텍스트는 절대 WebGL에 넣지 않기로.
3. **`MochiItemCreateRequest`에 capturedAt 없음** → 시간축(며칠 전·D-day)은 웹 시드 단독 소유. 시드는 전부 상대값(capturedDaysAgo/dateInDays/deadlineInDays), 절대화는 서버 주입 `now` 로 렌더 시점에만.
4. **4-Intent 메타 비노출**: "분류했어요" 카피 금지 — S2 는 카드가 체크리스트·캘린더 점·서재로 "꽂히는 행동"만 보여줌. 칩 라벨(일정/할일)은 필터로만.
5. 폴백 ingest 는 **입력을 id 에 base64url 인코딩** (`fb.…`) — 서버 무상태로 Vercel 인스턴스 분산에도 안전.
6. 이미지 없는 회수 카드는 **CanvasTexture** 로 타일 문법을 그려서 3D 카드에 얹음 (`recall/cardTexture.ts`).
7. 목업 캡처는 HTML 템플릿→Playwright 촬영 (저작권 안전, 로고 미사용). 재촬영: `npx tsx scripts/capture-mocks/shoot.ts [파일명필터]`.

## 5. 미완 결정 (대기 중)

- **페르소나 실계정 시딩(P7)**: prod DB 에 user row 3건 수동 삽입 필요(사람 단계) + 백엔드 `scripts/backfill_embeddings.py` 실행. env 키 계약: `MOCHI_PERSONA_UUID_{SENA,DOHYUN,YUNA}`.
- **시크릿 회전**: 구 mochi-web `.env.local` 의 `MOCHI_JWT_SECRET` 이 히스토리에 존재 — 회전 권장(백엔드 협의). 현 `.env.local` 은 gitignore 상태로 로컬 보존(백업: 세션 스크래치패드 `salvage/`).
- 파비콘 없음(콘솔 404 1건), `/dev/tokens` 임시 페이지 — P6/P7 정리 대상.

## 6. 다음 단계 + 검증 기준

### P5 — 라이브 연결 (라우트에 upstream 앞단 붙이기)
- `lib/bff/token.ts`(jose HS256, iss/aud=`mochi.app`, sub=페르소나 UUID, TTL 30분, 25분 캐시) + `lib/bff/upstream.ts` + `lib/bff/ratelimit.ts`(토큰버킷, 초과 시 429 아닌 **폴백 강등**).
- 채팅: upstream `POST {MOCHI_BACKEND_URL}/api/v1/conversations/{cid}/messages` 스트림 패스스루, **first-byte 8s/inter-event 15s 초과 시 스트림 안 끊고 서버가 폴백 이벤트 이어붙여 완결**. 409 → 새 conversationId 1회 재시도(클라 훅에 이미 입력잠금 있음).
- 검색: `POST /api/v1/search` → citations uuid 는 클라가 `backend-ids.json` 으로 slug 해석(이미 구현됨 — `resolveItemSlug`).
- 라이브 분석: 실 ingest(presign 없이 text/url만) + `GET /mochi_items/{id}/stream` 프록시.
- 킬스위치 `MOCHI_FORCE_FALLBACK=1` 전역 분기.
- 검증: dev 에서 curl 스모크, 스트림 강제 절단→폴백 완결, **Vercel preview 조기 배포로 SSE 버퍼링 실검증**(P5 안에서!).

### P6 — 랜딩·선택·레일·피날레 (디자인 하이라이트 구간)
- S0 `/`: R3F 기억 파편 필드(실캡처 텍스처 12~16, 라벤더 팔레트 `lavender-100~900`), 텍스트·CTA는 DOM(LCP), `WebGLGate` 폴백, next/dynamic ssr:false. **미션 카피가 첫 화면**: "필요한 기억은 쉽게 떠오른다".
- S1 `/p`: 페르소나 카드 3장(이름·tagline·heroSlugs 캡처 스택·intent 미니 스택바). `border-beam` npm 은 추천 카드 1장에만.
- `JourneyRail`: 하단 상주(진행 도트·다음·건너뛰기·→키), `?guided=1`+sessionStorage. 여정 순서: capture→홈→search→chat→**recall**→finale.
- S7 `/finale`: 여정 요약 3칸 + 아키텍처 SVG + iOS QR + 페르소나 재선택 + MochiWalk 25프레임 CSS steps() (`public/walk/`).
- 검증: `--disable-gpu` 폴백 스크린샷, LCP<2.5s, three lazy chunk 확인(`next build` 출력), guided 완주 ≤8분 E2E.

### P7 — 시딩·배포·문서
- `scripts/seed-backend.ts`(JWT 서명→`POST /mochi_items` confirmedInstances, `Idempotency-Key: {persona}:{slug}:v1`) → `backend-ids.json` 커밋.
- **문서 동기화 (CLAUDE.md §6 — 누락 시 미완성)**: `docs/CHANGELOG.md` 항목, `docs/ARCHITECTURE.md` §1 mochi-web 갱신, 새 `mochi-web/README.md`(빌드·BFF·env·시딩 정본), AGENTS.md 는 유지됨.
- Lighthouse perf≥85·a11y≥95, /ship 후 PR.

## 7. 컨텍스트 부채 — 다음 세션이 먼저 볼 것

1. `~/.claude/plans/cozy-mapping-tiger.md` — 승인된 플랜 전문 (여정 표·아키텍처·검증 기준).
2. `mochi-web/node_modules/next/dist/docs/` — **AGENTS.md 규칙: 코드 전 필독**. 이미 확인한 것: middleware→`proxy.ts`, async params(`await params`), Turbopack 기본, eslint flat config(`defineConfig`+`eslint-config-next/core-web-vitals`), image qualities 기본 변경. P6 에서 랜딩 만들 때 fonts/images 문서 재확인.
3. **스킬 사용 지도** (구현 중 반드시 활용):
   - R3F/3D 작업(P6 랜딩) → `core-3d-animation:react-three-fiber`, `threejs-webgl`, `meta-skills:web3d-integration-patterns`
   - 스크롤 연출(랜딩·피날레) → `core-3d-animation:gsap-scrolltrigger`
   - 마이크로 인터랙션 → `make-interfaces-feel-better`(이 세션에서 적용한 원칙: 동심원 radius, 이미지 ring-black/10, tabular-nums, 스태거, transition 속성 명시), `design-motion-principles`
   - 디자인 품질(랜딩 아트디렉션) → `frontend-design:frontend-design`, `design-taste-frontend`
   - 카피 → `mochi-ux-writing` (결과 직설, 마스코트 서사 금지 — 사용자 확정 취향)
   - 마감 감사 → `design-motion-principles`(audit 모드), `react-doctor`
4. **기술 gotcha**:
   - 날짜는 무조건 `kstParts()/midnight()` — `new Date().getMonth()` 류 직접 호출 금지 (codex P1 재발 방지).
   - R3F 파일은 `eslint-disable react-hooks/immutability` 필요(프레임 루프 ref 뮤테이션), RSC 의 `Date.now()`는 purity 예외 주석.
   - drei `Image` 는 radius prop 지원(확인됨), `Environment` preset 은 CDN 페치라 **오프라인 데모에 금지** — 조명은 라이트 3개로.
   - dev 서버 실행 중이었음(포트 3456, 백그라운드) — 새 세션은 새로 띄우면 됨.
   - Playwright MCP 스크린샷 산출물은 커밋 금지(.gitignore 에 .playwright-mcp 추가돼 있고 루트 jpg 는 정리 필요할 수 있음).
5. **UI 컴포넌트 재사용 규칙**: 피드 카드는 무조건 `tiles/ItemTile`(3변형 내장), intent 칩은 `INTENT_META`, 회수 이유는 `REASON_META`(glow 색 포함), 등장 모션은 `RiseIn(index)`, 숫자는 `RollingNumber`+`tnum`. 새 색 만들지 말 것 — `globals.css @theme` 에 있는 브랜드 색만 (없으면 iOS HomeDesign.swift 대조 후 추가).
6. 검증 명령: `npm run typecheck && npm run lint && npm test && npm run build` (prebuild 가 validate:seed 실행). 목업 재촬영 `npx tsx scripts/capture-mocks/shoot.ts`.
