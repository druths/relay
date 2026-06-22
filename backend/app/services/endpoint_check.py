"""Per-agent endpoint diagnostics.

Returns a structured report of probes (DNS, HTTP reachability, auth, model
listing, websocket-where-applicable, internal connection-registry state)
that the clients render in a modal. Surfaces the kind of detail a user
needs when an agent is hanging — most often "the LLM endpoint is up but
the registered websocket dropped" or "auth is rejected" or "the model
name isn't on the provider's list."

Each provider has its own pipeline; common helpers (`_check_dns`,
`_check_http`) live at the top. Each check returns a `CheckResult` with
a `status` (ok/warn/fail/skip), a short `detail` line for the summary,
and an `extra` dict for the full technical-detail view.
"""

from __future__ import annotations

import asyncio
import logging
import socket
import time
from dataclasses import asdict, dataclass, field
from typing import Any, Literal
from urllib.parse import urlparse

import httpx

from app.models.agent import Agent
from app.services.agent_manager import resolve_llm_config

logger = logging.getLogger(__name__)


CheckStatus = Literal["ok", "warn", "fail", "skip"]
SummaryStatus = Literal["healthy", "degraded", "down"]


@dataclass
class CheckResult:
    name: str
    status: CheckStatus
    detail: str
    elapsed_ms: int | None = None
    extra: dict[str, Any] = field(default_factory=dict)


@dataclass
class EndpointReport:
    agent_id: str
    agent_name: str
    provider: str
    model: str
    base_url: str | None
    summary_status: SummaryStatus
    summary_message: str
    checks: list[CheckResult]
    raw: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "agent_id": self.agent_id,
            "agent_name": self.agent_name,
            "provider": self.provider,
            "model": self.model,
            "base_url": self.base_url,
            "summary_status": self.summary_status,
            "summary_message": self.summary_message,
            "checks": [asdict(c) for c in self.checks],
            "raw": self.raw,
        }


# ── Common helpers ──────────────────────────────────────────────────


async def _check_dns(host: str, name: str = "DNS resolution") -> CheckResult:
    """Resolve the host via getaddrinfo with a 3s budget. Returns the first
    answer and the lookup latency."""
    start = time.perf_counter()
    try:
        infos = await asyncio.wait_for(
            asyncio.to_thread(socket.getaddrinfo, host, None),
            timeout=3.0,
        )
    except asyncio.TimeoutError:
        return CheckResult(
            name=name, status="fail",
            detail=f"{host} — timed out after 3s",
            elapsed_ms=3000,
        )
    except socket.gaierror as exc:
        elapsed = int((time.perf_counter() - start) * 1000)
        return CheckResult(
            name=name, status="fail",
            detail=f"{host} — {exc.strerror or exc}",
            elapsed_ms=elapsed,
        )
    elapsed = int((time.perf_counter() - start) * 1000)
    addresses = sorted({info[4][0] for info in infos})
    return CheckResult(
        name=name, status="ok",
        detail=f"{host} → {addresses[0]}"
               + (f" (+{len(addresses) - 1} more)" if len(addresses) > 1 else ""),
        elapsed_ms=elapsed,
        extra={"addresses": addresses},
    )


async def _check_http(
    url: str,
    *,
    name: str,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: Any = None,
    timeout: float = 10.0,
    expect_status: tuple[int, ...] = (200,),
    warn_status: tuple[int, ...] = (),
    capture_body: bool = False,
) -> tuple[CheckResult, httpx.Response | None]:
    """Run a single HTTP probe. Returns a CheckResult plus the raw response
    so the caller can inspect/parse it if status is acceptable."""
    start = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            resp = await client.request(
                method=method, url=url, headers=headers or {}, json=body,
            )
    except httpx.ConnectError as exc:
        elapsed = int((time.perf_counter() - start) * 1000)
        return CheckResult(
            name=name, status="fail",
            detail=f"{method} {url} — connection refused ({exc})",
            elapsed_ms=elapsed,
        ), None
    except httpx.ConnectTimeout:
        elapsed = int((time.perf_counter() - start) * 1000)
        return CheckResult(
            name=name, status="fail",
            detail=f"{method} {url} — connect timed out after {int(timeout * 1000)}ms",
            elapsed_ms=elapsed,
        ), None
    except httpx.ReadTimeout:
        elapsed = int((time.perf_counter() - start) * 1000)
        return CheckResult(
            name=name, status="fail",
            detail=f"{method} {url} — read timed out after {int(timeout * 1000)}ms",
            elapsed_ms=elapsed,
        ), None
    except Exception as exc:
        elapsed = int((time.perf_counter() - start) * 1000)
        return CheckResult(
            name=name, status="fail",
            detail=f"{method} {url} — {type(exc).__name__}: {exc}",
            elapsed_ms=elapsed,
        ), None

    elapsed = int((time.perf_counter() - start) * 1000)
    status_code = resp.status_code
    if status_code in expect_status:
        status: CheckStatus = "ok"
    elif status_code in warn_status:
        status = "warn"
    else:
        status = "fail"

    extra: dict[str, Any] = {
        "status_code": status_code,
        "headers": dict(resp.headers),
    }
    if capture_body:
        # Limit captured body to avoid blowing up the modal.
        try:
            text = resp.text
            extra["body"] = text if len(text) <= 4096 else (text[:4096] + "…[truncated]")
        except Exception:
            extra["body"] = "(unreadable)"

    return CheckResult(
        name=name, status=status,
        detail=f"{method} {url} → {status_code} in {elapsed}ms",
        elapsed_ms=elapsed,
        extra=extra,
    ), resp


