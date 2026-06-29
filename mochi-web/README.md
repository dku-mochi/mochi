# mochi-web — 심사위원용 BFF 데모 웹

> 모찌(MOCHI) 를 **설치 없이 브라우저에서 체험**시키기 위한 데모 사이트.
> 캡처를 담으면 분석이 흘러가고("정직-증거": 무엇을·왜 그렇게 판단했는지 보임), 회수 피드가 "왜 지금 떠올랐는지" 를 규칙 칩으로 증명한다.
> 같은 배포 백엔드(`34-64-104-136.nip.io`)를 **서버사이드 프록시**하므로 라이브 데이터를 쓰되, 백엔드가 막히면 씨드로 graceful degrade 한다.

이 README 가 mochi-web 의 빌드·실행·BFF 구조의 정본이다. 시스템 토폴로지에서의 위치는 [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) §1.

> ⚠️ 이 Next.js 는 학습데이터의 버전과 다르다(breaking changes). 코드를 쓰기 전 `node_modules/next/dist/docs/` 의 해당 가이드를 먼저 읽는다 (`AGENTS.md`).

---

## 스택

- **Next.js 16** (App Router) + **TypeScript** / React 19
- **Tailwind CSS v4** (`@tailwindcss/postcss`)
- **React Three Fiber** (`@react-three/fiber` + `@react-three/drei`) — 3D
- **GSAP** (ScrollTrigger) — 스크롤 연출
- **Framer Motion** — 트랜지션·마이크로 인터랙션
- `openapi-typescript` — 백엔드 계약 타입 생성 (dev 도구)

---

## 설치 · 실행

```bash
npm install
npm run dev      # 개발 서버 (http://localhost:3000)
npm run build    # 프로덕션 빌드
npm run start    # 빌드 결과 실행
npm run lint     # eslint
```

토큰 env 없이도 돈다 — `liveEnabled=false` 로 떨어져 씨드 폴백으로 동작한다(아래 [라이브 실패 시 폴백](#라이브-실패-시-폴백) 참고).

---

## BFF 구조

브라우저는 백엔드를 **직접 호출하지 않는다.** 모든 백엔드 호출은 서버에서만 도는 `app/api/*` Route Handler 를 통한다.

| 라우트 | 역할 |
| --- | --- |
| `app/api/analyze` | 캡처 입력(text/url/image) 접수 → 분석 진행을 **SSE** 로 흘림 (`data: {stage, result?}\n\n`) |
| `app/api/recall` | 회수 피드 — "왜 지금 떠올랐는지" 규칙 칩 포함 |
| `app/api/samples` | 샘플 카드 목록 (홈/갤러리용) |

- `lib/api/backend.ts` — 서버 전용 백엔드 클라이언트. 데모 유저 토큰을 보관·refresh(access TTL 30분 → 25분 안전마진 캐시)하고 모든 호출에 `Authorization: Bearer` 주입. ingest 는 `Idempotency-Key` 헤더 필수.
- `lib/env.ts` — **서버 전용** env (브라우저 노출 금지 — `'use client'` 에서 import 금지). 토큰·rate-limit·라이브 플래그.
- `lib/ratelimit.ts` — 인메모리 슬라이딩 윈도(1분) rate-limit. Vercel 인스턴스별 메모리라 데모용으로 충분.
- `lib/types.ts` — 백엔드 OpenAPI(`lib/api/schema.ts`)를 화면이 쓰기 쉽게 정제한 UI 도메인 타입.
- `seed/` — 라이브 실패 시 쓰는 씨드 데이터.

**토큰은 서버에만.** `MOCHI_DEMO_*` 토큰은 Route Handler 안에서만 읽혀 `Authorization` 으로 주입되고, 브라우저로는 절대 내려가지 않는다.

---

## 환경변수

`lib/env.ts` 가 정본. 전부 **서버 전용**.

| 변수 | 기본값 | 의미 |
| --- | --- | --- |
| `MOCHI_BACKEND_URL` | `https://34-64-104-136.nip.io` | 배포된 모찌 백엔드 (끝 슬래시 없음) |
| `MOCHI_DEMO_REFRESH_TOKEN` | `""` | 데모 유저 refresh token (180일). svc 에서 1회 발급해 주입 |
| `MOCHI_DEMO_ACCESS_TOKEN` | `""` | (선택) 미리 발급한 access token — refresh 실패 시 폴백 |
| `MOCHI_INGEST_PER_MINUTE` | `6` | BFF rate-limit: 세션당 분당 ingest 허용 수 |
| `MOCHI_LIVE_DISABLED` | (unset) | `1` 이면 라이브 프록시 끄고 씨드 폴백만 |

`liveEnabled` 는 `MOCHI_LIVE_DISABLED !== "1"` **이고** refresh/access 토큰 중 하나라도 있을 때 true.

---

## OpenAPI 타입 생성

API 계약의 단일 원천은 백엔드 `mochi-backend/openapi.json` (⓪-tier — `../docs/ARCHITECTURE.md` §3.6·§4). 그 스펙에서 타입을 생성한다.

```bash
npx openapi-typescript ../mochi-backend/openapi.json -o lib/api/schema.ts
```

`lib/api/schema.ts` 는 생성물이라 **직접 수정 금지**. 백엔드 계약이 바뀌면 재생성하고, 화면이 쓰는 정제 타입은 `lib/types.ts` 에서 손본다.

---

## 라이브 실패 시 폴백

라이브 호출(ingest → SSE stream)이 막히면 — 토큰 없음·`MOCHI_LIVE_DISABLED=1`·백엔드 4xx/5xx·네트워크 실패 — 데모가 죽지 않도록 graceful degrade 한다.

- **`/api/analyze`**: 입력 텍스트/URL 을 기반으로 그럴듯한 `AnalysisResult` 를 추정해 **같은 SSE 포맷**으로 가짜 진행을 흘린다(ingested → normalized → analyzing → analyzed).
- **`/api/recall`·`/api/samples`**: `seed/` 의 씨드 카드로 폴백.

폴백은 포맷이 동일해 클라이언트는 라이브/씨드를 구분하지 않는다.

---

## Vercel 배포

- Vercel 에 연결하고 위 env 를 **Vercel Environment Variables** 로 주입한다(특히 `MOCHI_DEMO_REFRESH_TOKEN`). 토큰은 코드/클라이언트에 두지 않는다.
- `npm run build` 가 빌드 커맨드. App Router 기본 설정으로 배포.
- rate-limit 은 인메모리라 인스턴스마다 별도 — 데모 부하엔 충분하지만 강한 보장이 필요하면 외부 스토어로 교체한다.
