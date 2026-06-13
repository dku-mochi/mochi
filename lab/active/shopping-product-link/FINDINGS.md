# FINDINGS — shopping-product-link

쇼핑 캡처 → 카드 상세 구매 링크 실험 (2026-06-13~).

**아이디어**: 주간 정리 category 로 분리되는 쇼핑 캡처에 대해, 카드 상세에 구매 링크를
단다. 특정 판매자를 우리가 정할 수 없으므로 상품 상세가 아니라 **커머스 검색 결과
상태의 링크**(쿠팡/네이버 등)를 제공한다.

**검증 단계**:
1. `exp1_product_id.py` — 캡처(스크린샷/메모)에서 상품을 *검색어로 쓸 수 있을 만큼*
   정확히 식별할 수 있는가. flash-lite(프로덕션 agent 모델) vs 3.5-flash 비교 + LLM judge.
2. `exp2_search_link.py` — 식별된 상품명으로 검색 상태 URL 이 실제로 동작하는가
   (인코딩·URL 패턴 유효성·봇 차단 여부 + 실기기 수동 확인용 링크 목록).

---

## 실험 결과 메모

### exp1 — 상품 식별 (2026-06-13, `results/exp1_20260613_021957.json`)

30케이스 (스크린샷 22 + 합성 메모 8, 쇼핑/비쇼핑 혼재):

| 지표 | flash-lite (프로덕션 agent) | 3.5-flash |
|---|---|---|
| 쇼핑 검출 | 15건 | 15건 |
| is_shopping 판단 적절 (judge) | 30/30 | 30/30 |
| exact (모델/품번 수준) | 13/15 | 13/15 |
| product_match (judge, 1-5) | 3.93 | 3.97 |
| searchable (judge, 1-5) | 3.90 | 3.90 |

- 옷·화장품·전자기기 스크린샷 모두 브랜드+상품명 수준으로 식별 ("로지텍 MX 마스터 3S 펄화이트",
  "아비브 어성초 패드 140매", "쿠어 스탠드 칼라 넥 다운 푸퍼").
- 감점은 의도적 모호 메모 2건뿐 ("신발 예쁜 거 봐둠"→"신발") — 모델이 category 로 정직하게
  강등. **specificity(exact/category/unknown) 필드로 링크 노출을 게이트하면 된다.**
- **flash-lite ≈ 3.5-flash 동급** → 프로덕션 agent 분석 단계에서 product_query 를 함께
  뽑는 확장이 현실적 (별도 모델/패스 불필요).

### exp2 — 검색 상태 링크 (2026-06-13, `results/exp2_20260613_022115.json`)

exp1 산출 상품명 20건 × 4 제공자, iPhone Safari UA 로 GET:

| 제공자 | 결과 |
|---|---|
| **쿠팡** `coupang.com/np/search?q=` | 18/20 status 200 + **본문에 상품 토큰 전부 등장**(검색 결과 서버 렌더 확인), 2건 간헐 403(봇 차단) |
| 네이버쇼핑 `search.shopping.naver.com/search/all?query=` | 전건 418(봇 차단) — 서버측 사전 검증 불가, 브라우저 동작은 별도 확인 필요 |
| 네이버 통합 `search.naver.com/search.naver?query=` | 전건 200 + 토큰 등장 — 안전한 폴백 |
| 구글 | 전건 200 이나 본문 JS 렌더라 서버측 관련성 판단 불충분 |

- 한국어 상품명 percent-encoding 문제 없음. URL 패턴 전부 유효(redirect 정상).
- **결론: "검색된 상태" 링크는 가능하다.** 쿠팡이 1순위(서버에서 결과 존재까지 확인됨),
  네이버 통합이 폴백. 네이버쇼핑은 달 수는 있으나 서버 사전검증 없이.
- 봇 차단(403/418) ≠ 사용자 브라우저 실패 — 최종 UX 는 `results/exp2_links_*.md` 의
  링크를 실기기에서 탭해 확인 (미수행, 남은 단계).

