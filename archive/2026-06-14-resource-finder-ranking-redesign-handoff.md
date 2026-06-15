---
level: 3
mode: handoff
status: active
last_verified: 2026-06-14
confidence: 1.0
owners: [송준서, 이용찬, 박세현]
description: ResourceFinder(findReferenceUrls) 랭킹 재설계 세션 인수인계 — "지도/예약 overfit" 해소 + judge 위임 전환 + codex P1 수정. 다음 세션이 0부터 이어받을 컨텍스트.
---

# ResourceFinder 랭킹 재설계 — Handoff (2026-06-14)

> 브랜치 `feat/resource-finder-tool` (미머지). 이 세션은 이미 살아있던 findReferenceUrls tool 의
> **랭킹/프롬프트 품질**을 사용자 리포트 기반으로 재설계했다. tool 배선·iOS 영속화는 이전 세션 분.

---

## 0. TL;DR (한 화면)

- **무엇**: `findReferenceUrls`(ResourceFinder) 의 결과가 **네이버지도/예약에 overfit** 돼 있었고, 호출율이 낮았다. 이를 ① synthetic 계급 분리 ② URL별 bucket-quota 랭킹(액션+참고 믹스) ③ 동일성 판단을 룰→**judge 위임** ④ 프롬프트 호출 완화 로 재설계했다.
- **검증**: 네이버/Tavily 직접 호출 + 20건 LLM-judge(서브에이전트). relevance 4.30→**4.80**, action 4.06→**4.69**, diversity 3.95→**4.55**. 단위 9/9·lint·typecheck green.
- **codex 구조+프롬프트 리뷰**: P1 6건 발견 → **명백한 4건 수정 완료**, **2건(설계 trade-off)·P2 6건 미반영**.
- **상태**: 코드 작동함. **커밋 안 함.** 머지 전 정합성 폭포(아래 §7)·iOS 3종 카드 1종 확정 남음.
- **다음 첫 액션**: §6 의 "judge schema per-URL 전환" 결정부터. 이게 usefulness 단일값 문제 + iOS isExactMatch 까지 닿는 가장 큰 잔여 항목.

---

## 1. 대화 흐름 — 어떻게 여기까지 왔는가

1. **사용자 리포트 2건** (이 세션의 출발점):
   - 페이먼트(예약) 호텔 캡처 → 네이버지도 링크가 왔는데 **검색어에 "예약"이 박힌 깨진 링크**("리치몬드호텔 야마가타 에키마에 예약"으로 지도 검색).
   - 네이버지도 스크린샷("양은이네 신대방삼거리역직영점") → **reference_link 가 아예 안 옴**. "실험할 땐 잘 됐는데 왜?"
2. **추측 대신 직접 실험** (사용자가 "툴 호출을 너무 안 한다"고 명시 지적 → 직접 네이버/Tavily API 호출):
   - 일본 호텔은 네이버 local 검색이 **항상 0건**(예약 유무 무관) — 내 첫 추측("예약이 검색을 깨뜨린다")은 **틀림**.
   - 진짜 원인: `_synthetic_items` 가 검색 0건에도 네이버지도 검색 URL 을 **무조건 합성**해 tier1 으로 1위. / 양은이네는 tool 은 정상(지도 1위), **메인이 호출 안 한 것**.
3. **codex 설계 토론** (사용자 요청): overfit 근본 = synthetic 무조건 생성 + 액션티어 고정. codex 가 내 잠정안(returned>0 가드)을 넘어 "계급 분리 + URL별 bucket quota + 동일성은 judge 에" 제시.
4. **3단계 구현 + 20건 LLM-judge**: 4.5+ 달성. 하지만 judge 가 #6 노티드(엉뚱한 가게)·#13 로지텍(액세서리) 오인을 지적.
5. **사용자 핵심 지적 (중요)**: 내가 #13 을 잡으려 `_ACCESSORY_TOKENS`(스킨/스티커/그립…) **절대 blocklist** 를 넣자, 사용자가 *"아예 오버핏한 환경으로 바꾼 거 아니야? 누군가 진짜 액세서리(스킨/스티커/그립톡)를 캡처하면?"* → **정확한 지적**. 룰 blocklist 제거하고 **judge 위임**으로 전환.
6. **codex 구조+프롬프트 리뷰** (사용자가 권한문제로 1차 종료 후 재실행, 웹검색 제외): P1 6건. 명백한 4건 수정.

