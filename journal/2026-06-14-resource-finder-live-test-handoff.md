---
level: 3
mode: log
status: active
last_verified: 2026-06-14
confidence: 0.8
owners: [송준서]
title: 범용 ResourceFinder(이미지→참고 URL) 실험 exp4~7 + 라이브 테스트 설계 — Handoff
description: 쇼핑 카드 링크에서 출발해 "이미지→참고 가능한 URL 추출" 범용 tool 비전으로 확장한 하루. lab exp4~7(네이버+Tavily 백본·loop·실데이터 97건·비용·티어 랭킹)의 결론과, 다음 단계인 "실제 코드 라이브 테스트(divergence 0)" 설계까지. ResourceFinder 를 프로덕션 tool 로 올릴지 결정하기 전 반드시 읽어라.
---

# 범용 ResourceFinder — Handoff (2026-06-14)

## 0. TL;DR (한 화면)

- **무엇**: 쇼핑 카드 링크가 "검색만 하고 실재 확인 안 함" 발견 → **"이미지/기록 → 참고 가능한 좋은 URL 을 미리 찾아주는" 범용 tool** 비전으로 확장. (모찌 미션 "필요한 기억이 떠오른다" 의 회수 능력)
- **실험 4개(lab, 전부 실행·검증됨)**: exp4(범용 라우팅) → exp5(loop+Tavily 폴백) → exp6(**실데이터 97건**) → exp7(비용+개선+티어 랭킹).
- **핵심 수치**: 실데이터에서 검색 시도분의 **73% useful**(구체 상품일수록↑, 쇼핑후보 0.89), **캡처당 ~$0.0013**, judge(3.5-flash)가 **비용 60% 지배**.
- **가장 큰 깨달음**: 실패는 "키워드 문제"가 아니라 **"검색 대상의 부재"**. 큰 덩어리는 "영상 속 추천 리스트"(텍스트 검색 불가 → **원본 영상 URL 회수** 영역).
- **아키텍처 합의**: `recover_youtube_url`(규칙기반) + `find_reference_urls`(tool) **2분리**, 키워드 추출은 **메인 에이전트(이미지 본다)** 가, 미니는 **키워드 받아 검색**.
- **다음(미착수)**: **라이브 테스트** — 프로덕션 코드 그대로(프롬프트·구조 divergence 0)로 이미지→tool call 검증. (A) 길로 합의, doc-guardian/architect 선행 여부 **사용자 답 대기 중 세션 종료**.

---

## 1. 대화 흐름 — 어떻게 여기까지 왔는가

1. 어제 쇼핑 카드 favicon 저널 확인 → "쇼핑 아이템 어떻게 불러오나" 추적.
2. **발견**: 백엔드는 `shopping_product_query`(검색어 문자열)만 주고, **iOS 가 쿠팡·네이버 검색 URL 을 무조건 조립**. 실제 검색·존재확인 0. "있는지 확인하고 넣을지" 판단 없음. (`DetailView.swift` `ShoppingSearchProvider`)
3. 사용자: "검색 API → 추출 → 가져오기" 를 원함. + 올리브영 링크는 쇼핑 추천이 아니라 `primaryURL`(원본)임을 확인.
4. **쿠팡 직접 확인 = Akamai 봇차단 403** (단순 페칭 불가). → 네이버 쇼핑 검색 API 로 방향. 사용자가 키 발급.
5. 비전 확장: 쇼핑만이 아니라 유튜브·OTT·지도·정보 등 **범용 "참고 URL 회수"**. "tool 로 쓰는 sub agent".
6. **exp4**: 네이버 검색 API 가 shop/local/blog/news **단일 백본**임을 즉석 curl + 12케이스로 입증(routing_ok 1.0, found 1.0).
7. **exp5**: 단발 → **loop agent**(route→search→critique→judge) + **Tavily 웹 폴백**. 18 합성. 폴백이 해외 주제 구제(useful 0.44→0.61).
8. 사용자: "데이터 적다" → **프로덕션 DB(mochi-db VM, IAP SSH)에서 실데이터 97건 추출**(텍스트만). **exp6** 실행.
9. **exp7**: exp6 실패 20건 타겟 + **비용 측정(서버 `llm_cost`/`llm_usage` 재사용)** + generic 키워드 개선 + **액션티어 랭킹**. → 개선 net 0.
10. **아키텍처 재설계 논의**: ① youtube=별도 결정적 tool ② "원본"이 아니라 "참고" URL ③ 키워드는 메인(이미지)이 ④ 라이브 테스트는 프로덕션과 divergence 0 이어야.

---

## 2. 현재 코드 상태

**프로덕션(mochi-ios/mochi-backend): 무변경.** 이 세션은 전부 lab/ 실험.

