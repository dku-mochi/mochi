"""캡처 단서 → best-effort 원문 URL 복원 오케스트레이터 (프로토타입).

이 파일은 exp1(단서 추출)·exp2(YouTube/프로필 복원)·exp3(X syndication 매칭)이 **실제로
조립되는지** 검증하는 얇은 오케스트레이션이다. FINDINGS "구현 핸드오프 §A" 의 결정 흐름을
단일 진입점 `recover(clues) -> RecoveryResult` 로 구현한다.

설계 경계 (의도적으로 lab 수준 — production 이 다시 입힌다):
  - 외부 fetch 는 exp2/exp3 함수를 그대로 쓴다 → **SSRF 가드 없음.** production 은
    `PlatformContextTool._guarded_get`/`_enforce_host_policy` 로 감싸야 한다(아래 [GUARD] 표시).
  - DB·DI·config·에러 택소노미 없음. 입력은 dict, 출력은 dataclass — production DTO 로 매핑.
  - X 매칭 score 임계는 placeholder. exp1 실행으로 *실제 OCR 본문* 분포를 본 뒤 튜닝한다(TODO).

production 이식 가이드:
  이 `recover()` 본문이 백엔드 복원 tool 의 `run()` 골격이다. 단서는 analysis 단계
  (`system_prompts.py`)가 산출하고, 결과 url+recover_level 은 `IntentPayloadDTO.url`(+신규 필드)로
  카드 상세에 노출. 복원 앞단에 민감 캡처 게이트(PRIVACY_SENSITIVE_CAPTURE.md)를 둔다.

실행 (repo 루트에서):
  uv run --project mochi-backend python lab/active/capture-url-recovery/recover.py            # exp1 결과 or 기본 케이스
  uv run --project mochi-backend python lab/active/capture-url-recovery/recover.py --clues '{"platform":"x","handle":"@elonmusk","post_text":"SpaceX AI Satellites"}'
"""
import argparse
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

import httpx

# 같은 디렉터리의 검증된 실험 함수를 재사용 (중복 구현 금지).
sys.path.insert(0, str(Path(__file__).parent))
sys.stdout.reconfigure(encoding="utf-8")

from exp2_url_recovery import recover_youtube, _clean_handle  # noqa: E402
from exp3_x_syndication import best_match, fetch_timeline  # noqa: E402

LAB_ROOT = Path(__file__).parent
RESULTS_DIR = LAB_ROOT / "results"

# X 매칭 게이트: 이 미만이면 정확한 트윗을 못 집었다고 보고 profile 로 폴백.
# exp3: 깨끗한 본문 0.83~1.0. 실제 OCR/요약 변형은 더 낮음 → 보수적 시작값, exp1 후 튜닝.
X_SCORE_THRESHOLD = 0.6  # TODO(exp1): 실제 단서 분포로 재튜닝

# exp1 없이도 돌도록 — 공인 공개 계정.
DEFAULT_CLUES = [
    {"platform": "youtube", "author": "HYBE LABELS",
     "title": "NewJeans (뉴진스) 'Hype Boy' Official MV",
     "search_query": "뉴진스 Hype Boy official MV HYBE LABELS"},
    {"platform": "x", "handle": "@elonmusk", "post_text": "SpaceX AI Satellites"},
    {"platform": "threads", "handle": "@zuck", "post_text": "new feature rollout"},
]


@dataclass
class RecoveryResult:
    platform: str
    recover_level: str  # post | profile | search | none
    url: str | None
    detail: str  # 복원 근거 (production: 로그/디버그용, 응답엔 불필요)


def _has_clue(clues: dict) -> bool:
    return any(clues.get(k) for k in ("handle", "author", "title", "post_text", "search_query"))


