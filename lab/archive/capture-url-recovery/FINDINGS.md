# FINDINGS — capture-url-recovery

캡처 이미지만으로 원문 URL 을 best-effort 복원 (2026-06-13~).

**아이디어**: 유튜브/X/쓰레드 스크린샷을 저장하면, 그 캡처만으로 원문(게시물/영상) 링크를
카드 상세에 노출한다. 정확한 deep-link 가 안 되면 프로필/검색 링크라도 — **best-effort**
(사용자 선택). 미션 "필요한 기억은 쉽게 떠오른다"의 회수 보강.

**선행**: `archive/youtube-enrich/` 가 YouTube 비전추출+무키 메타복원을 이미 검증
(videoId 8/8 발견, 수동검수 6/8 정확). 본 실험의 신규 미지수는 **X·Threads** 의
복원 상한 + best-effort tier 의 실제 도달성이다.

**복원 tier** (높을수록 좋음): `post`(정확 게시물 URL) > `profile`(작성자) > `search`(검색결과) > `none`.

**검증 단계**:
1. `exp1_recover_id.py` — 캡처에서 복원 단서(platform·@handle·author·title·post_text·
   search_query)를 정확히 뽑을 수 있는가. flash-lite vs 3.5-flash + LLM judge (특히 handle OCR).
2. `exp2_url_recovery.py` — 그 단서로 플랫폼별 best-effort URL 을 실제로 만들 수 있는가 (도달성).
3. `exp3_x_syndication.py` — X 비공식 syndication 으로 post-level 까지 가능한가 + fragility 측정.
4. `cloud_ip_check.py` — (X 한정) 데이터센터 IP 에서 Cloudflare 차단 여부 — 착수 전 게이트.
5. `recover.py` — 위 조각을 잇는 **오케스트레이션 프로토타입**. 흐름 A(§구현 핸드오프)를 단일
   `recover(clues) -> RecoveryResult` 로 구현 — production 복원 tool `run()` 의 골격. (3건 실측:
   YouTube=post, X=post(score 1.0), Threads=profile)

---

## 실험 결과 메모

### exp2 — URL 복원 도달성 (2026-06-13, `results/exp2_20260613_133608.json`)

공인 공개 계정 3건(YouTube/X/Threads)으로 무키 복원 실측 (`--defaults`):

| 플랫폼 | 도달 tier | 경로 | 결과 |
|---|---|---|---|
| **YouTube** | **post** ✅ | 무키 검색(`/results`) → 첫 `"videoId"` → `watch?v=` → oEmbed 검증 | `9wUKhEgnllc` 복원 → oEmbed 200, 제목 "NewJeans 'Hype Boy' Official MV" 정확 |
| **X** | **profile** | `@handle` → `x.com/{handle}` (게시물 deep-link 무키 경로 없음) | 200. 프로필까지만 — tweet_id 가 화면에 없어 post 불가 |
| **Threads** | **profile** | `@handle` → `threads.net/@{handle}` (→ `threads.com` 301) | 200. 프로필까지만 |

- **핵심 확정**: 가설대로 **YouTube=post, X·Threads=profile 이 무키 상한**. X 게시물 URL 은
  `x.com/{handle}/status/{tweet_id}` 인데 tweet_id 가 캡처 화면에 없고, 무키 텍스트→게시물
  검색 경로가 막혀 있어 deep-link 복원 불가. Threads 동일. → best-effort 선택이 옳았다.
- **UA 함정**: YouTube 검색 스크랩은 **데스크톱 UA 필수**. iPhone UA 면 `m.youtube.com` 로
  리다이렉트되어 결과 HTML 에 `ytInitialData`(videoId) 가 안 실린다(`has_videoId_str=False`).
  → 검색 스크랩은 **서버측 단계**라 사용자 UA 와 무관, 데스크톱 UA 로 긁고 복원된 watch URL 만
  사용자에게 준다 (그 URL 은 아이폰 브라우저에서 정상). `SCRAPE_UA` 로 분리 반영.
- **봇 차단 주의**: X/Threads 프로필은 GET 200 이나 본문은 JS 렌더라 서버 사전검증엔 부적합.
  최종 UX 는 `results/exp2_links_*.md` 링크를 실기기에서 탭해 확인 (앱 핸드오프 포함, 미수행).

### API 지형 — X·Threads post-level 복원 가능성 (2026-06-13, 실측)

"공식 API로 X·Threads도 post-level 복원되나" 조사:

| 경로 | 존재 | 캡쳐→게시물 URL 복원 |
|---|---|---|
| 공식 Threads API (2024~) | ✅ | ❌ **내 계정 글만** 읽기/게시 — 임의 공개 사용자 텍스트 검색 불가 |
| Instagram Graph oEmbed | ✅ | ❌ URL 선행 필요 (메타 보강용, `PlatformContextTool` 보유) |
| X API v2 recent search | ✅ | ⚠️ 유료 Basic($200/mo)~·최근 7일 한정 — 대회 비용 비현실적 |
| X oEmbed (무키) | ✅ | ❌ URL 선행 필요 |

→ **공식·무키 경로는 전부 "URL 선행 메타 보강" 또는 "내 계정 전용".** 캡쳐→URL 생성은 없음.

**비공식 우회로 — X syndication (실측 LIVE)**:
- `syndication.twitter.com/srv/timeline-profile/screen-name/{handle}` → 무키 200, **최근 트윗
  status ID 다수**(elonmusk 113개) 반환. `handle → 최근 트윗 → 캡쳐 텍스트 매칭 → status URL`
  로 **post-level 복원이 기술적으로 가능**. 단 본문 텍스트는 HTML 미렌더라 entries JSON 역공학
  또는 per-tweet `cdn.syndication.twimg.com/tweet-result?id=` 추가 필요.
- **리스크**: youtube-enrich 가 기각한 `youtube-transcript-api` 와 동일 클래스 — 비공식·클라우드
  IP 차단 가능·언제든 깨짐(지속성 취약) + **최근 트윗만** 커버 + 텍스트 매칭 모호성.
- Threads: 프로필 JS 렌더라 초기 HTML 에 permalink 0개, 공식 API 내 계정 전용 → **무키 post-level
  막다른 길**. profile 이 상한.

**결론**: 신뢰 경로는 X·Threads **profile best-effort 유지**(exp2). post-level X 는 비공식
syndication 을 *베팅 전에 측정* → exp3 에서 실측(아래).

### exp3 — X syndication post-level 복원 실측 (2026-06-13, `results/exp3_*.json`)

`__NEXT_DATA__` 에 최근 트윗(`full_text`·`id_str`·`permalink`·`created_at`)이 무키로 실림.
`handle → 타임라인 → 캡쳐 본문 매칭(SequenceMatcher) → x.com/{handle}/status/{id}` 측정:

| handle | 타임라인 수 | 최근성 깊이 | top-1 정확도 | avg score |
|---|---|---|---|---|
| elonmusk | 100 | ~1년 (2025-06) | **1.0** | 0.96 |
| nasa | **18** | 수일 (2026-06) | 0.92 | 0.48 |
| naval | 99 | ~1년 (2025-04) | 0.83 | 0.65 |

수동: `"SpaceX AI Satellites"` → `x.com/elonmusk/status/2064187087184650253` 정확(score 1.0).

**판정 — 작동하나 fragile**:
- (1) **생존성**: 이 머신 기준 200. **클라우드 IP 미검증** — 배포(Cloud Run/GCP) 에서 차단되면
  통째로 죽는다(youtube-enrich 가 transcript-api 를 기각한 바로 그 이유). **배선 전 클라우드에서 GET 200 확인 필수.**
- (2) **최근성 깊이 계정별 들쭉날쭉**: elon/naval ~100개(≈1년)지만 NASA 는 18개(수일)뿐.
  오래된 캡쳐·타임라인 밖 게시물은 못 찾음 → match 실패 시 profile 폴백 필수.
- (3) **매칭 정확도**: 특징적 본문 top1=1.0, 짧고 유사한 글(naval) 0.83. 위 평가는 *깨끗한*
  본문 앞 50자 기준 — 실제 OCR 오차·요약 변형이 더해지면 하락. score 임계로 게이트 필요.

→ **X post-level 은 "작동하지만 베팅하면 안 되는" 보강책**: 매칭 score 높고 타임라인 안에 있을
때만 status URL, 아니면 profile. ship 여부는 *유지보수 fragility* 비용을 팀이 받아들이냐의 문제.

#### 클라우드 IP 생존성 — 차단 메커니즘 규명 (2026-06-13, `cloud_ip_check.py`)

exp3 의 200 은 *주거용(로컬) IP* 결과다. 프로덕션은 데이터센터 IP 에서 나가므로 별도 검증.
엔드포인트 응답 헤더 특성화 결과:

- **`server: cloudflare envoy` + `__cf_bm` 쿠키** → Cloudflare 봇 매니지먼트 활성. Cloudflare BM
  은 **데이터센터 ASN(GCP/AWS) 을 능동 challenge** 하는 그 계층 — 클라우드 IP 차단의 주범.