변경된 파일 (모두 `lab/active/shopping-product-link/`):
- `exp3_naver_search.py` (작성, **미실행** — exp4 로 일반화되어 흡수)
- `exp4_universal_router.py` ✅ 실행 (`results/exp4_20260614_001841.json`)
- `exp5_resource_finder_loop.py` ✅ 실행 ×2 (Tavily 없이/있이: `exp5_*_003255`, `_003612`)
- `exp6_prod_data.py` ✅ 실행 (`exp6_20260614_010146.json`) — **실데이터 97건**
- `exp7_cost_refine.py` ✅ 실행 (`exp7_20260614_013315.json`) — 실패 20건
- `FINDINGS.md` 수정 (exp4~7 결론 전체 기록 — **다음 세션 첫 정독 대상**)
- `lab/data/mochi_items_prod.jsonl` (프로덕션 추출 97건, gitignore)

작동: 4개 실험 전부 end-to-end 실행됨. 실행 커맨드는 각 스크립트 docstring + FINDINGS.

---

## 3. codex 검증 결과

**없음.** 이 세션은 `lab-experimenter`(실험 작성)만 사용. 코드 리뷰/QA codex 게이트는 lab 실험이라 미적용. **라이브 테스트(app/ 실제 코드)로 가면 code-reviewer/qa-validator 필수.**

---

## 4. 결정 / trade-off (왜 이렇게 했는가)