def recover(clues: dict, client: httpx.Client) -> RecoveryResult:
    """단서 dict → best-effort URL + tier. 흐름 A(FINDINGS §A) 단일 구현.

    NOTE: 호출 전 민감 캡처 게이트를 통과시킨다(이 프로토타입 범위 밖 — production 앞단).
    """
    platform = (clues.get("platform") or "none").lower()
    if not _has_clue(clues):
        return RecoveryResult(platform, "none", None, "단서 없음(handle·title·text 모두 빈값)")

    # ── YouTube: 검색→videoId→watch→oEmbed 검증 (견고, 공식 oEmbed) ───────────────
    if platform == "youtube":
        # [GUARD] recover_youtube 내부의 httpx.get(검색 스크랩·oEmbed)은 production 에서
        #         _guarded_get 로 교체. 검색 스크랩은 SCRAPE_UA(데스크톱) 필수.
        r = recover_youtube(client, clues)
        level = r.get("recover_level", "none")
        return RecoveryResult(platform, level, r.get("best_url"),
                              f"youtube {level} (videoId={r.get('video_id')})")

    # ── X: syndication 타임라인 → 본문매칭 → score 게이트 → post, 아니면 profile ──
    if platform == "x":
        handle = _clean_handle(clues.get("handle"))
        post_text = clues.get("post_text") or ""
        if handle and post_text:
            # [GUARD] fetch_timeline 의 httpx.get(syndication)도 production 에선 가드 + 클라우드 IP
            #         생존(cloud_ip_check) 통과가 전제. 미통과면 이 분기 자체를 끈다.
            status, tweets = fetch_timeline(client, handle)
            if tweets:
                match, score = best_match(post_text, tweets)
                # 타임라인(최근 ~100)에서만 매칭하므로, 윈도우 밖 게시물은 자연히 저score → 폴백.
                if match and score >= X_SCORE_THRESHOLD:
                    return RecoveryResult(platform, "post", match["url"],
                                          f"x post (score={score})")
        if handle:
            return RecoveryResult(platform, "profile", f"https://x.com/{handle}",
                                  "x profile (post 매칭 실패/단서부족)")
        return RecoveryResult(platform, "none", None, "x handle 없음")

    # ── Threads: 프로필만 (post 무키 불가) ─────────────────────────────────────────
    if platform == "threads":
        handle = _clean_handle(clues.get("handle"))
        if handle:
            return RecoveryResult(platform, "profile", f"https://www.threads.net/@{handle}",
                                  "threads profile (post 무키 불가)")
        return RecoveryResult(platform, "none", None, "threads handle 없음")

    return RecoveryResult(platform, "none", None, f"미지원 platform={platform}")


def clues_from_exp1() -> list[dict]:
    """최신 exp1_*.json 의 (더 강한 추출 모델) 결과를 단서로 변환."""
    files = sorted(RESULTS_DIR.glob("exp1_*.json"))
    if not files:
        return []
    data = json.loads(files[-1].read_text(encoding="utf-8"))
    clues: list[dict] = []
    for row in data["results"]:
        for value in reversed(list(row.values())):
            if isinstance(value, dict) and value.get("is_social_post") and value.get("platform") != "none":
                clues.append({k: value.get(k) for k in
                              ("platform", "handle", "author", "title", "post_text", "search_query")})
                break
    return clues


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--clues", help="단건 복원: 단서 JSON")
    args = parser.parse_args()

    with httpx.Client(follow_redirects=True, timeout=20) as client:
        if args.clues:
            result = recover(json.loads(args.clues), client)
            print(json.dumps(asdict(result), ensure_ascii=False, indent=2))
            return

        clues_list = clues_from_exp1() or DEFAULT_CLUES
        src = "exp1 결과" if clues_from_exp1() else "기본 케이스"
        print(f"{src} {len(clues_list)}건 복원\n")
        for clues in clues_list:
            r = recover(clues, client)
            label = clues.get("handle") or clues.get("author") or clues.get("title") or "?"
            print(f"  [{r.recover_level:7s}] {r.platform:8s} {str(label)[:32]:34s} → {r.url}")


if __name__ == "__main__":
    main()