---

## 2. 이 기능이 왜 중요한가 (다음 세션이 절대 잊으면 안 되는 것)

**모찌의 미션: "놓치기 쉬운 순간은 쉽게 남기고, 필요한 기억은 쉽게 떠오른다." 회수의 능동 주체는 사용자가 아니라 모찌다** (`docs/PRODUCT.md` §1.5, `CLAUDE.md` §1).

findReferenceUrls 는 이 미션의 **회수(능동) 축의 핵심 기능**이다 — 사용자가 맛집·상품·장소·정보를 캡처해두면, 나중에 다시 봤을 때 모찌가 알아서 **"바로 액션할 링크(지도/예약/구매) + 참고할 유용한 자료(리뷰/영상/큐레이션)"** 를 떠올려준다. 사용자가 직접 다시 검색하게 만들면 미션 위반.

그래서 이 세션의 두 가지 실패 모드는 **둘 다 미션 직격**이었다:
- **overfit(지도/예약만 도배)** → "참고할 유용한 자료"를 못 떠올림. 사용자가 직접 찾아야 함.
- **호출 안 함 / 엉뚱한 링크** → 회수 자체가 실패하거나 신뢰를 깸("혹시 이거?"가 틀리면 안 봄).

**사용자가 원하는 출력 형태(명시)**: *"바로 액션할 수 있거나, 참고할 만한 유용한 자료를 잘 응답 — 지도·네이버 예약 뿐만 아니라."*

---

## 3. 사용자가 이 세션에서 계속 지적한 것 (다음 세션도 같은 기준으로)

1. **"툴 호출을 너무 안 한다"** → 추측·텍스트 분석만 하지 말고 **직접 실험(API 호출/스크립트)으로 검증**하라. 이 지적 후 probe 스크립트로 모든 가설을 실측했다.
2. **"장소/지도에 overfit 된 것 같다"** → 한 종류(지도/예약)로 top3 를 도배하지 마라. 액션+참고 믹스.
3. **"아예 오버핏한 환경으로 바꾼 거 아니야? 진짜 액세서리 캡처하면?"** → **특정 케이스를 잡으려 룰을 하드코딩하지 마라**(skill-creator 의 fiddly-overfit 경고). 의미 판단은 LLM(judge)에 위임. → 이게 `_ACCESSORY_TOKENS` blocklist 제거의 직접 계기.
4. **"skill 처럼 보고 최상급 tool 로"** → skill-creator 철학 적용(description=트리거, pushy, 기준+why, 예시 나열 금지).
5. **handoff 는 디테일하게** → 본 문서.

**관통하는 원칙: 룰 하드코딩 < LLM 위임 / 추측 < 실측 / 특정 예시 overfit < 일반 기준.**

---

## 4. 현재 코드 상태 (작동 가능 + 변경 파일)

작동함. 단위 9/9·`make lint`·`make typecheck`(153파일) green. **이 세션이 실제로 건드린 파일**(diff 의 나머지는 이전 reference_url 영속화 세션 누적분):

- `mochi-backend/app/modules/agent/infrastructure/tools/resource_finder.py` — **핵심**. 검색/judge/랭킹 재설계.
- `mochi-backend/app/modules/agent/prompts/system_prompts.py` — findReferenceUrls 설명 V19→**V20**, judge 와 무관(메인 프롬프트). `ACTIVE_PROMPT.name` v20.
- `mochi-backend/app/modules/agent/infrastructure/gemini_agent_client.py` — RESOURCE_FINDER function declaration description 동기화.
- `mochi-backend/tests/unit/test_resource_finder_ranking.py` — 9 테스트(강등·다양성·정규화·액세서리 생존·noise).
- `docs/CHANGELOG.md` — 항목 추가.
- `lab/active/shopping-product-link/` — `probe_naver_local.py`/`probe_tool_e2e.py`/`probe_places.py`/`probe_accessory.py`/`eval_20cases.py` 신규(실험 재현용).

