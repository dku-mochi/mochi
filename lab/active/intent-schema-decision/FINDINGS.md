---
level: 3
mode: log
status: active
last_verified: 2026-06-04
confidence: 0.8
owners: [송준서, 이용찬, 박세현]
description: Intent schema decision 실험 결과. PR #6 boolean instance 방식과 현 threshold 방식 중 어떤 스키마로 0009 타겟을 확정할지 판단할 때 읽어라.
---

# Intent schema decision — findings

## 결론

0009 타겟은 **`intent_instances` + `needs_review` + `review_options`**로 가는 편이 낫다.

초기 PR #6처럼 per-instance `applicable`을 두는 방식도 threshold 방식보다 낫지만, 추가 실험 결과 `applicable=false` 후보를 정본 DB에 저장할 이유는 약하다. `intent_instances`는 **저장할 것만** 담고, 사용자에게 보여줄 미확정 후보는 `review_options`로 분리하는 편이 의미가 더 선명하다.

단, 자유 `payload` object는 부족하다. 실험에서 열린 object payload는 Gemini structured output이 빈 객체를 내기 쉬웠다. 스키마는 아래처럼 **공통 optional typed fields를 명시**해야 한다.

```json
{
  "needs_review": true,
  "intent_instances": [
    {
      "intent_type": "todo",
      "payload": {
        "title": "...",
        "date": null,
        "time": null,
        "deadline": null,
        "person": null,
        "topic": "...",
        "url": null,
        "note": "..."
      },
      "label": "...",
      "reasoning": "..."
    }
  ],
  "review_options": [
    {
      "intent_type": "todo",
      "label": "할 일로 등록",
      "reasoning": "사용자가 선택하면 이 intent instance를 생성한다."
    }
  ]
}
```

`evidence_score`는 이번 실험에서 의사결정 성능을 올리지 않았다. product decision에는 넣지 말고, 필요하면 eval/debug 로그 전용으로만 둔다.

## 실행

```bash
GOOGLE_CLOUD_PROJECT=axial-device-460408-i9 \
  uv run --directory mochi-backend \
  python ../lab/active/intent-schema-decision/intent_schema_decision_bench.py
```

결과 파일:

- `intent_schema_decision_results.json`
- `intent_schema_decision_report.md`

## 비교 결과

Gemini `gemini-3.1-flash-lite`, temperature 0.1, 18개 텍스트 케이스.

| schema | intent F1 | instance count acc | review acc | payload quality |
|---|---:|---:|---:|---:|
| `score_flat` (`applicability` + threshold 0.6) | 0.809 | 0.667 | 0.833 | n/a |
| `boolean_instances` | 0.833 | 0.833 | 1.000 | 1.000 |
| `boolean_instances_debug` | 0.833 | 0.833 | 1.000 | 1.000 |
| `boolean_instances_refined` | **0.935** | **0.889** | 0.944 | **1.000** |
| `instances_review_options` | 0.907 | 0.833 | 0.944 | **1.000** |

## 관찰

`score_flat` 방식은 intent 후보를 넓게 보존하는 데는 괜찮지만, decision으로 쓰면 false positive가 반복됐다.

- `오늘 저녁 7시 약속` → `schedule` + `todo`
- `ReAct 구조 나중에 공부` → `todo` + `knowledge`
- `2026년 연말정산 공제 항목 정리 글` → `knowledge` + `todo` + `schedule`
- `이 가방 예쁘긴 한데 살지 말지 모르겠다` → intent는 맞춰도 `needs_review=false`
- `이거 나중에` → `todo`, `needs_review=false`

즉 threshold는 "active 저장"과 "사용자에게 물어볼지"를 잘 분리하지 못했다. 특히 "헷갈려요"는 score calibration보다 LLM의 holistic boolean 판단이 더 잘 맞았다.

`boolean_instances` 방식은 같은 type의 multi instance를 잘 표현했다.

