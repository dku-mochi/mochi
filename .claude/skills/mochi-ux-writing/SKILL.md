---
name: mochi-ux-writing
description: Write, diagnose, and improve the Korean microcopy users see in the MOCHI app — buttons, labels, toasts, error messages, empty states, permission/consent text, onboarding, placeholders, section headers. Trigger aggressively whenever the user asks about "카피", "UX writing", "문구", "라벨", "버튼 텍스트", "에러 메시지", "빈 화면 문구", "안내 문구", "카피 다듬어줘", "문구 개선", "이 말 더 낫게", or whenever new Korean text is added to or edited in a SwiftUI screen. Use it when the target is "the words themselves" — not layout, color, or animation. The core premise: existing MOCHI copy is material to improve, NOT a correct answer to imitate.
---

# MOCHI UX Writing

Make every line of Korean text a MOCHI user reads into **top-tier microcopy** — whether you're writing it fresh or fixing wording already shipped on a screen.

The copy you produce is always **Korean** (MOCHI ships in Korean). These instructions are in English; the output is not.

## Stance — existing copy is not the answer

Copy already on screen is **material to improve (a "before"), not a model answer.** Never reason "it currently says X, so match X." Assume roughly half the current copy is fine and half is mediocre — decide which, every time, against the principles below. Do not treat shipped strings as ground truth.

Two things *are* law, and they come from different places:

1. **MOCHI's intended voice and prohibitions** — the design decisions written down in `docs/PRODUCT.md` and `docs/UX_SPEC.md`. These are deliberate rules, not accidental wording, so honor them.
2. **Universal top-tier microcopy principles** (§3) — the actual engine of "top-tier." Good-writing standards that hold for MOCHI or anywhere.

When judgment is split: make it better by §3, but never cross MOCHI's voice (§2) or prohibitions (§4).

## 1. Before writing — establish context

Good microcopy doesn't come from a vacuum. The same button needs different words depending on who hits it, in what state of mind, while trying to do what. Before writing, know the following — or, if you don't, name what's missing and ask the user once:

- **Which screen, which moment** — home empty state? a delete-confirmation dialog? an upload-failed toast?
- **The user's emotional state** — hopeful (empty state)? anxious (delete, account deletion, permissions)? annoyed (error)? neutral (settings)? This sets the tone.
- **What the user was actually trying to do** — copy should get out of the way of that task, not block it. The user didn't come to read.
- **Physical constraints** — button width, characters per line, dialog height. If it's too long, it can't ship.
- **Surrounding flow** — what the user saw right before this string, and what happens when they act on it.

If context is missing, don't guess to fill it — state what's unknown and ask in one batch.

## 2. MOCHI's voice (law — from docs)

`docs/PRODUCT.md` and `docs/UX_SPEC.md` are the source of truth; read them directly when you need detail. The essentials:

- **Mission**: "놓치기 쉬운 순간은 쉽게 남기고, 필요한 기억은 쉽게 떠오른다." (Easy to capture fleeting moments; needed memories surface on their own.) The active agent of recall is **MOCHI** — the user doesn't go dig things up; MOCHI surfaces them.
- **MOCHI is the one doing the work.** Not "(you) organize this" but "모찌가 정리해드릴게요" (MOCHI will tidy it for you). Copy that makes the *user* sort, classify, or manage violates the mission.
- **Friendly polite register (~해요체).** Use endings like "~해드릴게요" (a promise), "~있어요 / ~이에요" (state/invitation), "~해보세요" (a gentle nudge). Avoid the stiff ~합니다체 and avoid plain/casual form. Exception: legal notices (terms, required consent) may warrant a more formal register — match the moment.
- **MOCHI is a persona.** Personify it — "모찌가 기다리고 있어요" (MOCHI is waiting), "모찌가 헷갈려 해요" (MOCHI is unsure) — but keep it understated, never cloying or forced.
- **Never expose the internal model.** System-internal concepts — the 4-Intent classification, the categorization algorithm, sensitivity scores — must never surface to the user. They show only through the *shape* of the result (a checkbox, a schedule, a link).
- **Respect autonomy.** Don't pressure or rush. Not "지금 바로 하세요" (do it right now) but "곧 골라드릴게요" (I'll pick some for you soon) — honor the user's pace.
- **Sensitive info: concrete reason + a choice.** Not vague fear ("정보가 위험해요" / your info is at risk) but a concrete statement of what was detected and why, plus options the user can choose from.

## 3. Top-tier microcopy principles (law — the universal engine)

This is what separates "ordinary MOCHI copy" from "top-tier." Apply each with its **why** in mind.