- **`x-rate-limit-limit: 30`, 윈도우 15분(`x-rate-limit-reset` 으로 확인), IP당.** 초과 시 429.
  주거 IP 는 윈도우 후 회복(remaining 30 복귀) — 즉 429 는 영구차단이 아니라 레이트리밋.
- **프로덕션 산수**: 캡쳐 1건 = 타임라인 1요청이면, **단일 공유 egress IP 로는 전 서비스가
  X 복원 ~120건/시간(30/15min)에 묶인다.** Cloud Run 의 공유 NAT egress 라면 더 빡빡.
- **`cf-cache-status: DYNAMIC`** (origin 직격, 캐시 완충 없음) → 차단/레이트리밋이 그대로 노출.

**남은 단 하나의 실측**: 실제 Google 데이터센터 IP 에서 challenge(403/503) 가 뜨는가.
`cloud_ip_check.py` 를 **GCP Cloud Shell** 또는 **실제 Cloud Run egress** 에서 1회 실행 →
verdict `PASS`(데이터회수)/`BLOCKED`(Cloudflare challenge)/`RATE_LIMITED` 판정. (로컬 검증: PASS)

**종합 판정**: cloud_ip_check 가 PASS 여도, **30/15min per-IP + Cloudflare BM** 때문에 X
post-level 은 *규모 있는 primary 경로로는 부적합*하다(IP 풀/로테이션 = youtube-enrich 가 기각한
residential-proxy fragility 와 동급). BLOCKED 면 경로 자체가 죽는다. → **profile best-effort 가
신뢰 기본, X post-level 은 저빈도·score 게이트·실패 시 profile 폴백 한정의 옵션.**

### exp1 — 단서 추출 (미실행, 자격증명·스크린샷 필요)

ADC + `GOOGLE_CLOUD_PROJECT` + `lab/data/screenshot/` 의 소셜 캡처가 있어야 실행. 평가 포인트:
- **handle OCR 정확도** — youtube-enrich §5 가 지목한 복원 병목. judge `handle_match`(1-5)로 측정.
- X·Threads 의 handle/본문 추출이 YouTube 만큼 되는가 (신규 미지수).
- flash-lite(프로덕션 agent 모델) 단독으로 충분한지 vs 3.5-flash.

> mac 사용자 또는 cred 세팅 후 실행 → 이 절에 표를 채운다.

---

## 구현 핸드오프 (구현 주체: mac 사용자)

이 lab 의 스크립트는 **동작하는 알고리즘 그 자체**다. 아래는 (A) production 결정 흐름,
(B) 어느 함수를 그대로 옮겨오나, (C) 어디에 배선하나, (D) 착수 전 필수 확인 순서다.

### A. End-to-end 결정 흐름 (production 이 따라야 할 알고리즘)

```
캡처 저장
  └─ [민감 캡처 게이트] (PRIVACY_SENSITIVE_CAPTURE.md) — 민감신호면 복원·외부fetch 중단
       └─ 비전 단서추출 (analysis): {platform, handle, author, title, post_text, search_query}
            ├─ platform=youtube → /results 검색(SCRAPE_UA=데스크톱) → 첫 videoId
            │                      → watch?v={id} → oEmbed 검증
            │                      → 성공: recover_level=post / 실패: 검색 URL(search)
            ├─ platform=x       → syndication 타임라인 → 본문매칭(score)
            │                      ├─ score≥임계 AND 타임라인 윈도우 안 → status URL (post)
            │                      └─ 아니면 → x.com/{handle} (profile)
            ├─ platform=threads → threads.net/@{handle} (profile — post 무키 불가)
            └─ 단서 없음(handle·title 모두 null) → none (복원 생략)
       └─ 결과: IntentPayloadDTO.url + recover_level(post|profile|search|none) 동봉
```

핵심 규칙: **recover_level 을 함께 실어 보낸다.** UI 가 "정확 영상 / 작성자 프로필 / 검색"을
구분 표기해야 best-effort 가 정직해진다(없는 정확도를 가장하지 않음).

### B. 그대로 옮겨올 수 있는 코드 (이 lab 에 이미 있음)