```json
{
  "summary": "회의록 내용으로 API 명세 공유, 데이터셋 제작, 중간 점검 일정이 포함되어 있습니다.",
  "needs_review": false,
  "intent_instances": [
    {
      "intent_type": "todo",
      "applicable": true,
      "label": "찬서에게 API 명세 공유",
      "payload": {"person": "찬서", "topic": "API 명세 공유"},
      "reasoning": "찬서에게 API 명세를 전달해야 하는 구체적인 업무입니다."
    },
    {
      "intent_type": "todo",
      "applicable": true,
      "label": "세현이의 eval dataset 제작",
      "payload": {"person": "세현", "topic": "eval dataset 제작"},
      "reasoning": "세현이가 수행해야 할 구체적인 작업입니다."
    },
    {
      "intent_type": "schedule",
      "applicable": true,
      "label": "중간 점검 회의",
      "payload": {"date": "금요일", "time": "14:00", "topic": "중간 점검"},
      "reasoning": "금요일 2시로 확정된 회의 일정입니다."
    }
  ]
}
```

`boolean_instances_refined`는 prompt policy가 중요했다. 다음 규칙을 넣자 실패가 줄었다.

- "나중에 공부" / 기술 개념 = `knowledge`, 구체적 적용 행동이 있을 때만 `todo` 추가
- 장기 목표 = `todo`, 구체적 날짜/시간이 없으면 `schedule` 금지
- article title의 연도/날짜 = `schedule` 금지
- "이거 나중에"처럼 대상/행동이 없는 경우 = `memo` fallback + `needs_review=true`
- 명시적 양자택일 = `needs_review=true`, 확정되지 않은 행동은 함부로 materialize하지 않음

`instances_review_options`는 refined boolean보다 intent F1이 약간 낮았다. 이유는 구매 고민/양자택일 케이스를 더 보수적으로 `memo`만 저장하고, `todo`/`knowledge` 가능성은 `review_options`로 보냈기 때문이다. 제품 정책상 "사용자가 확정하지 않은 행동을 자동 materialize하지 않는다"가 더 중요하면 이 손실은 허용 가능한 보수성이다.

적절했던 low-signal output:

```json
{
  "summary": "사용자가 '이거 나중에'라고만 언급하여 구체적인 대상이나 의도가 불분명함.",
  "needs_review": true,
  "intent_instances": [
    {
      "intent_type": "memo",
      "applicable": true,
      "label": "나중에 확인할 항목",
      "payload": {
        "note": "사용자가 '이거 나중에'라고 저장함. 구체적인 내용이 없어 확인이 필요함."
      },
      "reasoning": "입력된 내용이 매우 모호하여 구체적인 의도를 파악할 수 없으므로, 안전한 메모 형태로 저장하고 사용자에게 확인을 요청함."
    }
  ],
  "review_options": [
    {
      "intent_type": "todo",
      "label": "할 일로 등록",
      "reasoning": "나중에 해야 할 구체적인 작업인 경우"
    },
    {
      "intent_type": "knowledge",
      "label": "지식/참고 자료로 저장",
      "reasoning": "나중에 읽거나 공부할 자료인 경우"
    }
  ]
}
```

적절했던 deadline output:

```json
{
  "needs_review": false,
  "intent_instances": [
    {
      "intent_type": "schedule",
      "applicable": true,
      "label": "장학금 신청 마감",
      "payload": {"title": "장학금 신청 마감", "date": "6월 20일", "time": "18:00", "deadline": "6월 20일 18:00"}
    },
    {
      "intent_type": "todo",
      "applicable": true,
      "label": "장학금 신청 서류 업로드",
      "payload": {"title": "장학금 신청 서류 업로드", "note": "마감 전까지 서류를 업로드해야 합니다."}
    }
  ]
}
```

## 남은 결정

모호 케이스에서 `needs_review=true`일 때 "가능한 todo 후보도 함께 저장할지" 아니면 "memo fallback만 저장할지"는 제품 정책이다.

