# 유튜브 enrich 실험 — 종합 결론 및 적용 방향

> **기간** 2026-05-29~30 · **모델** gemini-3.1-flash-lite (Vertex AI, location=global)
> **북극성** "사용자가 직접 무언가 해야 하는 것을 최대한 줄인다."
> **데이터 리포트** `youtube_enrich_report.md`(URL→메타) · `image_context_report.md`(스크린샷→맥락+복원)

---

## 0. 한 줄 결론

유튜브 콘텐츠는 **비전 맥락추출(88%) + 메타 보강(무키·공식)** 으로 사용자 개입 없이 거의 다 enrich 된다. 진짜 사용자 fallback 은 *화면에 식별 단서(제목·채널)조차 없는 극소수(~12%)* 뿐이며, 이는 비전·URL복원이 동시에 못 푸는 본질적 한계다. 무거운 경로(영상 멀티모달·자막 추출)는 **비용·지속성 때문에 1차에서 기각**한다.

---

## 1. 실험 여정 (3단계)

| 단계 | 질문 | 결과 |
|---|---|---|
| **사전조사** | 영상 내용을 어떻게 enrich? | 멀티모달·자막은 비용/지속성 취약 → **메타 1차** 결정 |
| **URL→메타** (`youtube_enrich_bench`) | URL 있을 때 메타만으로 충분? | 13/13 추출, intent·요약 우수, $0.0001/건 |
| **이미지→맥락+복원** (`image_context_bench`) | URL 없는 스샷은? | 비전 맥락 7/8(88%), videoId 복원 8/8(정확 6/8) |

---

## 2. 핵심 발견

### 2.1 무거운 경로를 기각한 이유 (사전조사)
- **Gemini 멀티모달(YouTube URL 직접)**: 영상 토큰화 ~300 tok/s(low 100) → 10분=6만~18만 토큰. 지금은 프리뷰 무료지만 **GA 시 비용 폭발 + 프리뷰 의존 리스크**.
- **자막**: 공식 `captions.download` 는 OAuth+본인 영상만. 무키 `youtube-transcript-api` 는 **클라우드(GCP/AWS) IP 차단** → residential proxy 필수 = **지속성 취약**.
- → **메타(oEmbed 무키 + watch page `shortDescription`)** 는 공식·무키·클라우드 OK·지속가능. 1차 경로 확정.

### 2.2 메타 경로는 싸고 충분하다
- 비용 **~$0.00013/건** (1만 건 = $1.3). 멀티모달 대비 수십~수백 배↓.
- 식별 가능한 영상은 제목+채널+설명으로 intent·요약·검색 충분. 요약이 *"역삼동 간장게장 오다리집"* 같은 가게명·위치까지 추출.
- 판정기(`sufficient`)는 관대하지 않음 — ablation 5건 중 3건 `false`, conf 0.9 vs 0.1~0.2 로 갈려 **fallback 트리거 신호로 사용 가능**.

### 2.3 이미지 비전이 메타 역할을 한다 (URL 없어도)
- 스크린샷의 `@handle`·제목·오버레이·자막을 비전이 직접 읽음 → **7/8(88%) 맥락 충분**.
- intent 단서는 오히려 화면에 직접 보임 (8517 *"이것 좀 사려고"* = 구매 todo) — URL 메타(설명)엔 없는 정보.
- 비전이 못 읽을 땐 `suf=false` + 정확한 사유로 **자기 한계를 정직하게 보고**.

### 2.4 URL 복원은 "단서 의존"
- 비전 제목·채널 → 무키 youtube 검색(`/results`) → 첫 videoId → oEmbed: **videoId 8/8 발견**.
- 정확도: 제목 자카드 자동측정 4/8이나, 쇼츠는 *화면 오버레이 ≠ 공식 제목*이라 과소평가. **채널+핵심어 수동검수 6/8**.
- 실패 2건: 채널 OCR 오독(`@예능감각`←메타코미디클럽), 메타 부재(영상 전체화면).