### 핵심 함수 지도 (resource_finder.py)
- `_observed_items` (visible/original, 항상) vs `_fallback_search_items(payload, place_confirmed)` (네이버지도·쿠팡 검색URL — `place_confirmed`=네이버 local 매칭 OR 캐치테이블 `ct/shop` 발견 일 때만).
- `_search_plan(payload, query)` — local/event_booking 에 `{q} 캐치테이블 예약` webkr 변형.
- `_bucket(provider)` → observed/primary_action/official/reference. `_QUOTA_ORDER` + `_select_diverse` (observed 우선 → 선호 bucket 한칸씩 → provider 다양성 2-pass → score 정렬).
- `_rank_results` — picked 를 `_dedupe_key` 정규화 비교. **picked 안 된 primary_action 은 reference 로 강등 + role/label/tier 까지 "관련 링크 보기"로** (codex P1). 합성링크는 예외. `picked=[]` 면 강등 안 함(← trade-off, §5).
- `_profile_score` = `_base_profile_score` + `_synthetic_penalty`(+0.3).

---

## 5. codex 검증 결과 (구조+프롬프트 리뷰, gpt-5.5 high)

전체 원문: 이 세션 codex consult 출력(`/tmp/codex-mochi-review2-out.txt`, 휘발성 — 핵심은 아래). **P1 6건 중 4건 수정, 2건 미반영.**

### ✅ 수정한 P1 (4건, 검증 완료)
1. **강등이 출력에 반영 안 되던 버그** — `bucket` 만 reference 로 바꾸고 `provider/role/label/tier` 는 그대로라, judge 가 거부한 액션이 화면엔 여전히 "쿠팡에서 보기"/"예약" CTA 로 나갔다. → 강등 시 `role="reference"`, `label="관련 링크 보기"`, `tier=4.0` 까지 낮춤. **e2e 로 노티드의 `schedule_cheongdam` 이 "예약"→"관련 링크"로 격하 확인.**
2. **`ACTIVE_PROMPT.name` v19→v20** (rationale 만 V20 이라 운영로그/평가추적 틀어짐).
3. **picked raw string 비교** → `_dedupe_key` 정규화 + judge 프롬프트에 "link 그대로 복사" 명시.
4. **judge `_render` 에 구조필드 누락** → mallName/lprice/brand/category/주소 추가(동일성 판단 근거).

### ⏳ 미반영 P1 (2건 — 설계 trade-off, §6 다음 단계)
- **P1: `useful=true` + `picked_urls=[]` 면 모든 primary_action 이 살아남는다.** 현재 `picked=[]` 면 강등을 끄게 했다(다양성 보존 의도). codex 는 "정확한 pick 0개면 primary 승격 금지 또는 빈 결과"를 권고. judge 가 보통 픽하므로 드문 경로지만, 위임 일관성엔 구멍.
- **P1(프롬프트): `useful`/`usefulness` 가 후보 전체 단일값** → "상위 1개만 정확, 나머지 잡음"을 표현 못 함. `usefulness` 5 가 **3개 `reference_entities` 에 공통 복사**되어 iOS `isExactMatch`(usefulness≥5)가 3장 동시 점등. codex 권고: judge schema 를 `items:[{url, exact_target, value_score}]` per-URL 판정으로.

### ⏳ 미반영 P2 (6건)
- quota 후 최종 score 재정렬이 bucket order 의도를 흐림.
- `place_confirmed` 가 broad query/동명이점에서 false positive → 지도 fallback 부활 가능. (fallback 을 judge 이후 생성 권고)
- catchtable `ct/shop` 확인이 searches 전체 재순회 — search result 에 backend/category 메타 남기면 명확.
- `origin(observed/fallback/search)` / `provider` / `backend` 가 `source` 문자열에 섞여 if-chain 헷갈림.
- **이중 점수체계**: `_classify_tier`/`_legacy_score` (tier) 와 `_bucket`/`_profile_score` 가 공존 — 같은 URL 의 "좋음"을 두 언어로 말함. iOS 가 `tier_label` 안 쓰면 제거.
- 메인 프롬프트에 **negative gate 부재**(과호출 위험): 개인로그/영수증/채팅/이름 없는 분위기 캡처/너무 넓은 추천어는 호출 말라.

