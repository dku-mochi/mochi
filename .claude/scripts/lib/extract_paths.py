#!/usr/bin/env python3
"""OpenAPI ↔ iOS 클라이언트 path 추출 + 정규화 → stdout.

heredoc 으로 인라인했을 때 read-only sandbox 에서 temp file 실패가 발생해서
별도 파일로 분리. 항상 디스크 위 정적 파일이라 환경 의존성 없음.

사용: python3 extract_paths.py <openapi.json> <URLSessionMochiAPIClient.swift>
출력:
  SPEC:
  /sorted/spec/path
  ...
  CLIENT:
  /sorted/client/path
  ...
"""
import json
import re
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: extract_paths.py <openapi.json> <client.swift>", file=sys.stderr)
        return 2

    spec_file, client_file = sys.argv[1], sys.argv[2]

    try:
        with open(spec_file, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"spec read error: {e}", file=sys.stderr)
        return 3

    spec_paths = {
        re.sub(r"\{[^}]+\}", "{var}", p)
        for p in (data.get("paths") or {}).keys()
    }

    try:
        with open(client_file, "r", encoding="utf-8") as f:
            src = f.read()
    except OSError as e:
        print(f"client read error: {e}", file=sys.stderr)
        return 4

    client_paths: set[str] = set()
    # 매칭: "/api/v숫자/...".  Swift string interpolation \(...\) 와 {param} 모두 {var} 로 정규화.
    for m in re.finditer(r'"(/api/v\d+/[^"]+)"', src):
        raw = m.group(1)
        raw = re.sub(r"\\\([^)]*\)", "{var}", raw)
        raw = re.sub(r"\{[^}]+\}", "{var}", raw)
        raw = raw.rstrip("/")
        client_paths.add(raw)

    print("SPEC:")
    for p in sorted(spec_paths):
        print(p)
    print("CLIENT:")
    for p in sorted(client_paths):
        print(p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
