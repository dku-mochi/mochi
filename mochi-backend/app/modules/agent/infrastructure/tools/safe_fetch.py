"""SSRF 가드 + 연결-핀 페치 — ``web_fetch`` · ``platform_context`` 공유.

두 툴이 각자 복사본을 들고 있어 fix-drift 위험이 있었다(한쪽만 고치면 다른 쪽에 구멍). 단일 지점으로 모은다.

차단: 블록리스트 호스트 + 호스트 리터럴 IP + 모든 A/AAAA 응답의 사설/링크로컬/루프백/멀티캐스트/
예약/미지정 IP. **IPv4-mapped IPv6(``::ffff:a.b.c.d``)는 unwrap 후 판정** — IPv6 객체의 ``is_loopback``
등은 내부 IPv4 를 반영하지 않아 ``::ffff:127.0.0.1`` 같은 인코딩 우회가 가능했다.

**연결-핀(TOCTOU 차단)**: 검증한 IP 와 httpx 가 연결 시 재해석하는 IP 가 분리되면 권한 DNS 통제 공격자가
검증↔연결 사이에 사설 IP 로 rebinding 할 수 있다. ``guarded_get`` 은 호스트를 한 번 resolve·검증한 뒤
**검증한 IP 로 직접 연결**하고(URL host→IP), 원본 host 를 SNI(``extensions['sni_hostname']``)와 Host
헤더로 보존해 TLS 인증서 검증·가상호스팅을 유지한다. 매 redirect hop 도 동일하게 핀한다.
"""

import ipaddress
import socket
from urllib.parse import urlparse, urlunparse

import httpx

from app.modules.agent.domain.tools import ToolExecutionError, ToolName

IPAddress = ipaddress.IPv4Address | ipaddress.IPv6Address


def is_blocked_ip(ip: IPAddress) -> bool:
    """사설/루프백/링크로컬/멀티캐스트/예약/미지정이면 True. IPv4-mapped IPv6 는 내부 IPv4 로 unwrap."""
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
    )


def resolve_pinned_ip(url: str, blocked_hosts: tuple[str, ...], *, tool_name: ToolName) -> tuple[str, str]:
    """URL host 의 SSRF 정책 검증 + 연결할 IP 선택. ``(host, ip)`` 반환, 위반 시 ``ToolExecutionError``.

    호스트 리터럴 IP 면 그것을, 아니면 모든 A/AAAA 를 검증하고 첫 안전한 IP 를 핀 대상으로 돌려준다
    (응답 중 하나라도 사설이면 rebinding 으로 보고 전체 거부).
    """
    parsed = urlparse(url)
    try:
        _ = parsed.port  # 비정상 포트(non-numeric/범위초과)는 ValueError — redirect Location 은 미검증이라
    except ValueError as exc:  # 여기서 raw ValueError 가 새지 않게 ToolExecutionError 로 정규화.
        raise ToolExecutionError(tool_name, f"Invalid port in URL: {url}") from exc
    host = parsed.hostname
    if not host:
        raise ToolExecutionError(tool_name, "URL has no host")
    if host.lower() in blocked_hosts:
        raise ToolExecutionError(tool_name, f"Blocked host: {host}")

    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        literal = None
    if literal is not None:
        if is_blocked_ip(literal):
            raise ToolExecutionError(tool_name, f"Blocked IP {literal} for host {host}")
        return host, host

    try:
        infos = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    except OSError as exc:
        raise ToolExecutionError(tool_name, f"DNS resolution failed for {host}") from exc
    pinned: str | None = None
    seen: set[str] = set()
    for info in infos:
        addr = str(info[4][0])
        if addr in seen:
            continue
        seen.add(addr)
        try:
            ip = ipaddress.ip_address(addr)
        except ValueError:
            continue
        if is_blocked_ip(ip):
            raise ToolExecutionError(tool_name, f"Blocked IP {ip} for host {host}")
        if pinned is None:
            pinned = addr
    if pinned is None:
        raise ToolExecutionError(tool_name, f"No usable address for {host}")
    return host, pinned


def pin_url(url: str, ip: str) -> str:
    """URL 의 host 를 검증된 IP 로 치환(IPv6 는 brackets). scheme/port/path/query/userinfo 보존."""
    p = urlparse(url)
    host_part = f"[{ip}]" if ":" in ip else ip
    netloc = f"{host_part}:{p.port}" if p.port is not None else host_part
    if p.username:
        cred = p.username + (f":{p.password}" if p.password is not None else "")
        netloc = f"{cred}@{netloc}"
    return urlunparse(p._replace(netloc=netloc))


def host_header(url: str) -> str:
    """원본 host[:port] — 핀한 IP 로 연결할 때 Host 헤더로 보존(가상호스팅 라우팅)."""
    p = urlparse(url)
    h = p.hostname or ""
    if ":" in h:  # 리터럴 IPv6 host
        h = f"[{h}]"
    return f"{h}:{p.port}" if p.port is not None else h


async def guarded_get(
    client: httpx.AsyncClient,
    url: str,
    *,
    blocked_hosts: tuple[str, ...],
    tool_name: ToolName,
    max_redirects: int = 5,
) -> tuple[httpx.Response, str]:
    """SSRF 검증 + 연결-핀 GET. 검증한 IP 로 직접 연결하고 host 를 SNI/Host 로 보존. 매 redirect 재핀.

    ``client`` 는 ``follow_redirects=False`` 여야 한다(호출부 책임). ``(response, final_logical_url)`` 반환 —
    final_url 은 IP 가 아니라 hostname 기반(사용자 표면)으로 돌려준다. 응답 본문은 호출부가 읽는다.
    """
    logical_url = url
    for _ in range(max_redirects + 1):
        host, ip = resolve_pinned_ip(logical_url, blocked_hosts, tool_name=tool_name)
        pinned = pin_url(logical_url, ip)
        try:
            response = await client.get(
                pinned,
                extensions={"sni_hostname": host},
                headers={"Host": host_header(logical_url)},
            )
        except httpx.HTTPError as exc:
            raise ToolExecutionError(tool_name, f"HTTP error: {exc}", transient=True) from exc

        if response.is_redirect:
            location = response.headers.get("location")
            if not location:
                raise ToolExecutionError(tool_name, "Redirect without Location header")
            # 상대 redirect 는 IP 가 아니라 hostname URL 기준으로 join(다음 hop 에서 다시 핀).
            logical_url = str(httpx.URL(logical_url).join(location))
            continue
        return response, logical_url
    raise ToolExecutionError(tool_name, "Too many redirects")
