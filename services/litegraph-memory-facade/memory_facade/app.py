from __future__ import annotations

import json
import logging
import os
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from aiohttp import ClientSession, ClientTimeout, web


LOG = logging.getLogger("litegraph_memory_facade")
TOKEN = re.compile(r"[a-z0-9]+")
MEMORY_TYPES = {
    "identity",
    "communication_preference",
    "relationship",
    "work_context",
    "project",
    "goal",
    "preference",
    "routine",
    "constraint",
    "integration_intent",
    "decision",
    "commitment",
}
SENSITIVITY_LEVELS = {"level_1", "level_2", "level_3"}
READY_SCOPES: set[tuple[str, str, str]] = set()


class LiteGraphHttpError(RuntimeError):
    def __init__(self, status: int, detail: str = "") -> None:
        super().__init__(f"litegraph_http_{status}")
        self.status = status
        self.detail = " ".join(detail.split())[:500]


@dataclass(frozen=True)
class Settings:
    litegraph_endpoint: str
    litegraph_api_key: str
    tenant_guid: str
    graph_guid: str
    port: int = 8710
    timeout_seconds: float = 5.0

    @classmethod
    def from_env(cls) -> "Settings":
        values = {
            "LITEGRAPH_ENDPOINT": os.getenv("LITEGRAPH_ENDPOINT", "").rstrip("/"),
            "LITEGRAPH_API_KEY": os.getenv("LITEGRAPH_API_KEY", ""),
            "MCP_TENANT_GUID": os.getenv("MCP_TENANT_GUID", ""),
            "MCP_GRAPH_GUID": os.getenv("MCP_GRAPH_GUID", ""),
        }
        missing = [name for name, value in values.items() if not value]
        if missing:
            raise RuntimeError(f"missing required environment: {', '.join(missing)}")
        return cls(
            litegraph_endpoint=values["LITEGRAPH_ENDPOINT"],
            litegraph_api_key=values["LITEGRAPH_API_KEY"],
            tenant_guid=values["MCP_TENANT_GUID"],
            graph_guid=values["MCP_GRAPH_GUID"],
            port=int(os.getenv("PORT", "8710")),
            timeout_seconds=float(os.getenv("UPSTREAM_TIMEOUT_SECONDS", "5")),
        )


def tool_catalog() -> list[dict[str, Any]]:
    return [
        {
            "name": "memory_search",
            "description": "Search authorized personal memory by meaning or keywords.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "minLength": 1},
                    "max_results": {"type": "integer", "minimum": 1, "maximum": 10},
                },
                "required": ["query"],
                "additionalProperties": False,
            },
            "annotations": {"readOnlyHint": True},
        },
        {
            "name": "memory_get",
            "description": "Read one authorized memory using its memory_id.",
            "inputSchema": {
                "type": "object",
                "properties": {"memory_id": {"type": "string", "minLength": 1}},
                "required": ["memory_id"],
                "additionalProperties": False,
            },
            "annotations": {"readOnlyHint": True},
        },
        {
            "name": "memory_store",
            "description": (
                "Store one durable, atomic memory for the authenticated owner. "
                "Use only for stable facts, preferences, relationships, projects, "
                "goals, routines, constraints, decisions, commitments, or integration "
                "intentions. This is append-only; corrections supersede prior memories."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "memory_type": {"type": "string", "enum": sorted(MEMORY_TYPES)},
                    "subject": {"type": "string", "minLength": 1, "maxLength": 160},
                    "content": {"type": "string", "minLength": 1, "maxLength": 2000},
                    "sensitivity": {
                        "type": "string",
                        "enum": sorted(SENSITIVITY_LEVELS),
                        "default": "level_3",
                    },
                    "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                    "source_session_ref": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 200,
                    },
                    "source_thread_ref": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 200,
                    },
                    "valid_from": {"type": "string", "format": "date-time"},
                    "supersedes_memory_id": {"type": "string", "format": "uuid"},
                },
                "required": [
                    "memory_type",
                    "subject",
                    "content",
                    "confidence",
                    "source_session_ref",
                    "source_thread_ref",
                ],
                "additionalProperties": False,
            },
            "annotations": {
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": True,
            },
        },
    ]


