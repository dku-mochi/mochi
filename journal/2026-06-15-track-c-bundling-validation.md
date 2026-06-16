---
level: 3
mode: log
status: draft
last_verified: 2026-06-15
confidence: 0.8
owners: [송준서]
title: 트랙 C 주제 묶음 — 구현 방향 결정 + 실데이터/LLM 실험 (사고 변천 로그)
description: 능동 회수 트랙 C(맥락 회수)의 "주제 묶음"을 어떻게 구현할지 결정한 토론·실험 로그. Claude의 "클러스터링 불필요" 주장이 실데이터로 두 번 뒤집힌 과정과, 최종 설계(embedding prefilter→LLM sliding-window batch+label-ANN 소생)를 실데이터 103개 + 실제 flash-lite 실험으로 검증한 결과를 담는다. 트랙 C 묶음·카테고라이징·클러스터링·weekly digest 통합을 구현하기 전 읽어라. 미승인. 선행 문서: 2026-06-15-proactive-recall-design.md(기획)·-tech-design.md(기술). 실험 코드: lab/proactive-recall-bundling/.
---

# 트랙 C 주제 묶음 — 구현 방향 결정 + 실데이터 검증 (2026-06-15)

> 코드 변경: `mock`(홈 통합 디자인 — FeatureInbox에 임시 mock) + `lab/proactive-recall-bundling/`(실험) 만. 프로덕션 백엔드/문서 정합 반영은 아직(§10). CHANGELOG 미추가(실험·설계 단계).

---

## 0. TL;DR

능동 회수의 **트랙 C "관련 기억 모음"(주제 묶음)을 무엇으로 만드나**를 결정했다. 결론이 **두 번 뒤집혔고**, 그 과정 자체가 이 문서의 핵심이다.

1. Claude: "이미 category가 있으니 **클러스터링 불필요, `GROUP BY category`**" →
2. 실데이터: category가 coarse("쇼핑 21")라 fine 묶음 안 됨 → Claude: "entity 정규화 필요" →
3. 송준서: "클러스터링 한번 해봐" → embedding 클러스터링이 fine 군집(유니클로·헨리넥·야마가타)을 **자동으로 잘 잡음** → Claude의 "불필요" 주장 반박됨 →
4. 송준서: "그럼 **3개마다 LLM batch(sliding-window)로 entity 묶음을 지속 업데이트**하는 게 낫지 않나" → Claude 동의 + embedding prefilter·label-ANN 보강 →
5. lab 실험(실제 flash-lite 103콜): **설계 골격 검증**, 한계 2개(헨리넥 과분할·규모) 노출.

**확정 설계**: `embedding prefilter(top-k) → LLM sliding-window batch(기존 라벨 시드) → label-ANN 소생`. 순수 클러스터링/임계 단독은 금지(실증). 묶음은 회수의 *보조* 표면, 신규 유저 주력은 단건(트랙 A/B).

---

## 1. 어디서 출발했나

선행: `…-proactive-recall-design.md`(3트랙 기획)·`…-tech-design.md`(Claude×codex 3턴). 트랙 C(아카이브형 = 맥락 회수)의 MVP 중 **"관련 기억 모음"**을 홈에 어떻게 보여줄지 디자인하다가(mock의 `CollectionScreen`), "그럼 이 묶음을 **시스템이 무엇으로 만드나**"가 미해결로 남아 이 토론이 시작됐다.

직전 결정(A안): weekly digest("이번 주 회고")와 트랙 C(주제 묶음)를 **하나의 "모찌가 모아뒀어요" 패러다임**으로 통합(시간 축 + 맥락 축). 이때 **fine/coarse category를 둘 다 보존**하기로 함(weekly가 fine을 coarse로 덮어쓰면 트랙 C가 깨지므로).

---

## 2. 사고 변천 — 왜 결론이 두 번 뒤집혔나 ★

이 문서에서 가장 중요한 부분. **송준서 제안과 Claude 응답이 데이터를 만나 어떻게 교정됐는가.**

### 라운드 1 — Claude: "클러스터링 불필요"
- **송준서 생각**: "묶음은 클러스터링을 써야 하나? 임베딩은 이미 되어있는데."
- **Claude 생각**: 클러스터링은 *라벨이 없을 때* 군집을 발견하는 비지도 방법인데, 우리는 저장 시 LLM이 이미 `category`를 붙여뒀다 → 라벨이 있으니 `GROUP BY category`면 끝. 클러스터링은 *이미 가진 라벨을 버리고 비싸게 재발견*하는 셈. → **"클러스터링 불필요."**
- 이때까지는 논리적으로 옳아 보였다.