| 기능 | 출처 | 함수/상수 |
|---|---|---|
| YouTube 검색→videoId→watch→oEmbed | `exp2_url_recovery.py` | `recover_youtube()`, `YOUTUBE_ID_RE`, `SCRAPE_UA` |
| X/Threads 프로필 조립 + 검색 폴백 | `exp2_url_recovery.py` | `recover_profile_platform()`, `_clean_handle()` |
| X 타임라인 파싱 (handle→트윗 리스트) | `exp3_x_syndication.py` | `fetch_timeline()`, `NEXT_DATA_RE`, `_find_entries()` |
| 본문→트윗 매칭 (score) | `exp3_x_syndication.py` | `best_match()`, `_norm()`(t.co 제거), `TCO_RE` |
| 클라우드 IP 차단 프로브 | `cloud_ip_check.py` | (배선 전 게이트로 1회 실행) |
| **흐름 A 오케스트레이션** | `recover.py` | `recover(clues, client)` — 위 전부를 잇는 단일 진입점 = tool `run()` 골격 |

`recover.py` 가 production 이식의 출발점이다: `recover()` 본문이 곧 복원 tool 의 `run()` 이고,
`[GUARD]` 주석 위치에 `_guarded_get` 을 끼우고 입출력을 DTO 로 바꾸면 된다. lab 수준 단순화
(가드·DB·DI·config 없음, X score 임계 placeholder)는 의도된 것 — production 이 입힌다.

⚠️ **이식 시 반드시 SSRF 가드를 입힌다.** lab 스크립트는 `httpx.get` 을 가드 없이 직접 호출한다
(실험 단순화). production 의 외부 fetch(`syndication.twitter.com`, `youtube.com/results`,
oEmbed)는 `PlatformContextTool` 의 `_guarded_get`/`_enforce_host_policy`(SSRF·redirect 재검증·
응답크기 제한)를 거쳐야 한다 — `web_fetch` 와 동일 정책.

### C. 배선 지점 (기존 인프라에 surgical 하게)

1. **단서 추출**: 분석 프롬프트(`system_prompts.py`)에 소셜 캡처 한정 단서 산출 추가
   (platform·handle·search_query). shopping-product-link 가 `entities` 경로를 재사용한 선례 참고
   — 별도 모델/패스 없이 agent 분석에 합류.
2. **URL 복원 tool**: `PlatformContextTool`(`platform_context.py`) 가 이미 X/YouTube/Instagram
   oEmbed + SSRF 가드를 보유하나 입력이 `HttpUrl`("URL 이 이미 있을 때")이다. 빠진 조각은
   **"단서 → 후보 URL"** — 위 B 의 함수들을 가드로 감싸 같은 tool(또는 형제 tool)에 추가.
3. **노출**: 복원 URL + recover_level 을 `IntentPayloadDTO.url`(이미 존재)+신규 필드로 카드 상세에 노출.
4. **민감 캡처 게이트**: 복원·외부 fetch 는 ingestion 경로를 건드리므로
   `docs/PRIVACY_SENSITIVE_CAPTURE.md` 의 민감신호 차단을 복원 앞단에 둔다(흐름 A 의 첫 게이트).
5. **docs 동기화**: 이 시점에 `DOMAIN_DESIGN.md`(url/recover_level 필드)·`ARCHITECTURE.md`
   (외부 fetch 토폴로지)·양 README 를 따라 맞춘다 (지금 lab 단계에선 docs/ 미반영이 정상).

### D. 착수 전 필수 확인 (순서대로 — 실패하면 범위 조정)

1. **exp1 실행** (cred+스크린샷) → platform/handle/title **OCR 정확도 수치화**. 이게 전체의
   입력 품질이자 X 매칭 score 임계의 근거. handle 오독률이 높으면 X post-level 은 접고
   YouTube(oEmbed 검증으로 오독 자동 교정됨)만 간다.
2. **X 한정** `cloud_ip_check.py` 를 **실제 Cloud Run egress** 에서 1회 → `BLOCKED` 면 X
   post-level 옵션 자체 제거(profile 만). `PASS` 여도 30/15min 레이트리밋 게이트는 그대로.
3. (선택) YouTube `/results` 스크랩도 Cloud Run egress 에서 200 확인 — oEmbed 는 공식이라
   안전하나 검색 스크랩 단계는 미검증. BLOCKED 면 검색 폴백만(영상 직링크 없이).
4. `results/exp2_links_*.md` 실기기 탭 확인 (X/Threads 프로필 앱 핸드오프 포함).

### 우선순위 권고

**YouTube 부터 배선**(견고·oEmbed 검증, 위 1·3만 확인) → **X·Threads 는 profile best-effort**
(항상 동작) → **X post-level 은 위 1·2 통과 + score 게이트 시에만 옵션으로 얹기**. 신뢰도 순위
`YouTube(post) > X(post, 조건부) > {X,Threads}(profile)` 그대로.