def _node_id(node: dict[str, Any]) -> str:
    return str(node.get("GUID") or node.get("Guid") or node.get("guid") or "")


def _node_text(node: dict[str, Any]) -> str:
    return json.dumps(node, ensure_ascii=False, sort_keys=True).lower()


def rank_nodes(nodes: list[dict[str, Any]], query: str, limit: int) -> list[dict[str, Any]]:
    terms = set(TOKEN.findall(query.lower()))
    ranked: list[tuple[int, dict[str, Any]]] = []
    for node in nodes:
        text = _node_text(node)
        score = sum(1 for term in terms if term in text)
        if score:
            ranked.append((score, node))
    ranked.sort(key=lambda pair: (-pair[0], _node_text(pair[1])))
    return [node for _, node in ranked[:limit]]


async def litegraph_request(
    settings: Settings,
    method: str,
    path: str,
    *,
    params: dict[str, str] | None = None,
    json_body: dict[str, Any] | None = None,
) -> Any:
    timeout = ClientTimeout(total=settings.timeout_seconds)
    headers = {"Authorization": f"Bearer {settings.litegraph_api_key}"}
    async with ClientSession(timeout=timeout) as session:
        async with session.request(
            method,
            f"{settings.litegraph_endpoint}{path}",
            headers=headers,
            params=params,
            json=json_body,
        ) as response:
            body = await response.text()
            if response.status >= 400:
                raise LiteGraphHttpError(response.status, body)
            return json.loads(body) if body else None


async def _resource_exists(settings: Settings, path: str) -> bool:
    try:
        await litegraph_request(settings, "HEAD", path)
        return True
    except LiteGraphHttpError as error:
        if error.status == 404:
            return False
        if error.status == 400 and "no graph with guid" in error.detail.lower():
            return False
        raise


async def ensure_memory_scope(settings: Settings) -> None:
    """Create the one configured tenant and graph when ephemeral storage is empty."""
    scope = (settings.litegraph_endpoint, settings.tenant_guid, settings.graph_guid)
    if scope in READY_SCOPES:
        return

    tenant_path = f"/v1.0/tenants/{settings.tenant_guid}"
    if not await _resource_exists(settings, tenant_path):
        try:
            await litegraph_request(
                settings,
                "PUT",
                "/v1.0/tenants",
                json_body={
                    "GUID": settings.tenant_guid,
                    "Name": "2-memory-poc",
                    "Active": True,
                },
            )
            LOG.warning("memory_scope_tenant_created tenant=%s", settings.tenant_guid)
        except LiteGraphHttpError as error:
            if error.status != 409:
                raise

    graph_path = (
        f"/v1.0/tenants/{settings.tenant_guid}/graphs/{settings.graph_guid}"
    )
    if not await _resource_exists(settings, graph_path):
        try:
            await litegraph_request(
                settings,
                "PUT",
                f"/v1.0/tenants/{settings.tenant_guid}/graphs",
                json_body={
                    "TenantGUID": settings.tenant_guid,
                    "GUID": settings.graph_guid,
                    "Name": "2-memory",
                },
            )
            LOG.warning("memory_scope_graph_created graph=%s", settings.graph_guid)
        except LiteGraphHttpError as error:
            if error.status != 409:
                raise

    READY_SCOPES.add(scope)