### 라운드 2 — 실데이터가 반박 (1차 뒤집힘)
- **송준서 생각**: "실제 내 DB 데이터로 진짜 되는지 확인해봐."
- DB에서 송준서 계정(106 items) 추출. **category 분포가 전부 coarse**였다: 일상 32·쇼핑 21·학업 11·맛집 9·투자 6. → `GROUP BY category` 하면 "쇼핑 21"이라는 거대 버킷만, mock의 "유니클로/무선 마우스" 같은 **fine 묶음이 안 나온다.**
- 원인: weekly digest가 fine→coarse로 정규화하며 fine을 **덮어썼다**(75/106 정규화됨). → "fine/coarse 둘 다 보존" 결정이 *필수*임이 실증.
- **Claude 교정**: "category GROUP BY로는 안 된다. fine 재료는 `shopping_product` entity에 있다(유니클로 5·헨리넥 3·제습기 2·PDRN 3·야마가타 3). 단 value 파편화로 exact GROUP BY 불가 → **entity 정규화 필요**."
- 또 발견: **screenshot이 88/106(83%)**. tech-design §3.3의 channel allowlist가 screenshot을 *뺐는데*, 빼면 트랙 C 대상이 106→18로 붕괴 → **sensitivity 필드 구현이 "선택"이 아니라 진짜 blocker**(codex 경고가 데이터로 입증).

### 라운드 3 — 클러스터링 실험 (2차 뒤집힘)
- **송준서 생각**: "그럼 이 데이터로 클러스터링 한번 해봐. 임베딩 이미 되어있는 거 써서."
- 103개 embedding(Voyage 1024d) L2 정규화 후 KMeans/Agglomerative/HDBSCAN.
- **결과: embedding 클러스터링이 fine 군집을 자동으로 잘 잡았다.** k=20: 유니클로 5(C9)·헨리넥(C8)·야마가타(C7)·투자(C0). HDBSCAN(k 불필요): 투자·주거·헨리넥·야마가타·Claude학업을 자동 분리 + **추출실패 더미("https://kkk")를 따로 격리**(보너스) + 1회성은 noise(28/103).
- **Claude 교정(정직)**: "내 '클러스터링 불필요' 주장이 틀렸다. 그건 fine category가 보존됐을 때의 이상론이고, **현실 데이터(coarse category + 파편 entity)에선 embedding 클러스터링이 fine 묶음의 실질적 정답**이다. 송준서 직관이 옳았다."
- 세 방법 판결: `category GROUP BY`(❌ coarse) / `entity GROUP BY`(❌ 파편) / **`embedding 클러스터링`(✅)**.

### 라운드 4 — 송준서: LLM batch가 더 낫다
- **송준서 생각**: "어쨌든 3개마다 batch는 이미 하고 있었잖아. LLM이 *신규 3개 + 이전 10개 + 예전에 묶은 것들*을 보고 entity 기반 카테고라이징을 **지속 업데이트**하면 좋지 않나? 클러스터링 vs 이 batch(window sliding)?"
- **Claude 생각**: 이게 **클러스터링보다 낫다.** 본질은 "LLM을 증분 클러스터링 오라클로 쓰는 것". 클러스터링의 3대 약점을 한 번에 해결:
  - **명명 따로** → LLM은 묶으면서 동시에 이름("유니클로").
  - **의미 못 봄** → LLM은 "브론슨 자켓 ≠ 헨리넥"을 안다(수치 클러스터링은 섞음).
  - **비결정 재계산** → 신규만 기존 라벨에 배정(증분), 기존 라벨 이어받아 안정.
  - 게다가 **이미 있는 batch 패턴**(profile refresh, weekly digest)의 확장 → 새 인프라 최소. 송준서가 줄곧 짚은 "weekly batch 비용을 fine 묶음 유지로 전환"이 여기서 완성.
- **Claude 보강**: 순수 LLM은 라벨이 수백 개가 되면 컨텍스트 폭발 → **embedding prefilter**로 관련 라벨 top-k만 LLM에 시드. 즉 *embedding=후보 좁히기(recall, 싸다) / LLM=묶음 판단·명명(precision, 의미)* 하이브리드.

### 라운드 5 — 송준서: 세 운영 문제
§6 참고. 배치 지연/중요단건, cold start, 라벨 희미해짐.

---