### exp4 — 범용 라우팅 (2026-06-14, `results/exp4_20260614_001841.json`)

exp3(shop 단일)은 실행 생략하고 exp4 로 일반화해 흡수. 핵심 질문이 "쇼핑 검색어가 잘
나오나"에서 "**임의 캡처 → 어느 종류 자료가 필요한지 라우팅 → 네이버 검색 단일 백본으로
실재 URL 이 나오나**"로 바뀜(사용자 비전: 범용 resource finder).

12 합성 케이스(도메인 혼재) — 라우터 flash-lite `{needs_resource, category(shop|local|blog|news|none), query}`
→ 네이버 검색 엔드포인트별 → judge 3.5-flash:

| 지표 | 값 |
|---|---|
| routing_ok_rate | **1.0** (12/12) |
| none_rate | 0.25 (친구대화·마감일 등 URL 불필요 3건 정확 분리) |
| found_rate | **1.0** (검색 9건 전부 total>0, 헛검색 0) |
| avg_usefulness | **4.22 / 5** (judge, 검색한 것만) |

- **네이버 검색 API 단일 키로 shop/local/blog/news 멀티 도메인 전부 커버** — 사이트별 어댑터
  불필요, 카테고리 라우팅만으로 충분. "범용 백본" 가설 입증.
- 약점 1: 모호한 쇼핑("엄마 생신 선물 추천")은 generic 결과(top1=용돈박스) → exp1 의
  specificity 게이트 재확인. 라우터가 exact 수준 미달이면 none 으로 강등 필요.
- 약점 2: 영상 자체(넷플릭스 작품/유튜브 클립)는 네이버 검색으로 부정확 — 라우터가 blog
  ("넷플릭스 다큐 추천 글")로 우회. **video 카테고리 + 메타 도구(`PlatformContextTool`) 별도** 필요.
- 아키텍처: "sub agent" 아니라 **메인 agent loop 의 tool** 로 승격이 정확 — 기존 `Tool[TIn,TOut]`
  ABC + `StaticToolRegistry` 구조에 `ResourceFinderTool` 추가(메인이 필요 판단→function call→
  실재 URL 반환, 환각 0). 토큰은 tool 내부 라우터(flash-lite)로 분리.

### exp5 — ResourceFinder loop agent (2026-06-14, `results/exp5_20260614_003612.json`)

exp4(단발 route→search→judge)를 **자체 loop 도는 mini-agent** 로 진화(사용자 방향): route
(generic 캡처는 검색 가능 키워드로 분해) → search loop(네이버 1차 + Tavily web 폴백, ≤2 iter,
critique 가 재검색 쿼리 제시) → final judge 게이트(무용하면 빈손). 18 합성 케이스.

| 지표 | Tavily 없이 | **Tavily 폴백** |
|---|---|---|
| final_useful_rate | 0.44 | **0.61** |
| fallback_used | 0 | **3** (web 3건 전부 구제) |
| suppressed(judge 버림) | 5 | 2 |
| refine_count | 4 | 1 |
| avg_iters | 1.31 | 1.08 |
| avg_usefulness(useful만) | 4.62 | 4.64 |
| none_rate / rescue_count | 0.28 / 2 | 0.28 / 2 |

- **2-tier 백본 확정**: 네이버(한국 shop/local/blog/news) 1차 + Tavily(범용·해외) 폴백. 네이버
  사각(영어/해외: React Server Components·Netflix 다큐·mechanical keyboard)을 Tavily 가 전부
  구제 → useful_rate 0.44→0.61.
- **loop 3요소 작동**: 키워드 추출(엄마 생신선물 rescue 2) · 폴백(3) · final judge 억제(무용 2 차단).
  none 5건 정확 분리. 검색 시도 13건 중 11 useful(85%). 전부 실재 검색 → 환각 0.