async def search_memory(settings: Settings, arguments: dict[str, Any]) -> dict[str, Any]:
    await ensure_memory_scope(settings)
    query = str(arguments.get("query", "")).strip()
    if not query:
        raise ValueError("query_required")
    limit = min(max(int(arguments.get("max_results", 5)), 1), 10)
    base = f"/v1.0/tenants/{settings.tenant_guid}/graphs/{settings.graph_guid}/nodes"
    payload = await litegraph_request(
        settings,
        "GET",
        base,
        params={"max-keys": "1000", "incldata": "true", "inclsub": "false"},
    )
    if isinstance(payload, dict):
        nodes = payload.get("Objects") or payload.get("objects") or payload.get("Nodes") or []
    elif isinstance(payload, list):
        nodes = payload
    else:
        nodes = []
    matches = rank_nodes([node for node in nodes if isinstance(node, dict)], query, limit)
    return {
        "query": query,
        "matches": [
            {
                "memory_id": _node_id(node),
                "name": node.get("Name") or node.get("name"),
                "content": node.get("Data") or node.get("data"),
            }
            for node in matches
        ],
    }


async def get_memory(settings: Settings, arguments: dict[str, Any]) -> dict[str, Any]:
    await ensure_memory_scope(settings)
    memory_id = str(arguments.get("memory_id", "")).strip()
    if not memory_id or "/" in memory_id or ".." in memory_id:
        raise ValueError("invalid_memory_id")
    path = (
        f"/v1.0/tenants/{settings.tenant_guid}/graphs/{settings.graph_guid}"
        f"/nodes/{memory_id}"
    )
    node = await litegraph_request(
        settings, "GET", path, params={"incldata": "true", "inclsub": "false"}
    )
    return {
        "memory_id": _node_id(node),
        "name": node.get("Name") or node.get("name"),
        "content": node.get("Data") or node.get("data"),
    }


def build_memory_node(settings: Settings, arguments: dict[str, Any]) -> dict[str, Any]:
    memory_type = str(arguments.get("memory_type", "")).strip()
    subject = str(arguments.get("subject", "")).strip()
    content = str(arguments.get("content", "")).strip()
    sensitivity = str(arguments.get("sensitivity", "level_3")).strip()
    source_session_ref = str(arguments.get("source_session_ref", "")).strip()
    source_thread_ref = str(arguments.get("source_thread_ref", "")).strip()
    supersedes = str(arguments.get("supersedes_memory_id", "")).strip() or None
    try:
        confidence = float(arguments.get("confidence"))
    except (TypeError, ValueError):
        raise ValueError("invalid_confidence") from None

    if memory_type not in MEMORY_TYPES:
        raise ValueError("invalid_memory_type")
    if not subject or len(subject) > 160:
        raise ValueError("invalid_subject")
    if not content or len(content) > 2000:
        raise ValueError("invalid_content")
    if sensitivity not in SENSITIVITY_LEVELS:
        raise ValueError("invalid_sensitivity")
    if not 0 <= confidence <= 1:
        raise ValueError("invalid_confidence")
    if not source_session_ref or len(source_session_ref) > 200:
        raise ValueError("invalid_source_session_ref")
    if not source_thread_ref or len(source_thread_ref) > 200:
        raise ValueError("invalid_source_thread_ref")
    if supersedes:
        try:
            uuid.UUID(supersedes)
        except ValueError:
            raise ValueError("invalid_supersedes_memory_id") from None

    valid_from = str(arguments.get("valid_from", "")).strip() or None
    if valid_from:
        try:
            datetime.fromisoformat(valid_from.replace("Z", "+00:00"))
        except ValueError:
            raise ValueError("invalid_valid_from") from None

    canonical = "\n".join(
        [memory_type, subject.casefold(), " ".join(content.casefold().split())]
    )
    memory_id = str(uuid.uuid5(uuid.UUID(settings.graph_guid), canonical))
    captured_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    return {
        "TenantGUID": settings.tenant_guid,
        "GraphGUID": settings.graph_guid,
        "GUID": memory_id,
        "Name": f"memory:{memory_type}:{memory_id}",
        "Labels": ["Memory", memory_type],
        "Tags": {
            "sensitivity": sensitivity,
            "status": "active",
            "schema_version": "memory-v1",
        },
        "Data": {
            "schema_version": "memory-v1",
            "memory_type": memory_type,
            "subject": subject,
            "content": content,
            "sensitivity": sensitivity,
            "confidence": confidence,
            "status": "active",
            "source_session_ref": source_session_ref,
            "source_thread_ref": source_thread_ref,
            "valid_from": valid_from,
            "captured_at": captured_at,
            "supersedes_memory_id": supersedes,
        },
    }