## 3. 실데이터 검증 (DB 106 items, 송준서 계정)

| 항목 | 값 |
|---|---|
| 타깃 owner | 71503fa8…(106 items, 2위 40개와 큰 격차) |
| category(coarse) | 일상 32·쇼핑 21·학업 11·맛집 9·투자 6·주거 4 … |
| 정규화 비율 | 75/106(70.8%) — weekly digest가 fine을 coarse로 덮음 |
| entity kind | reference_url 43·shopping_product 27·deadline 18·ticker 8 … (한글/영문 혼재: place/장소명/장소) |
| channel | **screenshot 88(83%)**·appShareSheet 10·chat 4 … |
| intent_type | memo 80·todo 24·schedule 8·knowledge 6 |
| fine 재료(entity) | 유니클로 5·헨리넥 3·제습기 2·PDRN 3·야마가타 3 |
| 데이터 품질 | summary 더미("https://kkk") 존재, value 파편화 |

> 접근: INFRA.md 기준 db VM IAP SSH → `docker exec mochi-pg psql`(5432 직접 IAP는 방화벽에 막힘). read-only SELECT만. raw는 `/tmp/mochi_recall_check/`.

---

## 4. 클러스터링 실험 결과 (baseline)

- KMeans: k=8 coarse("쇼핑 14" 한 덩어리) → k=20 fine(유니클로/헨리넥/야마가타/투자 분리). silhouette 0.17→0.24(군집 구조 약함).
- **HDBSCAN(min_cluster_size=2)**: 24 clusters, noise 28/103. fine 자동 + 더미 격리 + 1회성 noise. k 불필요라 가장 적합.
- 결론: embedding 클러스터링은 fine을 잡지만 (1) k/임계 결정 (2) 군집 명명 별도 (3) 비결정 재계산이 약점 → 이게 라운드 4의 LLM batch로 이어짐.

---

## 5. 확정 메커니즘 (라운드 4 결론)

```
새 저장 N개 → batch 트리거(flush: count≥3 OR 경과시간>T OR importance 높음)
  embedding prefilter: 새 item embedding → 관련 라벨 top-k 소환(ANN)
  LLM 입력: 신규 N + 최근 window M + 소환된 관련 라벨(=예전 묶음 시드)
  LLM 출력: 각 신규를 기존 라벨에 배정 OR 새 라벨 생성(+명명)
  → 묶음 라벨 테이블 증분 업데이트(centroid 갱신)
라벨 = 영속 + 임베딩 인덱싱(window 밖에서도 ANN 소생)
오프라인 월1회: 클러스터링으로 라벨 체계 병합·정돈(역할 분담)
```

---

## 6. 세 운영 문제와 해법 (송준서 제기)

### 6.1 배치 지연 + 중요 단건
- **문제(송준서)**: 3개마다 batch인데 큐에 1개만 있고 그게 중요하면?
- **해법(Claude)**: **batch는 "회수 트리거"가 아니라 "묶음 라벨 정비" 주기**다. 분리하라.
  - 회수 트리거(1:1 관련·일정·지식) = **저장 즉시**(1개도 OK, embedding ANN).
  - 묶음 라벨 정비 = batch(지연 무방).
  - 큐 stale 방지: flush = `count≥3 OR 경과시간>T OR importance 높음`(현재 profile refresh는 count만이라 timeout 추가 필요).

### 6.2 Cold Start (처음 N개 미만)
- **문제(송준서)**: 처음 3개/10개 미만 유저는 묶음이 안 돼 초기 이탈.
- **해법(Claude)**: **회수의 첫인상을 묶음에 걸지 마라.** 묶음은 2개+ 필요해 초기엔 불가.
  - 초기 가치 = 단건으로 작동하는 트랙: 저장 직후 즉각 분석 피드백 + 일정 D-1(트랙 B) + 지식 spaced(트랙 A).
  - 묶음 임계 낮게(2) + 점진 발현(하드 게이트 "10개 모이면" 금지).

### 6.3 예전 라벨 희미해짐 (드리프트/소멸)
- **문제(송준서)**: window sliding이면 오래된 라벨이 밀려나 잊힘.
- **해법(Claude)**: **라벨을 window에서 떼어내라.** 라벨 영속 + 임베딩 인덱싱 → 새 item과 가까운 라벨을 ANN으로 소환(window 밖이어도). decay하되 소생, 비슷한 라벨은 오프라인 병합.

---

## 7. lab 실험 결과 (실제 flash-lite 103콜)