- 남은 약점: (a) vague_gift — "엄마 생신선물" top 이 여전히 용돈박스 generic, "여자친구
  화이트데이"는 judge 가 버림. 키워드 분해가 "여성 귀걸이" 수준 구체까진 못 감. (b) news("금리
  인하")는 결과 과다·generic 해 특정 기사로 못 좁혀 judge 가 버림. → 프로덕션 specificity 게이트로 흡수.
- 아키텍처 확정: 프로덕션 `ResourceFinderTool` = 메인 agent loop 의 tool, 내부는 이 loop
  (route→search(naver/tavily)→critique→judge). env: NAVER_CLIENT_ID/SECRET·TAVILY_API_KEY(.env 보유).

### exp6 — 실데이터 97건 (2026-06-14, `results/exp6_20260614_010146.json`)

exp5(합성 18건) 데이터 부족 지적 → 프로덕션 DB(`mochi-db` VM docker pg, IAP SSH 경유)에서
실제 mochi_items 97건 추출(텍스트만, 이미지 제외; `lab/data/mochi_items_prod.jsonl`, gitignore).
loop 구조는 exp5 그대로, **입력만 교체**(route 가 summary 보고 키워드 생성).

| 지표 | 값 |
|---|---|
| final_useful_rate | 0.48 (47/97) |
| none_rate | 0.34 (33건 검색 불필요 판단) |
| suppressed | 17 (검색했으나 judge 가 무용 판정해 차단) |
| avg_usefulness(useful만) | 4.64 |
| fallback_used | 16 (Tavily web) |
| avg_iters | 1.19 |

- 검색 시도 64건(97−none33) 중 47 useful = **73%**. none+suppressed=50건을 "안 보여줄"
  결정 → 보여주는 건 확실할 때만(4.64). "혹시 이거?" 신뢰의 핵심.
- category별: 쇼핑후보 **0.89**(구체 상품명) > 투자 0.67 > 쇼핑 0.53 > 학업 0.50 > 일상 0.43. 구체적일수록 잘됨.
- route 키워드 품질 양호: 정확 상품명(데이지크 틴트/로지텍 MX/콜게이트), 분해(유니클로 아이템별),
  해외제품 web+영어(Lofree EDGE), none 정확(카톡대화/계획).
- 실패 패턴(suppressed): (a) generic 추천 키워드("육아템 추천"·"남성 약산성 세안제 추천"·
  "보온병 추천")→빈약/무관, (b) 품절·희귀(배스킨 토이스토리컵 검색0), (c) local 약함(동탄 미용실),
  (d) 브랜드명 일반명사화(LUCIER 안경→무관 뿔테). judge 게이트가 전부 차단(false positive 억제 작동).
- 결론: 실데이터에서도 ResourceFinder loop 유효. 약점은 generic 키워드 분해 품질 + local 검색.
  **다음(exp7): 비용 측정(`app.shared.llm_cost`/`llm_usage` 재사용) + generic 키워드 분해 개선.**

### exp7 — 비용+generic개선+티어랭킹, exp6 실패 20건 (2026-06-14, `results/exp7_20260614_013315.json`)

exp6 의 "검색 시도했으나 실패(suppressed)/빗나간(usefulness≤3)" 20건 타겟. ① generic 키워드
개선(ROUTER_PROMPT) ② 비용 측정(서버 `app.shared.llm_cost`/`llm_usage` 재사용) ③ 액션티어 랭킹.

**개선 효과 net 0** (improved 2 / regressed 2 / still_failing 15, useful_rate_delta 0.0):
- 살린 것(2): local 류(여의도 베이커리·마을버스 시간표) — 군더더기 제거가 먹힘.
- 깬 것(2, 부작용): 영어 검색이 나았는데 한글 강제 / 과도한 none 처리.
- **핵심: 실패 20건은 키워드 문제가 아니라 "검색 대상 부재"** — ROUTER_PROMPT 튜닝으론 못 고침.