- **네이버 검색 API 단일 백본** — 사이트별 어댑터(올영·무신사…) 폭발을 회피. `mallName`/도메인이 곧 분류 신호. shop/local/blog/news + Tavily(해외) 2-tier 면 대부분 커버.
- **loop 보다 함수에 가깝게** — exp5~6 에서 critique 재검색(refine)이 거의 안 돎(대부분 1 iter). loop ROI 낮음 → 키워드를 메인이 주면 미니는 "검색+judge+랭킹"만.
- **youtube = 규칙기반**(tool 아님) — 출처앱을 단축어가 보내주니 호출 여부가 명확. `recover_youtube_url`(무키 검색→videoId→watch URL)은 결정적 함수. (PR #34 / `lab/archive/youtube-enrich` 의 `recover_url` 재사용)
- **키워드 추출 = 메인(이미지) > 미니(summary)** — exp6~7 generic 실패("육아템 추천")의 **근본 원인**이 미니가 빈약한 summary 로 키워드 만든 것. 메인은 이미지를 보니 "무신사+쿠어 다운" 같은 정확한 검색 지시 가능.
- **라이브 테스트 = import only, 프롬프트 복제 0** — exp4~7 의 프롬프트는 lab 자작이라 프로덕션 `system_prompts.py` 와 divergent. 그래서 그 결과는 "방향성"이지 "프로덕션 정확도"가 아님. 진짜 라이브는 app/ 코드를 그대로 import.

---

## 5. 미완 결정 (사용자 선택 대기)

1. **라이브 테스트 착수 여부** — (A) doc-guardian → architect → app 구현(tool+배선) → lab harness → Claude judge. 마지막 질문("doc-guardian/architect 선행으로 갈까?")에 **답 받기 전 /handoff 로 세션 종료**. → 다음 세션이 이 결정부터.
2. **`find_reference_urls` 키워드 구조** — `[상품명 / 정확검색어 / 참고검색어]` 3종으로 줄지. (도깨비 예시: 정확→원본/커머스, 참고→블로그/OTT 정리)
3. **exp8(성공10 + 영상10)** — 사용자가 "고고" 했으나, 라이브 테스트로 방향 전환되며 보류. lab mock 으로 따로 남길지 vs 라이브로 흡수.
4. **critique loop 제거 여부** — ROI 낮으니 뺄지. (judge·티어 랭킹은 유지 가치)

---

## 6. 다음 단계 + 검증 기준 (러프 — 다음 에이전트가 의사결정)

> 큰 그림: "검색은 검증됨, 이제 **실제 코드에 tool 로 올려서 메인이 진짜 부르는지** + **Claude judge 로 품질**" 단계.

- **라이브 테스트 (A) 착수 결정.** 가면:
  - doc-guardian: agent tool 계약(`DOMAIN_DESIGN`/`ARCHITECTURE`) 정합성 스캔.
  - architect: `find_reference_urls` Tool 인터페이스 + `system_prompts.py` 배선 지점 설계.
  - 구현(app/, 정본): tool(검색·랭킹·프롬프트) + `registry.py` + `gemini_agent_client.py`(`_function_declarations` 하드코딩이라 분기 추가) + `system_prompts.py`(tool 호출 지시) + `recover_youtube_url`.
  - lab harness(import only): `agent-loop-live` 패턴 + 로컬 스크린샷 주입 → 실제 loop → tool call 로그.
  - **Claude 서브에이전트 judge** (gemini 아님).
- **검증 기준**:
  - (가설1) 메인이 이미지 보고 `find_reference_urls` 를 **키워드와 함께 실제로 호출**하는가.
  - (가설2) 반환 URL 이 **Claude judge** 통과하는가.
  - (불변식) lab harness 에 **프롬프트/스키마 리터럴 0** — grep 으로 divergence 0 기계 확인.
- **곁가지 (값싸게 먼저 볼 수 있는 것들)**:
  - judge 를 **flash-lite** 로 — 비용 60% 지배분 절감 가능한지(품질 유지되는지).
  - 티어 랭킹 **useful 풍부한 셋(exp6 성공 47)** 으로 재검증 — exp7 은 useful 3건이라 무의미했음.
  - **출처앱 메타 위치 확정** — youtube 규칙기반의 전제. 이 세션에서 미확인(`channel` 은 screenshot/instagram/… 인데 "youtube" 출처가 어디 실리는지 불명). ingest 경로 + ShareExtension 단축어 payload 봐야.

---

## 7. 컨텍스트 부채 (다음 세션이 먼저 봐야 할 것)

1. **`lab/active/shopping-product-link/FINDINGS.md`** — exp4~7 결론 전체. **첫 정독.**
2. `lab/active/agent-loop-live/agent_loop_live_test.py` — 실제 loop(`GeminiAgentClient`+`AgentOrchestrator`+`FakeGateway`) 실행 패턴. 라이브 harness 의 뼈대.
3. **PR #34 `lab/capture-url-recovery`** + `lab/archive/youtube-enrich/image_context_bench.py` — `recover_url`(youtube 링크 따오기) 정본. develop 에 이미 있음(통째 머지 불필요, 함수만).
4. mochi-backend agent loop: `application/orchestrator.py`(tool 주입·loop), `infrastructure/gemini_agent_client.py`(**`_function_declarations` 가 tool 별 하드코딩** — 새 tool 은 app 수정 불가피), `infrastructure/registry.py`, `prompts/system_prompts.py`(classify_and_act@v17), `infrastructure/tools/`(WebFetch·PlatformContext = 기존 tool 본).

### ⚠️ 남들이 놓치기 쉬운 디테일 (사용자 명시 요청)

- **쿠팡 = Akamai edge 봇차단(403).** 단순 HTTP·UA 변경으로 못 뚫음. exp2(이전 세션)의 "쿠팡 18/20 200" 은 **쿼리마다 200/403 갈리는 간헐 통과**라 신뢰 불가. 헤드리스도 프로덕션 매요청엔 부적합.
- **네이버 검색 API = 한 키로 shop/local/blog/news 멀티 도메인.** `mallName`(올리브영/쿠팡/…)이 곧 **액션티어 신호** → 도메인 파싱 없이 룩업. (티어: 공식>편집샵>오픈마켓>직구>가격비교>정보, 원본일치 예외)
- **exp4~7 프롬프트는 lab 자작 = 프로덕션과 divergent.** 결과는 "방향성"이지 "프로덕션 정확도" 아님. **라이브는 반드시 app import only.** 이걸 안 지키면 라이브가 또 다른 mock 이 됨.
- **judge(3.5-flash)가 비용 60% 지배.** 비용 줄이려면 VM/검색이 아니라 judge 모델·빈도부터.
- **실패의 본질 = 키워드 아님.** "영상 속 추천 리스트"(인스타·유튜브가 추천한 구체 제품을 캡처가 모름)는 텍스트 검색으로 영영 못 찾음 → **원본 영상 URL 회수**가 답. 키워드 튜닝(exp7) ROI ≈ 0.
- **게이트(judge useful)는 견고.** 못 찾을 건 안 보여줌(none 34% + suppressed). "혹시 이거?" 신뢰의 핵심 — 무리해서 살리지 말고 깔끔히 none 이 맞을 때가 많다.
- **이미지 입력 우회 필요.** loop 는 이미지를 `image_object_keys`(GCS)로 받음. lab 로컬 스크린샷은 gateway/fetch 경로를 mock 해야 들어간다.
- **`recover_url` 무키 youtube 검색은 데스크톱 UA 필수**(모바일 UA 는 `ytInitialData` 미포함). 그리고 **데이터센터 IP(Cloud Run)에서 차단 가능** — PR #34 `cloud_ip_check` 가 그 게이트(로컬은 PASS).

---

**다음 세션 첫 30분 추천 동선**: FINDINGS.md 정독 → 이 handoff §5(미완 결정)·§6(다음 단계) → 라이브 테스트 (A) 갈지 사용자에게 재확인 → 가면 doc-guardian 부터.