async def store_memory(settings: Settings, arguments: dict[str, Any]) -> dict[str, Any]:
    await ensure_memory_scope(settings)
    node = build_memory_node(settings, arguments)
    memory_id = node["GUID"]
    item_path = (
        f"/v1.0/tenants/{settings.tenant_guid}/graphs/{settings.graph_guid}"
        f"/nodes/{memory_id}"
    )
    if await _resource_exists(settings, item_path):
        return {
            "memory_id": memory_id,
            "stored": False,
            "duplicate": True,
            "sensitivity": node["Data"]["sensitivity"],
        }

    base = f"/v1.0/tenants/{settings.tenant_guid}/graphs/{settings.graph_guid}/nodes"
    created = await litegraph_request(settings, "PUT", base, json_body=node)
    return {
        "memory_id": _node_id(created) or memory_id,
        "stored": True,
        "duplicate": False,
        "sensitivity": node["Data"]["sensitivity"],
    }


def rpc_result(request_id: Any, result: Any) -> web.Response:
    return web.json_response({"jsonrpc": "2.0", "id": request_id, "result": result})


def rpc_error(request_id: Any, code: int, message: str) -> web.Response:
    return web.json_response(
        {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}
    )


async def mcp(request: web.Request) -> web.Response:
    settings: Settings = request.app["settings"]
    try:
        payload = await request.json()
    except (json.JSONDecodeError, ValueError):
        return rpc_error(None, -32700, "parse_error")
    request_id = payload.get("id")
    method = payload.get("method")
    if method == "initialize":
        return rpc_result(
            request_id,
            {
                "protocolVersion": "2025-03-26",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "litegraph-memory-facade", "version": "0.1.0"},
            },
        )
    if method == "notifications/initialized":
        return web.Response(status=202)
    if method == "tools/list":
        return rpc_result(request_id, {"tools": tool_catalog()})
    if method != "tools/call":
        return rpc_error(request_id, -32601, "method_not_found")
    params = payload.get("params") or {}
    name = str(params.get("name", ""))
    arguments = params.get("arguments") or {}
    try:
        if name == "memory_search":
            result = await search_memory(settings, arguments)
        elif name == "memory_get":
            result = await get_memory(settings, arguments)
        elif name == "memory_store":
            result = await store_memory(settings, arguments)
        else:
            return rpc_error(request_id, -32601, "tool_not_found")
        text = json.dumps(result, ensure_ascii=False)
        LOG.info("memory_tool_completed tool=%s", name)
        return rpc_result(
            request_id,
            {
                "content": [{"type": "text", "text": text}],
                "structuredContent": result,
                "isError": False,
            },
        )
    except ValueError as error:
        return rpc_error(request_id, -32602, str(error))
    except Exception as error:
        LOG.exception("memory_tool_failed tool=%s error_type=%s", name, type(error).__name__)
        return rpc_error(request_id, -32000, "memory_backend_unavailable")


async def health(_: web.Request) -> web.Response:
    return web.json_response(
        {"status": "ok", "tools": [tool["name"] for tool in tool_catalog()]}
    )


def build_app(settings: Settings) -> web.Application:
    app = web.Application(client_max_size=64 * 1024)
    app["settings"] = settings
    app.router.add_post("/mcp", mcp)
    app.router.add_get("/health", health)
    return app


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    settings = Settings.from_env()
    web.run_app(build_app(settings), host="0.0.0.0", port=settings.port)


if __name__ == "__main__":
    main()