---

## 6. 다음 단계 + 검증 기준

우선순위 순. 각 항목은 "왜"가 §5 codex 근거에 있다.

1. **[가장 큼] judge schema per-URL 전환** — `_FinalJudge.picked_urls(list[str])` → `picks: list[{url, exact_target: bool, value: int}]`. usefulness 를 URL별로 → `reference_entities` 의 usefulness 가 링크별이 됨.
   - **정합성 폭포 주의**: `ResourceFinderOutput.reference_entities`(JSON) → 백엔드 `repository._reference_links` → `ReferenceLinkResponse.usefulness` → **iOS `ReferenceLink.usefulness` / `isExactMatch`**(`ReferenceLinkCards.swift`). API 계약(openapi)은 안 변하지만(usefulness 필드 이미 있음) 의미가 "전체"→"링크별"로 바뀜.
   - 검증: 20건 LLM-judge 재실행, "딱 맞아요" 뱃지가 1장만 켜지는지.
2. **picked=[] 엣지 결정** — judge 가 useful=true 인데 0개 픽하면 primary 승격 금지할지. 결정 후 테스트 추가.
3. **negative gate 추가**(메인 프롬프트) — 과호출 방지. 단 eval_dataset 영향 → V20→V21, 라이브 재측정.
4. **이중 점수체계 정리** — `tier_label` 을 iOS 가 쓰는지 확인 후 `_legacy_score`/`_classify_tier` 제거 여부 결정.
5. **iOS 3종 카드 1종 확정** — `ReferenceLinksComparison`(A/B/C 동시 렌더, 임시) 에서 승자 1개만 ② 섹션에 합치고 둘 제거. (이전 세션 TODO, 실데이터 비교 필요)
6. **남은 LLM-judge 누수**: #14 소니(구매 슬롯 0 — electronics 에 buy 보장), #9 마뗑킴/#12 다우니(SKU/브랜드 정밀도), #4 양은이네(지점 매칭). 4.5+ 위의 미세조정.

**머지 전 필수**: `/ship backend` (lint+typecheck+OpenAPI 단일계약+CHANGELOG) + 정합성 폭포(§7) 확인.

---

## 7. 컨텍스트 부채 (다음 세션이 먼저 봐야 할 것)

- **읽기**: 이 문서 → `lab/active/shopping-product-link/FINDINGS.md`(실험 전사) → `resource_finder.py` 핵심 함수(§4 지도) → `docs/CHANGELOG.md` 최신 2항목.
- **실험 재현**: `cd mochi-backend && uv run python ../lab/active/shopping-product-link/probe_accessory.py` (액세서리 생존+노티드 강등) / `eval_20cases.py`(20건 → `results/eval_20cases.json`, 서브에이전트 LLM-judge 로 채점). 네이버/Tavily/YouTube 키는 `mochi-backend/.env` 에 설정됨(env-inspect 로 확인).
- **정합성 폭포 (미반영, 머지 전)**: 직전 handoff(`2026-06-14-resource-finder-live-test-handoff.md`)가 남긴 **"프로덕션 DOMAIN/ARCHITECTURE/PRIVACY tool 산출물 영속화 미반영"** 이 여전히 유효. reference_url 영속화는 이미 됐으나 상위 설계문서 동기화가 남았을 수 있음 — `doc-guardian` 로 스캔 권장.
- **커밋 안 됨**: working tree 에 이번 변경 전부 unstaged. 커밋·푸시는 사용자 지시 대기.
- **judge 모델**: `gemini-3.5-flash`(비용 지배분, 주석에 "flash-lite 검토" 표시). picked 가 이제 랭킹 핵심 신호라 모델 강등 시 picked 안정성 재측정 필요.
- **주의**: `ResourceFinderTool` docstring 이 아직 "search→critique→judge" 라고 쓰여 있으나 critique loop 는 이전에 제거됨. 사소한 문서 drift(다음에 정리).
