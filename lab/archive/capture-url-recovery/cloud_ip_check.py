"""X syndication 클라우드 IP 생존성 프로브 (exp3 보강) — stdlib only, 어디서나 실행.

왜 별도 스크립트인가:
  exp3 는 *로컬(주거용) IP* 에서 syndication 이 200 을 주는 걸 확인했다. 하지만 프로덕션은
  GCP/Cloud Run 의 *데이터센터 IP* 에서 나간다. syndication 은 Cloudflare 봇 매니지먼트
  (`server: cloudflare`, `__cf_bm` 쿠키) 뒤에 있고 IP당 30회/15분 레이트리밋이 걸린다 —
  Cloudflare BM 은 데이터센터 ASN 을 능동 차단하므로, 같은 요청이 클라우드 IP 에선 403/503
  challenge 로 떨어질 수 있다. 그 한 가지를 *실제 클라우드 IP 에서* 판정한다.

어디서 돌리나 (둘 중 하나 — Google 데이터센터 IP 가 나오는 환경):
  1) GCP Cloud Shell (무료, 가장 쉬움): https://shell.cloud.google.com 접속 후
       curl -sL <이 파일 raw URL> -o /tmp/c.py && python3 /tmp/c.py
     (또는 내용 복붙). 의존성 없음 — Cloud Shell 기본 python3 로 즉시 동작.
  2) 실제 배포 egress (가장 정확): Cloud Run/Functions 의 egress IP 에서 동일 요청.
     production 어댑터가 나갈 바로 그 경로라 이게 최종 진실. mac 사용자 배선 시 확인.

의존성 없음(urllib). 단발 요청만 보낸다 — 레이트리밋을 건드리지 않도록 1회.
"""
import json
import sys
import urllib.error
import urllib.request

HANDLE = sys.argv[1] if len(sys.argv) > 1 else "elonmusk"
URL = f"https://syndication.twitter.com/srv/timeline-profile/screen-name/{HANDLE}"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

req = urllib.request.Request(URL, headers={"User-Agent": UA})
status = None
body = ""
headers: dict[str, str] = {}
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        status = resp.status
        headers = {k.lower(): v for k, v in resp.headers.items()}
        body = resp.read(400_000).decode("utf-8", "replace")
except urllib.error.HTTPError as e:
    status = e.code
    headers = {k.lower(): v for k, v in e.headers.items()}
    body = e.read(20_000).decode("utf-8", "replace")
except Exception as e:  # noqa: BLE001
    print(json.dumps({"verdict": "ERROR", "error": str(e)[:200]}, ensure_ascii=False))
    sys.exit(1)

has_data = "__NEXT_DATA__" in body
server = headers.get("server", "")
cf_mitigated = headers.get("cf-mitigated")
rl_remaining = headers.get("x-rate-limit-remaining")
challenged = bool(cf_mitigated) or "challenge-platform" in body or "cf-challenge" in body

if status == 200 and has_data:
    verdict = "PASS"  # 클라우드 IP 에서 데이터 회수 성공
elif status == 429:
    verdict = "RATE_LIMITED"  # IP당 30/15min 소진 — 차단은 아님
elif challenged or status in (403, 503):
    verdict = "BLOCKED"  # Cloudflare BM 이 이 IP 를 막음 → production 불가 신호
else:
    verdict = f"UNKNOWN({status})"

print(
    json.dumps(
        {
            "verdict": verdict,
            "status": status,
            "has_next_data": has_data,
            "server": server,
            "cf_mitigated": cf_mitigated,
            "x_rate_limit_remaining": rl_remaining,
            "body_sample": body[:160] if not has_data else "(data present)",
        },
        ensure_ascii=False,
        indent=2,
    )
)