**실패 2부류:**
1. **"영상 속 추천 리스트"(가장 큰 덩어리)** — 애둘맘 잘산템·너드킹 셔츠 리스트(3건)·살림 꿀템·
   어깨운동 루틴·트럼프 버블. 인스타릴스·유튜브가 추천한 구체 제품을 summary 가 모름 → 텍스트
   검색 불가. **원본 영상 URL 로 보내야 함**(검색 아니라 `PlatformContextTool` 영역, 사용자 "유튜브→원본" 직관).
2. **진짜 검색불가** — 품절(배스킨 토이스토리)·일반명사 브랜드(LUCIER 안경)·로컬 소상공인(모프 동탄).
   judge 가 옳게 버림(게이트 견고).
→ generic 키워드 개선 ROI 낮음. ROUTER_PROMPT 변경은 부작용 있어 **되돌림 검토**.

**비용(케이스당, 검색 도는 케이스 기준):** $0.001763. 단계별 judge(3.5-flash) 61% / route 25% /
critique 14%. 모델별 flash-lite $0.0138 + 3.5-flash $0.0215(20건 합 $0.035). 전체 캡처 평균은
none 34%(route 1회) 포함 시 더 쌈(추정 ~$0.0013/캡처). judge 가 비용 지배 → 비용 줄이려면 judge 모델·빈도.

**티어 랭킹:** useful 3건뿐(tier4 정보2/tier3 오픈마켓1, 원본일치0)이라 검증 빈약 — exp6 성공 47건으로 재검증 필요.

**시사점:** (a) 키워드 개선보다 "영상 캡처→원본 영상 URL 회수"가 실패의 큰 덩어리 해결(`PlatformContextTool`).
(b) 검색불가 패턴은 judge 가 잘 버리니 무리한 개선 말고 깔끔히 none. (c) 티어 랭킹은 useful 풍부한 셋으로.

### 라이브 baseline — app 정본 tool 2개 + 실스크린샷 39건 (2026-06-14, `agent-loop-resource-eval/results/baseline_20260614_025147.json`)

exp4~7(lab 자작 프롬프트, divergent)을 졸업하고 **app/ 정본에 tool 2개를 구현**해 메인 orchestrator 가
실제 스크린샷을 보고 부르는지 측정. divergence 0(프로덕션 `AgentOrchestrator`+`GeminiAgentClient`를
import only, 로컬 이미지 inline 주입). 데이터: 본인 계정 실스크린샷 39건(`lab/data/screenshot_prod/`).

