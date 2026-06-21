"""SSRF 공유 가드(`safe_fetch`) 단위 테스트.

web_fetch · platform_context 가 공유하는 호스트 정책 + 연결-핀. 리터럴 IP·DNS 응답·IPv4-mapped 우회,
pin_url/host_header, guarded_get 배선(IP 핀+SNI+Host)을 커버한다.
"""

import socket

import pytest

from app.modules.agent.domain.tools import ToolExecutionError, ToolName
from app.modules.agent.infrastructure.tools import safe_fetch
from app.modules.agent.infrastructure.tools.safe_fetch import (
    guarded_get,
    host_header,
    pin_url,
    resolve_pinned_ip,
)

_NAME = ToolName.WEB_FETCH
_NO_BLOCK: tuple[str, ...] = ()


def _addrinfo(*ips: str) -> list:
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 0)) for ip in ips]


def test_blocklisted_host_rejected() -> None:
    with pytest.raises(ToolExecutionError, match="Blocked host"):
        resolve_pinned_ip("http://localhost/x", ("localhost",), tool_name=_NAME)


def test_private_literal_ip_rejected() -> None:
    with pytest.raises(ToolExecutionError, match="Blocked IP"):
        resolve_pinned_ip("http://10.0.0.1/x", _NO_BLOCK, tool_name=_NAME)


def test_public_literal_ip_ok() -> None:
    resolve_pinned_ip("http://8.8.8.8/x", _NO_BLOCK, tool_name=_NAME)  # no raise


def test_ipv4_mapped_loopback_rejected() -> None:
    # ::ffff:127.0.0.1 — IPv6 객체의 is_loopback 은 False 라 unwrap 없이는 우회됐다.
    with pytest.raises(ToolExecutionError, match="Blocked IP"):
        resolve_pinned_ip("http://[::ffff:127.0.0.1]/x", _NO_BLOCK, tool_name=_NAME)


def test_ipv4_mapped_metadata_rejected() -> None:
    # ::ffff:169.254.169.254 — GCP/AWS 메타데이터(link-local) 의 IPv4-mapped 인코딩 우회.
    with pytest.raises(ToolExecutionError, match="Blocked IP"):
        resolve_pinned_ip("http://[::ffff:169.254.169.254]/x", _NO_BLOCK, tool_name=_NAME)


def test_resolved_private_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(safe_fetch.socket, "getaddrinfo", lambda *a, **k: _addrinfo("10.1.2.3"))
    with pytest.raises(ToolExecutionError, match="Blocked IP"):
        resolve_pinned_ip("https://internal.example/x", _NO_BLOCK, tool_name=_NAME)


def test_resolved_public_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(safe_fetch.socket, "getaddrinfo", lambda *a, **k: _addrinfo("93.184.216.34"))
    resolve_pinned_ip("https://example.com/x", _NO_BLOCK, tool_name=_NAME)  # no raise


def test_resolved_mixed_public_and_private_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    # rebinding 으로 일부 응답만 사설인 경우 — 하나라도 사설이면 전체 거부.
    monkeypatch.setattr(
        safe_fetch.socket, "getaddrinfo", lambda *a, **k: _addrinfo("93.184.216.34", "127.0.0.1")
    )
    with pytest.raises(ToolExecutionError, match="Blocked IP"):
        resolve_pinned_ip("https://rebind.example/x", _NO_BLOCK, tool_name=_NAME)


def test_dns_failure_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    def _boom(*a: object, **k: object) -> list:
        raise OSError("nxdomain")

    monkeypatch.setattr(safe_fetch.socket, "getaddrinfo", _boom)
    with pytest.raises(ToolExecutionError, match="DNS resolution failed"):
        resolve_pinned_ip("https://nope.example/x", _NO_BLOCK, tool_name=_NAME)


def test_url_without_host_rejected() -> None:
    with pytest.raises(ToolExecutionError, match="no host"):
        resolve_pinned_ip("not-a-url", _NO_BLOCK, tool_name=_NAME)


# ---------- 연결-핀 helpers ----------


def test_pin_url_ipv4_preserves_path_query() -> None:
    assert pin_url("https://example.com/a/b?x=1#f", "1.2.3.4") == "https://1.2.3.4/a/b?x=1#f"


def test_pin_url_preserves_port() -> None:
    assert pin_url("https://example.com:8443/a", "1.2.3.4") == "https://1.2.3.4:8443/a"


def test_pin_url_brackets_ipv6() -> None:
    assert pin_url("https://example.com/a", "2606:4700::1111") == "https://[2606:4700::1111]/a"


def test_host_header_without_and_with_port() -> None:
    assert host_header("https://example.com/a") == "example.com"
    assert host_header("https://example.com:8443/a") == "example.com:8443"


def test_resolve_pinned_ip_public_literal() -> None:
    assert resolve_pinned_ip("http://8.8.8.8/x", _NO_BLOCK, tool_name=_NAME) == ("8.8.8.8", "8.8.8.8")


def test_resolve_pinned_ip_returns_resolved_ip(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(safe_fetch.socket, "getaddrinfo", lambda *a, **k: _addrinfo("93.184.216.34"))
    assert resolve_pinned_ip("https://example.com/x", _NO_BLOCK, tool_name=_NAME) == (
        "example.com",
        "93.184.216.34",
    )


def test_resolve_pinned_ip_invalid_port_rejected() -> None:
    # redirect Location 에 비정상 포트가 와도 raw ValueError 가 아니라 ToolExecutionError 로.
    with pytest.raises(ToolExecutionError, match="Invalid port"):
        resolve_pinned_ip("http://evil.example:99999/x", _NO_BLOCK, tool_name=_NAME)


# ---------- guarded_get 배선(핀+SNI+Host) 회귀 가드 ----------


class _StubResponse:
    is_redirect = False
    status_code = 200


class _RecordingClient:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []

    async def get(self, url: str, **kwargs: object) -> _StubResponse:
        self.calls.append((url, dict(kwargs)))
        return _StubResponse()


@pytest.mark.asyncio
async def test_guarded_get_pins_ip_and_preserves_host(monkeypatch: pytest.MonkeyPatch) -> None:
    # 검증한 IP 로 직접 연결하고(URL host→IP), 원본 host 를 SNI·Host 로 보존하는 배선을 고정.
    # httpcore 가 sni_hostname 을 무시하게 회귀하면 별개지만, 최소한 우리 코드가 키를 넘기는지는 가드.
    monkeypatch.setattr(safe_fetch.socket, "getaddrinfo", lambda *a, **k: _addrinfo("93.184.216.34"))
    client = _RecordingClient()
    resp, final = await guarded_get(
        client,  # type: ignore[arg-type]
        "https://example.com/a?x=1",
        blocked_hosts=_NO_BLOCK,
        tool_name=_NAME,
    )
    url, kwargs = client.calls[0]
    assert url == "https://93.184.216.34/a?x=1"  # IP 로 핀
    assert kwargs["extensions"]["sni_hostname"] == "example.com"  # TLS SNI/인증서 검증 = hostname
    assert kwargs["headers"]["Host"] == "example.com"  # 가상호스팅 라우팅 = hostname
    assert final == "https://example.com/a?x=1"  # 반환 final_url 은 IP 아닌 hostname
