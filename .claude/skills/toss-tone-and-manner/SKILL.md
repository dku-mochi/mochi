---
name: toss-tone-and-manner
description: Apply Toss(토스)'s official tone & manner to Korean user-facing copy — 해요체, active voice, positive framing, casual honorifics, spoken-language wording. Use when writing or reviewing Korean UI text, chat/agent responses, landing copy, or marketing lines and the user asks for "토스 톤", "토스 톤앤매너", "토스처럼", or a friendly-direct Korean product voice. Sources are Toss's published guidelines (Apps-in-Toss UX writing guide, toss.tech 8 writing principles).
---

# Toss Tone & Manner

토스가 공개한 보이스톤 지침을 한국어 제품 카피에 적용한다. 출력물은 항상 한국어.

**출처 (정본)**
- 앱인토스 개발자센터 UX 라이팅 가이드 — https://developers-apps-in-toss.toss.im/design/ux-writing.html
- 토스의 8가지 라이팅 원칙 (toss.tech) — https://toss.tech/article/8-writing-principles-of-toss

## 1. 보이스톤 5규칙 (앱인토스 UX 라이팅 가이드)

1. **해요체** — 상황·맥락 불문 모든 문구에 해요체. '~합니다' 금지. '되어요'는 '돼요'로.
2. **능동적 말하기** — 수동형 최소화.
   - '됐어요' → '했어요' / '저장되었습니다' → '저장했어요'
   - '~었' 빼기: '확인했어요' → '확인해요' (완료 시점이 핵심이 아니면 현재형)
   - 명사+한자어 동사 대신 동사로: '결제 완료' → '결제했어요'
3. **긍정적 말하기** — '안 돼요/없어요' 대신 '~하면 할 수 있어요'. 에러 메시지도 해결 방법 중심의 긍정형. 일부 기능만 막힐 때 전체가 안 되는 것처럼 읽히지 않게.
   - 다이얼로그 왼쪽 버튼은 **'닫기'로 통일** — '취소'는 진행 중 작업이 취소된다고 오해할 수 있어 쓰지 않는다.
4. **캐주얼한 경어** — '~시겠어요?', '~시나요?', '~께', '여쭈다', '계시다' 같은 과도한 경어 금지. '~시' 빼기, '께'→'에게', '계시다'→'있다', '여쭈다'→'묻다/확인하다'. '~시'를 빼서 어색해지면 파악하려는 정보를 주어로 문장을 다시 쓴다.
5. **'{명사}+{명사}' 쓰지 않기** — 한자어 명사 나열을 동사로 풀어쓴다. 못 풀면 '{명사}가 {명사}해서' 형태로라도 완화.

### 예외 규칙 (원칙을 깨도 되는 경우)

- **수동형 허용**: 서비스 종료·기간 만료('서비스가 종료돼요'), 사용자에게 미치는 영향을 설명할 때('계약이 해지돼요'), 사용자를 안심시켜야 할 때('수집되지 않아요').
- **경어 허용**: 사용자의 행동을 추정해 묻는 질문('카드 사용하셨나요?'), 선의로 부탁하는 요청(설문 등).
- **부정형 허용**: 정책상 불가능한 것은 명확하게 '~할 수 없어요', 민감 정보 안심 문구('수집되지 않아요').

## 2. 8가지 라이팅 원칙 (toss.tech)

1. **Predictable hint** — 버튼을 누르면 다음에 무슨 화면·무슨 일이 생기는지 라벨만 보고 예측 가능하게.
2. **Weed cutting** — 넣든 빼든 의미가 같은 단어는 제거.
3. **Remove empty sentences** — 제목이 이미 말한 걸 본문이 반복하지 않는다. 한 화면 안 중복 설명 제거.
4. **Focus on key message** — 만든 사람의 맥락 말고, 사용자가 지금 필요한 정보만.
5. **Easy to speak** — '읽기 쉬운'이 아니라 '소리 내어 말하기 쉬운' 표현. 한자어·문어체 대신 일상어.
6. **Suggest over force** — 공포·협박·손해 프레임 금지. 중립적으로 제시하고 선택권은 사용자에게.
7. **Universal words** — 연령·업계 불문 누구나 아는 단어. 유행어·밈·전문용어 지양.
8. **Find hidden emotion** — 정보 전달 너머 그 순간 사용자의 감정에 공감 (예: 상환 완료엔 축하).

## 3. 적용 워크플로우

1. 대상 문자열을 화면/순간 단위로 모은다.
2. 각 문자열을 §1 5규칙 → §2 8원칙 순으로 점검하고, 걸리는 규칙을 명시해 고친다.
3. 예외 규칙에 해당하면 원칙을 깨고 그 이유를 남긴다.
4. 최종본을 소리 내어 읽어본다 — 말로 어색하면 다시 쓴다 (Easy to speak).

프로젝트에 자체 보이스 가이드(예: MOCHI의 `mochi-ux-writing`)가 있으면 그 프로젝트의 페르소나·금지 규칙이 우선하고, 이 스킬은 문장 층위(어미·능동·긍정·간결)의 기준으로 쓴다.