- **Clarity over cleverness.** The user came to get something done, not to admire prose. The answer to "what happens if I tap this?" beats wit. If a pun delays comprehension by even a second, cut it.
- **Answer the question in the user's head.** Every piece of microcopy answers the question the user is silently asking in that moment — "Is this safe? How long will it take? Can I undo it? Where does this take me?" Surface that question first, then write the answer.
- **Make every word work.** Strip the filler that Korean UX text accretes by default: "~하실 수 있습니다"→"~해요", "~에 대한"→"~", "진행해 주세요"→"~해 주세요", "성공적으로 저장되었습니다"→"저장했어요". If removing a word leaves the meaning intact, remove it.
- **One message per screen.** Pack two ideas into one sentence and both get weaker. The headline carries one conclusion; the subline adds one line. Split into more lines if you need more.
- **Labels state the outcome, not the action.** Instead of "확인" (confirm/OK), write what the button *accomplishes* — "삭제" (delete), "저장하고 닫기" (save and close), "모찌에게 보내기" (send to MOCHI). If the user knows what will happen from the label alone, you've won.
- **Give control in anxious moments.** In scary moments — delete, account deletion, permissions, payment — provide (1) an honest account of what happens, (2) whether it's reversible, (3) what to do next. Hiding or hedging loses trust.
- **Never blame the user.** Write errors as the system's responsibility. Not "잘못 입력하셨습니다" (you entered it wrong) but "이메일 형식이 맞는지 확인해 주세요" (please check the email format). Don't make the user feel stupid.
- **Match tone to the moment.** Empty states are hopeful/inviting; errors are calm and solution-focused; risky moments are clear and honest; success is understated (no gushing, no exclamation-point spam). Modulate temperature within the same voice.
- **Concrete beats abstract.** "약 10초" (about 10 seconds) over "잠시 후" (in a moment); "3개" (3 of them) over "여러 개" (several). Give the user a picture they can hold — but never invent a number you don't know.

## 4. Patterns to avoid (prohibitions)

**MOCHI-specific prohibitions** (violations of `docs` rules):
- Exposing **internal meta** — classification, category, intent: "모찌가 4가지로 분류했어요" (MOCHI sorted it into 4 types) ❌
- Labels that make the **user do the sorting**: "직접 정렬하기" (sort it yourself), "폴더 만들기" (create a folder) ❌
- **Vague fear copy**: "당신의 정보가 위험해요" (your info is at risk) ❌ → give the concrete detection reason
- **Coercion / nagging**: "지금 바로 처리하세요" (handle it right now) ❌ → respect the user's pace
- **Promising or referencing unbuilt features** ❌

**General writing prohibitions** (the things that block "top-tier"):
- **Translationese**: "당신의 ~" (your ~), "~을 위한" (for the purpose of ~), needless passive ("~되어집니다"), "~에 대해서" (regarding ~)
- **Empty hype**: self-congratulatory adjectives like "최고의" (the best), "혁신적인" (innovative), "스마트한" (smart) — don't tell it, let the user feel it
- **AI-tell clichés**: overuse of "원활하게" (smoothly), "손쉽게 / 간편하게" (easily/conveniently), meaningless "다양한" (various)
- **Exclamation inflation**: ! on every sentence — save it for moments of genuine delight
- **Apology overload**: repeating "불편을 드려 죄송합니다" (sorry for the inconvenience) — say it once, then move to the fix

## 5. Workflow

Whether writing fresh or fixing, follow this order:

1. **Diagnose** — (if improving) point out in a line or two what's weak in the current string, tied to §3/§4: "too much filler," "states the action instead of the outcome." If writing fresh, confirm the §1 context.
2. **Recommendation + alternatives** — lead with the single option you recommend, then give 1–2 alternatives that differ in tone or length. Label how each differs — "shorter version," "warmer version."
3. **Rationale** — explain in one line why the recommended option is better, tied to a principle: "puts the outcome in the label," "answers the user's 'can I undo this?'"
4. **Self-check** — run the final option through the §6 rules yourself and note pass/fail briefly.

When handling many strings at once, group by screen/moment.

## 6. Self-check (verifiable rules)

Things you can check mechanically before delivering. If any fails, fix it:

- **Register consistency**: is the screen unified in ~해요체 (no ~합니다체 / casual-form mixing, aside from the legal-notice exception)?
- **Zero internal meta**: no system terms — "분류" (classification), "카테고리" (category), "intent", "민감도 점수" (sensitivity score) — in user-facing text.
- **Zero filler**: no leftover "~하실 수 있습니다", "~에 대한", "성공적으로", "진행해 주세요", "다양한".
- **Zero translationese**: no "당신의", "~을 위한", "~되어집니다".
- **Zero user-blaming**: error/failure copy doesn't fault the user.
- **Length sense** (guideline, not a hard rule — fit the space):
  - button/label: readable at a glance, roughly one short line
  - empty state / guidance: 1 headline + 1–2 sublines
  - toast: one line
- **Exclamation restraint**: exclamation marks only where genuinely earned.

## Output format

```
## [Screen / moment name]

**Diagnosis** (when improving)
- Current: "<original Korean string>"
- Weakness: <a line or two tied to a principle>

**Recommendation**
"<the Korean copy you recommend>"

**Alternatives**
- (shorter) "<...>"
- (warmer) "<...>"

**Rationale**: <why it's better, tied to a principle>

**Self-check**: register ✓ / no meta ✓ / no filler ✓ / no translationese ✓ / length ✓
```

When handling multiple screens, repeat the block per screen.