def _host_of(url: str) -> str | None:
    try:
        return urlparse(url).hostname
    except Exception:
        return None


def _summarize(checks: list[CheckResult]) -> tuple[SummaryStatus, str]:
    fails = [c for c in checks if c.status == "fail"]
    warns = [c for c in checks if c.status == "warn"]
    ok_count = sum(1 for c in checks if c.status == "ok")
    total = len([c for c in checks if c.status != "skip"])
    if fails:
        return "down", f"{fails[0].name} failed: {fails[0].detail}"
    if warns:
        return "degraded", f"{ok_count}/{total} checks passed; {warns[0].name} returned a warning"
    if total == 0:
        return "down", "No checks were runnable"
    elapsed_avg = int(
        sum((c.elapsed_ms or 0) for c in checks if c.status == "ok")
        / max(1, ok_count)
    )
    return "healthy", f"All {total} checks passed (avg {elapsed_avg}ms)"


# ── Provider pipelines ──────────────────────────────────────────────


async def _check_ark(base_url: str | None, api_key: str | None, agent_name: str) -> tuple[list[CheckResult], dict[str, Any]]:
    """Ark-specific pipeline. The interesting bits over and above generic
    HTTP reachability are: (1) the `/agents` listing confirms auth and
    that the configured agent name actually exists on the server, (2) a
    `/events` WebSocket probe confirms the live channel works, and (3)
    we report the state of Relay's own registered ark connection — that's
    the one that actually drives turns, and it can be dead while the
    HTTP endpoint is fine."""
    checks: list[CheckResult] = []
    raw: dict[str, Any] = {}

    if not base_url:
        checks.append(CheckResult(
            name="Configuration", status="fail",
            detail="No base URL configured for this ark agent",
        ))
        return checks, raw

    base = base_url.rstrip("/")
    raw["base_url"] = base
    host = _host_of(base) or base

    checks.append(await _check_dns(host))
    if checks[-1].status == "fail":
        return checks, raw

    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}

    # Listing agents — also confirms auth and lets us flag a typo'd agent name.
    agents_check, resp = await _check_http(
        f"{base}/agents",
        name="List agents (auth)",
        headers=headers,
        timeout=8.0,
        warn_status=(401, 403),
        capture_body=True,
    )
    checks.append(agents_check)
    available_agents: list[str] = []
    if resp is not None and resp.status_code == 200:
        try:
            data = resp.json()
            entries = data if isinstance(data, list) else data.get("agents", [])
            for entry in entries:
                if isinstance(entry, str):
                    available_agents.append(entry)
                elif isinstance(entry, dict):
                    nm = entry.get("name") or entry.get("agent_name") or entry.get("id")
                    if nm:
                        available_agents.append(str(nm))
            raw["available_agents"] = available_agents
        except Exception as exc:
            checks.append(CheckResult(
                name="Parse agents listing", status="warn",
                detail=f"Couldn't parse /agents response: {exc}",
            ))

    # Agent-name match check.
    if available_agents:
        if agent_name in available_agents:
            checks.append(CheckResult(
                name="Agent name on server", status="ok",
                detail=f"'{agent_name}' is registered ({len(available_agents)} agent(s) total)",
                extra={"matched": agent_name},
            ))
        else:
            checks.append(CheckResult(
                name="Agent name on server", status="warn",
                detail=f"'{agent_name}' not in server's agent list — known: {', '.join(available_agents[:5])}"
                       + ("…" if len(available_agents) > 5 else ""),
                extra={"configured": agent_name, "available": available_agents},
            ))

    # WebSocket probe.
    ws_url = base.replace("http://", "ws://", 1).replace("https://", "wss://", 1) + "/events"
    raw["ws_url"] = ws_url
    checks.append(await _check_websocket(ws_url, headers=headers))

    # Internal connection-registry inspection.
    checks.append(_inspect_ark_registry(base, api_key))

    return checks, raw