### 2.5 가장 중요한 통찰 — 비전 충분 ↔ 복원 정확은 **같은 뿌리**
둘 다 *"화면에 제목·채널 단서가 있는가"* 에 종속된다.
```
스크린샷 → 비전 맥락추출
  ├─ 단서 있음 (7/8) → 맥락 충분, URL 불필요
  │     └─ 더 풍부한 맥락 원하면 → 비전 단서로 URL 복원 → 메타 (정확도 ~75%)
  └─ 단서 없음 (1/8) → 비전 불충분 + 복원 실패 → 사용자 fallback (불가피)
```
→ **URL 복원은 비전 실패를 구제하지 못한다** (단서 없으면 검색어도 못 만듦). "비전이 단서를 읽은 뒤 더 풍부한 메타가 필요할 때"의 보강책이다.

---

## 3. Agent Tool 적용 설계 (다음 단계)

확정된 enrich 능력을 모찌 백엔드 `AgentOrchestrator`(이미 `webFetch` function-calling 보유)에 **tool 로 배선**한다.

| Tool | 입력 | 출력 | 구현 (검증됨) |
|---|---|---|---|
| `youtube_meta` | video_id \| url | 제목·채널·설명·길이·자막유무 | oEmbed(무키) + watch page `shortDescription` |
| `youtube_search` | query(채널+제목) | videoId 후보 | 무키 `/results` → videoId 정규식 |
| `image_context` | 이미지 | screen_type·제목·채널·intent·요약·`search_query`·`sufficient` | flash-lite Vision |

**오케스트레이션 흐름** (규칙 라우터 Tier 0 가 youtube 로 분기한 뒤):
```
입력이 URL  → youtube_meta
입력이 이미지 → image_context
                ├─ sufficient=true → 종료 (메타 확보)
                └─ sufficient=false & search_query 있음
                      → youtube_search → youtube_meta (메타 보강)
                      └─ 그래도 실패 → 사용자 fallback (intent 후보 제시)
```
- LLM(Agent)은 *어떤 tool 을 쓸지* 판단 + 최종 intent/요약 합성에 집중. 추출 자체는 규칙·API tool 이 싸게 처리.
- `sufficient`·`confidence` 를 fallback 게이트로 직접 사용.

---

## 4. 타 플랫폼 확장 (동일 패턴 적용)

핵심 패턴 **`비전 맥락추출 → 부족시 단서로 URL 복원 → 메타`** 은 플랫폼 무관하게 재사용 가능. 차이는 *메타/검색 가용성*뿐.

| 플랫폼 | 화면 단서 | 메타 경로 | 주의 |
|---|---|---|---|
| **YouTube** | `@handle`·제목·자막 | oEmbed(무키)+watch · `/results` 검색 | ✅ 검증 완료 |
| **Instagram** | `@username`·캡션 | oEmbed 폐지(2020) → og:tags · shortcode | 비공개·로그인월 多, 복원 어려움 |
| **X(Twitter)** | `@handle`·트윗텍스트 | publish oEmbed · og:tags | API 정책 변동성 |
| **Threads** | `@handle`·본문 | og:tags | 신생, 도구 미성숙 |

→ **인스타·X·쓰레드는 "비전 맥락추출"이 더 큰 비중을 차지**할 전망 (원문 복원이 YouTube 보다 어려움). 비전이 화면 텍스트를 읽는 능력은 이미 입증됐으므로, 각 플랫폼의 메타/복원 가용성만 개별 검증하면 됨.

---

## 5. 미해결 / 후속

- **채널 OCR 정확도** — URL 복원의 병목 (8519 오독). 비전 프롬프트에 채널 정확 추출 강조.
- **제목+채널 가중 매칭** — 현재 제목 자카드만이라 복원 정확도 과소평가. 채널 일치 가중 추가.
- **표본 확대** — 8장은 방향 확인용. 실사용 분포(설명 빈약·메타 부재 비율)로 진짜 fallback 율 측정.
- **규칙 라우터(Tier 0)** — 플랫폼 식별 + **민감신호 차단**(`PRIVACY_SENSITIVE_CAPTURE.md` 직결)을 enrich 앞단에.
- **백엔드 tool 배선** — 위 3개 tool 을 `AgentOrchestrator` 에 실제 등록 + 도메인 모델 반영 (본 실험 범위 밖, 프로덕션 작업).
