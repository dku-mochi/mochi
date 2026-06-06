---
level: 3
mode: log
status: active
last_verified: 2026-06-04
confidence: 0.8
owners: [송준서, 이용찬, 박세현]
description: GCS 캡처 이미지 30개를 Codex가 직접 확인해 intent_instances + review_options 스키마 기준으로 라벨링한 결과. 이미지 기반 schema eval 표본을 고를 때 읽어라.
---

# GCS image human label report

Codex가 `lab/data/gcs-captures/`의 이미지 30개를 contact sheet로 직접 확인한 뒤 라벨링했다.

라벨 파일: `gcs_image_human_labels.json`

## Summary

- total images: 34
- eval include: 26
- eval caution: 5
- eval exclude: 3
- needs_review=true: 15
- review_options total: 34
- intent_instances count: memo 20, todo 6, knowledge 9, schedule 3

## Best Eval Set

아래 26개는 바로 schema eval에 넣기 좋다.

| # | file | gold | review | why |
|---:|---|---|---|---|
| 2 | `01155271f39cfa3a6730b07585cf39c3db724e2a07bb6337ceda7f841484b967.jpg` | knowledge | false | 식물 관리 참고 |
| 3 | `0b1c948f6d9eee927144a65038e12454078d3be655992eefe2bf29fd97022469.jpg` | memo | false | 밈/재시청 |
| 4 | `105931b75a71b3c71a190b60669f8d9d6e175b24fdf99860db.jpg` | memo | false | 콘서트 하이라이트 |
| 7 | `1bc23d2c674863cce312a923bb984e3d4a2772f50bcf5c8a4c99766691ddf599.jpg` | memo | false | 인상적인 만화 대사 |
| 9 | `1c8f0d28362cc96b58f814cd3899de964c9d3f39563fdd563644dd257004b41b.jpg` | knowledge | false | 수학/개발 영상 |
| 10 | `3f96fb59258b0944d03831b2d4dd2b37a08d486c715bc2795fecde42a1bc977e.jpg` | knowledge | false | 주식 알림 multi-info |
| 12 | `57b8cb156eb53544df69abbcb61bf9577e7d974969a7da4f7a836163a6b570d8.jpg` | memo | true | 맛집/예약 후보 |
| 13 | `584789139516a3bef6ac40c83fbc4eb137558b8874e7ba2b8d6cfcfa6ddbac22.jpg` | memo | true | 모찌 헷갈려요 링크 |
| 14 | `5e85e08e1c83effa636fe98c87ba5ed1796e542bc5eff0b1962c3c96df27e14d.jpg` | memo | true | 식당 예약 후보 |
| 15 | `5ff895b9a1314588e88f65012f74c8d374542c6d61be6280285cd2e8a1d9fcd1.jpg` | todo + schedule | true | 생일/선물 챙기기 |
| 16 | `650cd8aca1b4fcf3b63373211e80421138553c41ccb7dbc80777a7e307bf0027.jpg` | memo | false | 코미디 쇼츠 |
| 18 | `7b20888d2949e8977c9b37cdb8a648f540e5ab51c8504d252148d14aecfc98b8.jpg` | memo | false | 엔터테인먼트 영상 |
| 19 | `8d45a4425fa5bce3b4ed6367ea6bf42b26c958e20c47dfd9df96d01aa93164cf.jpg` | memo | true | 세일 기간/date_not_schedule |
| 20 | `940a9534812ce96127bcb4bdf0560a00f2be7afa4ce3a7ca60a60a3652cdc325.jpg` | knowledge | false | Opus 4.8 영상 |
| 21 | `97e43eed6fda415c19edb7d8b5f6da4c4d7e3b0c989e303002241a91a9fcffca.png` | memo | true | 마우스 구매 후보 |
| 22 | `bbb228d4affae92500dc8e5b5e992f757bc7597bd2372d08140f7210d3028b76.jpg` | schedule + todo | true | 도시가스 점검 |
| 23 | `bc47e62e2ee01fe44f20fab63f0a0e6d9871acc4649e6c737051d43167a1db16.jpg` | schedule + todo | true | AI/XR 경진대회 |
| 26 | `d156227e5f95eff74cdf591b0d05d9596acd11bfe627f833ee9bd59621d9b581.jpg` | memo | false | 일상 사진/문구 |
| 27 | `d833f08fa5b0cea415d60bf43aee192d0f7e95ce1b8c9883133fe03521b1ee2b.jpg` | memo | false | 음악 릴스 |
| 28 | `e75ac75dfed21ce6becdbfad172b9a502b35b752410517bdcb79b6613c678e0a.jpg` | knowledge | false | Opus/Claude 영상 |
| 29 | `ea740f9a6da381a30811744e1894b17131a463cfc6f0eee40e835cef15c7d629.jpg` | memo | false | 참치 영상 |
| 30 | `fb4785e8e3617398af404d60b106ccadef1d7acdde821e058b0c4718e6787707.jpg` | memo | true | 바디워시 구매 후보 |
| 31 | `img_8541_resized.jpg` | knowledge | false | 레이밴 메타 스마트글래스 정보 |
| 32 | `img_8542_resized.jpg` | knowledge | false | 선관위 투표용지 부족 뉴스 |
| 33 | `img_8543_resized.jpg` | knowledge | false | 오디세우스 오픈소스 AI 워크스페이스 |
| 34 | `img_8544_resized.jpg` | knowledge | true | HWPX 클로드 스킬 + CTA |