async def _check_websocket(url: str, *, headers: dict[str, str]) -> CheckResult:
    """Open a websocket, wait for it to be connected, close cleanly. Times
    out aggressively because if /events takes more than a couple seconds
    to accept the connection, something is wrong upstream."""
    import websockets

    start = time.perf_counter()
    try:
        ws = await asyncio.wait_for(
            websockets.connect(url, additional_headers=headers, max_size=None),
            timeout=5.0,
        )
    except asyncio.TimeoutError:
        return CheckResult(
            name="WebSocket /events", status="fail",
            detail=f"Connect timed out after 5s ({url})",
            elapsed_ms=5000,
        )
    except Exception as exc:
        elapsed = int((time.perf_counter() - start) * 1000)
        return CheckResult(
            name="WebSocket /events", status="fail",
            detail=f"{type(exc).__name__}: {exc}",
            elapsed_ms=elapsed,
            extra={"url": url},
        )
    elapsed = int((time.perf_counter() - start) * 1000)
    try:
        await ws.close()
    except Exception:
        pass
    return CheckResult(
        name="WebSocket /events", status="ok",
        detail=f"Connected in {elapsed}ms, closed cleanly",
        elapsed_ms=elapsed,
        extra={"url": url},
    )


def _inspect_ark_registry(base_url: str, api_key: str | None) -> CheckResult:
    """Look up Relay's persistent ark connection for this (url, key) pair
    and report its liveness. This is the connection that actually drives
    turns — when an agent 'hangs forever' it's usually because this
    websocket died but the connection object is still in the registry."""
    from app.services.llm.ark import _conn_key, get_connection_by_key

    key = _conn_key(base_url, api_key)
    conn = get_connection_by_key(key)
    if conn is None:
        return CheckResult(
            name="Relay ark connection", status="warn",
            detail="No connection in Relay's registry — will be opened on next turn",
            extra={"key": key},
        )
    ws_open = conn._ws is not None and not conn._closed
    in_flight = list(conn._turn_queues.keys())
    extra = {
        "key": key,
        "ws_open": ws_open,
        "closed_flag": conn._closed,
        "in_flight_turn_ids": in_flight,
        "in_flight_turn_count": len(in_flight),
        "server_id": conn.server_id,
    }
    if not ws_open:
        return CheckResult(
            name="Relay ark connection", status="fail",
            detail=f"Registered connection has no live WS (closed={conn._closed})",
            extra=extra,
        )
    return CheckResult(
        name="Relay ark connection", status="ok",
        detail=f"WS open, {len(in_flight)} turn(s) in flight",
        extra=extra,
    )


async def _check_openai_compatible(
    base_url: str | None,
    api_key: str | None,
    model: str,
    *,
    default_base: str = "https://api.openai.com/v1",
    auth_style: Literal["bearer", "x-api-key"] = "bearer",
    provider_label: str = "OpenAI",
) -> tuple[list[CheckResult], dict[str, Any]]:
    """Pipeline for any provider that exposes a `/models` listing and uses
    bearer-token auth. Covers OpenAI, Ollama, openai-compatible deployments,
    and (with header tweaks) Anthropic."""
    checks: list[CheckResult] = []
    raw: dict[str, Any] = {}
    base = (base_url or default_base).rstrip("/")
    raw["base_url"] = base

    host = _host_of(base) or base
    checks.append(await _check_dns(host))
    if checks[-1].status == "fail":
        return checks, raw

    if not api_key:
        checks.append(CheckResult(
            name="API key", status="fail",
            detail=f"No {provider_label} API key configured (per-agent or platform default)",
        ))
        return checks, raw

    headers: dict[str, str]
    if auth_style == "bearer":
        headers = {"Authorization": f"Bearer {api_key}"}
    else:  # x-api-key (Anthropic)
        headers = {"x-api-key": api_key, "anthropic-version": "2023-06-01"}

    models_check, resp = await _check_http(
        f"{base}/models",
        name="List models (auth)",
        headers=headers,
        timeout=10.0,
        warn_status=(401, 403, 404),
        capture_body=True,
    )
    checks.append(models_check)

    if resp is not None and resp.status_code == 200:
        try:
            data = resp.json()
            items = data.get("data") or data.get("models") or []
            ids = [m.get("id") or m.get("name") for m in items if isinstance(m, dict)]
            ids = [i for i in ids if i]
            raw["available_models"] = ids
            if ids:
                if model in ids:
                    checks.append(CheckResult(
                        name="Model available", status="ok",
                        detail=f"'{model}' is in the server's model list ({len(ids)} total)",
                        extra={"matched": model},
                    ))
                else:
                    checks.append(CheckResult(
                        name="Model available", status="warn",
                        detail=f"'{model}' not in server's model list — known: {', '.join(ids[:5])}"
                               + ("…" if len(ids) > 5 else ""),
                        extra={"configured": model, "available_count": len(ids)},
                    ))
        except Exception as exc:
            checks.append(CheckResult(
                name="Parse models listing", status="warn",
                detail=f"Couldn't parse /models response: {exc}",
            ))

    return checks, raw