이번 실험 기준으로는 **확정되지 않은 행동은 materialize하지 않고 memo fallback만 저장**하는 쪽이 더 안전하다. 사용자가 답하면 그때 todo/schedule instance를 생성한다.

추천 최종 스키마:

- DB: `intent_instances jsonb not null default '[]'`, `needs_review boolean not null default false`
- DB 또는 API: `review_options jsonb not null default '[]'` 또는 `needs_review` 응답 projection 안의 transient options
- instance: `intent_type`, `payload`, `label`, `reasoning`
- review option: `intent_type`, `label`, `reasoning`
- payload: 공통 optional typed fields(`title`, `date`, `time`, `deadline`, `person`, `topic`, `url`, `note`)
- no `applicable` in canonical stored instances. Presence in `intent_instances` means applicable.
- no decision threshold
- no stored `confidence`
- optional score는 제품 필드가 아니라 eval/debug trace로만 별도 보관

## 이미지 validation — image-only 재검증 (2026-06-04)

사용자가 제공한 validation 이미지 15장은 처음에 파일명 메모를 모델 입력에 함께 넣어 평가했다. 이 방식은 파일명이 곧 사용자 의도라서 성능을 과대평가한다. 따라서 같은 15장을 **이미지 바이트만 입력**하고, 파일명/사용자 메모를 완전히 제거한 상태로 다시 평가했다. 파일명은 모델 입력이 아니라 offline gold label 산정에만 사용했다.

실행:

```bash
python3 lab/active/intent-schema-decision/validation_image_only_eval.py
```

결과 파일:

- `validation_image_only_results.json`
- `validation_image_only_report.md`

최종 결과:

| input policy | n | intent F1 | count acc | review acc | review options shape acc |
|---|---:|---:|---:|---:|---:|
| image only, no filename, no user memo | 15 | 0.911 | 0.933 | 1.000 | 1.000 |

중요한 해석:

- `review accuracy = 1.0`은 강한 증거가 아니다.
- 이번 validation 15장에는 gold `needs_review=true` 표본이 0개였다.
- 따라서 확인된 것은 **명확한 케이스에서 불필요한 review를 띄우지 않는다(FP 0)** 뿐이다.
- 확인되지 않은 것은 **정말 물어봐야 하는 케이스를 놓치지 않는가(FN/recall)** 이다.

이번 validation의 `needs_review` confusion matrix:

| | gold review=true | gold review=false |
|---|---:|---:|
| pred review=true | 0 | 0 |
| pred review=false | 0 | 15 |

즉 `needs_review`의 false negative 비율은 이번 표본으로는 계산할 수 없다. 다음 review 정책 실험에는 의도적으로 `needs_review=true`가 되어야 하는 양성 표본을 넣어야 한다. 예시는 다음과 같다.

- 화면 자체가 저장 의도를 묻거나 분류가 애매하다고 말하는 경우
- 핵심 텍스트가 잘려 safe memo/knowledge조차 어렵게 보이는 경우
- 날짜는 보이지만 이벤트/마감인지 단순 기사 날짜인지 판단하기 어려운 경우
- 같은 화면 안에서 구매/참고/일정 후보가 충돌하고 어느 하나를 저장하면 오동작 가능성이 큰 경우

image-only에서 남은 drift:

| case | gold | pred | 해석 |
|---|---|---|---|
| `validation_10_스케줄.jpg` | schedule | schedule + knowledge | 기숙사 생활 안내와 비데 점검 일정이 같이 보여 안내문까지 저장 가치로 과분류 |
| `validation_13_나중에 살 화장품.jpg` | todo | knowledge | 이미지 자체는 바닐라 향 제품 추천 정보로 보이며, "나중에 살" 의도는 파일명 없이는 약함 |

결론:

- `intent_instances + review_options` 스키마 효과는 image-only에서도 유지된다.
- 다만 사용자의 사후 의도(`나중에 살`, `가봐야지`, `신청해야지`)는 이미지에 직접 드러나지 않으면 완전히 복구할 수 없다.
- 운영 정책은 **image-only 기본 분류 + 사용자가 입력한 메모가 있으면 별도 strong intent signal로 반영**하는 쪽이 맞다.
- `needs_review` 정책의 recall은 이번 validation으로 판단하지 말고, 양성 표본을 추가한 별도 stress set에서 측정해야 한다.

## GCS 이미지 표본 보강 (2026-06-04)

localhost Postgres 는 꺼져 있어 직접 조회하지 못했다. 대신 `.env` 의 GCS 설정을 사용해 `axial-device-460408-i9` 프로젝트의 `mochi-captures-axial-device-460408-i9` 버킷을 조회했다.

결과:

- GCS object: 31개, 5.92MiB
- local downloaded sample: 30개 (`ea740...jpg` 가 서로 다른 owner prefix에 중복 파일명이라 1개 overwrite/skip)
- Gemini Vision inventory 기준 usable: 17개 (`suitability >= 3`, high sensitivity 제외)
- sensitivity: low 26개, medium 4개, high 0개
- review likely: usable 17개 중 10개

분포:

- category: calendar/event 2, chat/social 5, media 11, product 7, unknown 5
- stressor: review_options 7, payload_extraction 11, deadline 4, ambiguous_user_intent 4, multi_instance 3, date_not_schedule 1

저장된 산출물:

- `gcs_manifest.json`: GCS object manifest
- `../../data/gcs-captures/`: 내려받은 이미지 (`lab/data/` 는 gitignore 대상. 개인정보 가능성 때문에 원본 이미지는 여기만 둔다.)
- `gcs_image_inventory.json`: Gemini Vision raw inventory
- `gcs_image_inventory.md`: 사람이 읽는 후보 목록

추가 eval에 넣기 좋은 대표 후보:

| file | score | sensitivity | expected | stressor |
|---|---:|---|---|---|
| `584789139516a3bef6ac40c83fbc4eb137558b8874e7ba2b8d6cfcfa6ddbac22.jpg` | 5 | low | memo + review | ambiguous_user_intent, review_options |
| `6abe686ecc8859908c00b730fb70b0152d54250014b622127476a8540b50bddf.jpg` | 5 | low | todo | deadline, payload_extraction |
| `bc47e62e2ee01fe44f20fab63f0a0e6d9871acc4649e6c737051d43167a1db16.jpg` | 5 | low | schedule + todo + review | deadline, payload_extraction |
| `c054ed9fd6325a08773ba7049167212436e0bb5e052e33d272e003d075f6e11a.jpg` | 5 | low | memo + todo + review | ambiguous_user_intent, review_options, multi_instance |
| `c84b1fddf5d2db73ea87092afe4c75d484235d154cdf3246902a425fc80203b7.jpg` | 5 | low | memo + review | ambiguous_user_intent, review_options |
| `528fdd69dad1f1514038e19e9328b9433b9b60615d79feb1b77165445ec3b9c2.jpg` | 4 | low | todo | multi_instance |
| `97e43eed6fda415c19edb7d8b5f6da4c4d7e3b0c989e303002241a91a9fcffca.png` | 4 | low | todo + review | deadline, payload_extraction, review_options |
| `8d45a4425fa5bce3b4ed6367ea6bf42b26c958e20c47dfd9df96d01aa93164cf.jpg` | 4 | low | schedule/review caution | date_not_schedule, payload_extraction |

주의:

- medium sensitivity 4개는 schema stress에는 좋지만 공유 eval에는 별도 동의/마스킹 후 사용.
- 모찌 앱 화면 자체가 여러 장 포함되어 있어, "실제 사용자 입력 화면"과 "모찌가 이미 분석한 결과 화면"을 분리해 gold를 달아야 한다.
- score 1~2의 미디어 소비/홈 화면은 low-context negative sample로 일부만 쓰고, 주 eval에는 넣지 않는 편이 낫다.