**구현(브랜치 `feat/resource-finder-tool`):** ① `recoverYoutubeUrl`(결정적, 무키 youtube 검색→videoId→oEmbed,
PR#34 `recover_url` 정본) ② `findReferenceUrls`(exp5~7 loop: search(naver/tavily)→critique→judge→티어랭킹,
**키워드는 메인이 제공**). 배선: tools enum·registry(조건부)·gemini_agent_client·`system_prompts.py` v17→**v18**(# Tools 4-tool).

**baseline 수치(메인 자발 호출, 강제 안 함):**
| 지표 | 값 |
|---|---|
| finder 호출 | 16/39 (0.41), judge result_quality useful셋 **4.6**/5 |
| recover 호출 | 8/39 (0.21) — **유튜브 8건 전부 호출** |
| tool_choice (Claude judge, 이미지 보고) | correct 30 / miss 4 / wrong_tool 3 / unneeded 2 |
| recover 정확도 | 정확 3 / 빗나감·불확실 5 (평균 2.8) |
| none(tool 안 부름) | 카톡8·문자·일정·모찌 등 일관 — 과호출 거의 0 |

**검증된 것:** (가설1) 메인이 이미지 보고 두 tool 을 키워드/category 와 함께 자발 호출 ✅. (가설2) finder
반환 URL 품질 높음(상품명 명시 케이스 5점 반복). **none 게이트 견고**(외부자료 불필요 캡처 일관 분리).

**약점(다음 개선):**
1. **유튜브 댓글창에서 recover vs finder 혼동** — 댓글에 상품 링크(vo.la 등) 보이면 finder 가 맞는데
   recover 가 엉뚱한 채널 영상 반환(11·3·13). 채널명 명확해도 무키 검색이 빗나감. → "영상 본체 회수" vs
   "영상 속 상품 링크 회수" 명시 분기 + 댓글창 판단 로직.
2. **인스타 정보성에 platformContext 과호출**(19·26·32) — 32(남산 페스티벌 예약)는 finder("행사명+예약")가
   유용했을 케이스. 인스타=platformContext 단순패턴이 action-link 필요 사례를 놓침.
3. **finder local(장소) 커버리지 불안정** — 꽃집(27) useful=false, 맛집이 공식 SNS 만 반환(21). exp6 local 약점 재확인.

**불변식:** harness 프롬프트/스키마 리터럴 0(grep PASS). lint/typecheck green.

### v19 — codex 평가 반영 개선 + 재측정 (2026-06-14, `results/baseline_20260614_032128.json`)

v18 baseline + codex consult(IMPROVEMENT_PLAN.md) → 5개 수정: ① platformContext/webFetch 를
"실제 capture URL 있을 때만" 게이트 ② recoverYoutubeUrl channel_hint + 후보 oembed 채널 매칭 재랭킹
③ 댓글창 상품링크→finder·인스타 행사→finder 분기(프롬프트) ④ **critique loop 제거**(codex 가 잡은
"iter2 가 collected 덮어써 judge 가 마지막 검색만 보던 버그") ⑤ 입력 bound. + orchestrator 가
ValidationError 를 모델에 되먹임(malformed args 가 run 죽이던 것).

**v18 → v19 (Claude judge 비교, 바뀐 10건 이미지 재채점): improved 7 / regressed 2-3 / neutral 1**
- **개선**: 유튜브 댓글창 4건(11·13·3·35) recover 오호출(엉뚱 채널)→finder 상품검색(usefulness 5).
  인스타 platformContext 과호출 3건(19·26·32) 제거 — 26 none 정답, 32 남산 행사→finder(예약 의도 부합).
  tool_choice correct 30→**33** 추정.
- **새 회귀**: (a) **recover 채널 매칭 과엄격** — 15(따라cook/따라쿡)·16(codingapple/코딩애플) **한↔영 표기
  불일치로 recovered=false**, v18 맞던 게 깨짐. recover 정확 3/8 → **1/4**. → 다음: title 토큰 fallback
  또는 로마자 퍼지 매칭. (b) 0-카톡 webFetch — 화면 속 세션 url 로 호출(게이트가 프롬프트뿐이라 못 막음).
  (c) 4-야후 SOXL finder→none — 주가 화면 공식링크가 유용했는데 탈락.

**결론**: tool 선택 정확도는 순개선(correct +3), recover 호출은 8→4(댓글창이 finder 로 이동). 단 recover
채널 rerank 가 한/영 표기차에 과민 → 정확도 자체는 회귀. **다음 1순위: channel_hint 매칭 완화(title fallback).**

### 프로덕션 반영 (2026-06-13 완료, shopping_product 1차)

1. 분석 프롬프트: 쇼핑 캡처 한정 `entities(kind="shopping_product")` 산출 — specificity 는 별도
   필드 대신 프롬프트 게이트("검색 가능 수준 미달이면 생략")로 내장 (`system_prompts.py`).
2. 노출: entities 저장 경로 재사용(DDL 무변경) → `MochiItemResponse.shoppingProductQuery`
   projection → iOS Realm v9 미러 → 상세 "지금 할 수 있어요"에 쿠팡·네이버 행.
3. 사전 검증 서버 잡은 두지 않음 (쿠팡 간헐 403 이라 신뢰 불가, 검색 상태 링크는 dead-link 개념이 약함).

**남은 단계**: `results/exp2_links_*.md` 실기기 탭 확인 (쿠팡 앱 핸드오프 포함).