async def _check_gemini(
    base_url: str | None, api_key: str | None, model: str,
) -> tuple[list[CheckResult], dict[str, Any]]:
    """Gemini's model-list endpoint takes the key as a query param, not a
    header. Otherwise the shape mirrors the OpenAI-compatible pipeline."""
    checks: list[CheckResult] = []
    raw: dict[str, Any] = {}
    base = (base_url or "https://generativelanguage.googleapis.com").rstrip("/")
    raw["base_url"] = base

    host = _host_of(base) or base
    checks.append(await _check_dns(host))
    if checks[-1].status == "fail":
        return checks, raw

    if not api_key:
        checks.append(CheckResult(
            name="API key", status="fail",
            detail="No Gemini API key configured",
        ))
        return checks, raw

    url = f"{base}/v1beta/models?key={api_key}"
    models_check, resp = await _check_http(
        url, name="List models (auth)",
        timeout=10.0, warn_status=(401, 403),
        capture_body=True,
    )
    # Redact the key from the URL we display.
    models_check.detail = models_check.detail.replace(api_key, "•••")
    checks.append(models_check)

    if resp is not None and resp.status_code == 200:
        try:
            data = resp.json()
            items = data.get("models", [])
            # Gemini model names come back like "models/gemini-2.5-flash".
            ids = []
            for m in items:
                nm = m.get("name", "") if isinstance(m, dict) else ""
                ids.append(nm.split("/")[-1] if nm.startswith("models/") else nm)
            ids = [i for i in ids if i]
            raw["available_models"] = ids
            if ids:
                if model in ids:
                    checks.append(CheckResult(
                        name="Model available", status="ok",
                        detail=f"'{model}' is in the model list ({len(ids)} total)",
                    ))
                else:
                    checks.append(CheckResult(
                        name="Model available", status="warn",
                        detail=f"'{model}' not in model list — known: {', '.join(ids[:5])}"
                               + ("…" if len(ids) > 5 else ""),
                        extra={"configured": model, "available_count": len(ids)},
                    ))
        except Exception as exc:
            checks.append(CheckResult(
                name="Parse models listing", status="warn",
                detail=f"Couldn't parse response: {exc}",
            ))

    return checks, raw


# ── Public entry point ─────────────────────────────────────────────


async def run_endpoint_check(agent: Agent) -> EndpointReport:
    """Dispatch to the provider-specific pipeline and assemble the report."""
    base_url, api_key = await resolve_llm_config(agent)
    provider = agent.llm_provider
    model = agent.llm_model

    if provider == "ark":
        # Strip the optional "ark:" prefix from the model field — ark calls
        # this the "agent name."
        agent_name = model[len("ark:"):] if model.startswith("ark:") else model
        checks, raw = await _check_ark(base_url, api_key, agent_name)
    elif provider == "anthropic":
        checks, raw = await _check_openai_compatible(
            base_url, api_key, model,
            default_base="https://api.anthropic.com/v1",
            auth_style="x-api-key",
            provider_label="Anthropic",
        )
    elif provider == "gemini":
        checks, raw = await _check_gemini(base_url, api_key, model)
    elif provider == "openai":
        checks, raw = await _check_openai_compatible(
            base_url, api_key, model,
            default_base="https://api.openai.com/v1",
            provider_label="OpenAI",
        )
    elif provider == "ollama":
        checks, raw = await _check_openai_compatible(
            base_url, api_key or "ollama", model,
            default_base="http://localhost:11434/v1",
            provider_label="Ollama",
        )
    elif provider in ("openclaw", "openai-compatible"):
        checks, raw = await _check_openai_compatible(
            base_url, api_key, model,
            # No sensible default base for these; _check_openai_compatible
            # will use whatever resolve_llm_config returned (or fail).
            default_base=base_url or "",
            provider_label=provider,
        )
    else:
        checks = [CheckResult(
            name="Provider", status="fail",
            detail=f"Unknown provider '{provider}'",
        )]
        raw = {}

    summary_status, summary_message = _summarize(checks)

    return EndpointReport(
        agent_id=str(agent.agent_id),
        agent_name=agent.name,
        provider=provider,
        model=model,
        base_url=base_url,
        summary_status=summary_status,
        summary_message=summary_message,
        checks=checks,
        raw=raw,
    )