## Caution

아래 5개는 쓸 수는 있지만, 모찌 앱이 이미 분석한 결과 화면이라 원본 capture intent eval에는 섞지 않는 편이 낫다.

| # | file | reason |
|---:|---|---|
| 1 | `0082d3fbf37c2d1f89a8afacb0aa41377f01b05d2e39ab2794b35a0f4db472f5.jpg` | 모찌 홈 결과 화면 |
| 11 | `528fdd69dad1f1514038e19e9328b9433b9b60615d79feb1b77165445ec3b9c2.jpg` | 모찌 홈 결과 화면 |
| 17 | `6abe686ecc8859908c00b730fb70b0152d54250014b622127476a8540b50bddf.jpg` | 모찌 결과 화면의 교육 수강 카드 |
| 24 | `c054ed9fd6325a08773ba7049167212436e0bb5e052e33d272e003d075f6e11a.jpg` | 모찌 결과 화면 + 링크 헷갈림 |
| 25 | `c84b1fddf5d2db73ea87092afe4c75d484235d154cdf3246902a425fc80203b7.jpg` | 모찌 분석 중/헷갈림 UI |

## Exclude

아래 3개는 낮은 맥락이라 주 eval에는 제외한다. low-context negative sample로는 쓸 수 있다.

| # | file | reason |
|---:|---|---|
| 5 | `15cf7b4cb569cd7f7632dabe7d541fc46a7a2837059988a6227a7f309e851691.jpg` | iOS 검색 화면 |
| 6 | `16404a02c1604ffb0e3e9e92acc8065a1a55dfcd2d4aee6806dd51cc14721581.jpg` | iOS 홈 화면 |
| 8 | `1c1bc10b0771477ee4472f81eeb1c99b52cecb504b6810aa7e78fdd34f8e2ea7.jpg` | 앱 폴더/홈 화면 |

## Decision Notes

- 상품/맛집/광고류는 대부분 `memo`로 안전 저장하고 `review_options`에 `todo`를 넣었다. 구매/예약은 사용자가 확정하기 전까지 자동 materialize하지 않는 정책에 맞춘 라벨이다.
- 기간이 보이는 광고는 기본 `schedule`로 저장하지 않았다. 세일 기간은 payload에 보존하고, 알림이 필요할 때만 `review_options.schedule`로 둔다.
- 도시가스 점검, 경진대회처럼 실제 마감/방문/신청 행동이 뚜렷한 것은 `schedule + todo`를 허용했다.
- 모찌 앱 결과 화면은 schema stress에는 유용하지만, 모델 평가에서는 원본 캡처와 중복 신호가 섞이므로 caution으로 분리했다.