`lab/proactive-recall-bundling/`(common.py + exp_a/b/c + RESULTS.md). LLM: `gemini-3.1-flash-lite`(global), ADC. B/C는 구조 측정이라 ground-truth 오라클.

| 실험 | 핵심 수치 | 판정 |
|---|---|---|
| **A — LLM 묶음** | 6 주제 중 5개 purity 1.0, 더미 0.83. **헨리넥만 브랜드별 4 싱글톤 과분할** | 부분 지지 |
| A — 규칙 대안 | cosine≥0.62가 **93개 magnet 붕괴**(Voyage median cos 0.56) | 순수 임계 단독 불가 |
| A — 분리가능성 | 대부분 θ≈0.84로 분리 가능, **헨리넥만 intra-min 0.67 < cross-max 0.83** | 의미판단(LLM) 필요 실증 |
| **B — cold start** | 첫 묶음 ~20번째 item, 103개에서 회수가능 **20%** | 한계 정량화 |
| **C — 라벨 소생** | 분산 배치 시 window-only **21 라벨** vs **label-ANN 6(=정답), 중복 0** | **강하게 지지** |

**해석**:
- **C(label-ANN 소생)가 가장 단단한 근거** — §6.3 해법이 구조적으로 작동(21→6, 중복 제거).
- **순수 클러스터링/임계 단독 금지 확정** — Voyage 공간이 전반적으로 가까워(median 0.56) 임계가 magnet 붕괴. LLM 의미판단 필수.
- **정직한 한계 2개**:
  1. **헨리넥 과분할** — LLM이 "헨리넥 티셔츠"(브랜드 횡단 회수 단위)가 아니라 브랜드별 싱글톤으로 쪼갬. **아키텍처가 아니라 프롬프트(라벨 입자) 문제** — 후보 라벨에 멤버 예시 + "브랜드 달라도 같은 품목군이면 묶어라" 가이드로 잡는 후속 실험 필요(현 프롬프트 미해결).
  2. **규모** — 103 items/1계정. magnet·임계·cold-start 수치는 멀티 계정·수백 item 재현 필요.

---

## 8. 확정된 설계 (요약)

- **묶음 생성** = `embedding prefilter(top-k) → LLM sliding-window batch(라벨 시드) → label-ANN 소생`. 순수 클러스터링/cosine 임계 단독 금지.
- **트리거 분리**: 회수(즉시, 단건 OK) ⊥ 묶음 정비(batch, flush=count OR timeout OR importance).
- **라벨**: 영속 + 임베딩 인덱싱, decay하되 소생, 오프라인 월1회 클러스터링 병합.
- **fine/coarse 둘 다 보존**: weekly=coarse 라벨, 트랙 C=fine 묶음. (A안 — 한 "모아뒀어요" 패러다임의 시간 축/맥락 축.)
- **screenshot(83%) blocker**: channel allowlist로 빼면 트랙 C 붕괴 → **sensitivity 필드 구현이 선결**.
- **Cold start**: 묶음은 보조 표면, 신규 주력 회수는 단건(트랙 A/B).

---

## 9. 미해결 / 후속

1. **헨리넥 과분할 프롬프트** — 라벨 입자를 "회수 단위"로 잡는 프롬프트 튜닝 + 후속 실험(lab).
2. **규모 재현** — 멀티 계정·수백 item으로 magnet·임계·cold-start 재측정.
3. **sensitivity 필드 스키마** — screenshot 회수 개방의 blocker(PRIVACY_SENSITIVE_CAPTURE §6.2를 어디까지 DB로).
4. **flush timeout T·importance 임계** 실측.
5. **라벨 decay/병합 주기** 정책.

---

## 10. 기존 문서 정합 (정정 필요)

이 실험은 선행 문서를 **정정**한다 — 반영 미완(다음 작업):
- `…-tech-design.md` §"클러스터링 아님" 부분 → **"embedding 클러스터링 단독 불가(magnet 실증); 묶음 = prefilter→LLM batch + label-ANN"** 로 정정.
- `…-tech-design.md` §3.3 channel allowlist → **screenshot 83% 데이터로 sensitivity blocker 승격** 명시.
- `…-design.md`·`…-tech-design.md`에 이 저널 포인터 한 줄.
- (committed `docs/PROPOSAL_PROACTIVE_RECALL.md`는 제품 레벨이라 묶음 *구현 방식*은 안 들어감 — "관련 기억 모음"이 어떻게 만들어지는지는 내부 문서로 충분.)
