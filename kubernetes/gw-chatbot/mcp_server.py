"""
Local MCP server – document tools for the AI Gateway chatbot.

Speaks MCP over stdio (JSON-RPC 2.0) so it can be driven by any MCP client,
and is imported directly by app.py for the in-process tool loop.

Tools:
  list_documents  – enumerate uploaded files
  read_document   – return the text of one file
  search_documents – grep across all uploaded files

Documents live in DOCUMENTS_DIR (default: ./documents). Uploads from the web
UI land there too, which is what makes the demo interesting: an attacker can
plant an indirect prompt injection inside a file, and the AI Gateway guardrail
has to catch it on the way through.
"""

import json
import os
import sys
from pathlib import Path

DOCUMENTS_DIR = Path(os.environ.get("DOCUMENTS_DIR", Path(__file__).parent / "documents"))
MAX_CHARS = int(os.environ.get("MCP_MAX_DOC_CHARS", "20000"))

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "gw-chatbot-docs", "version": "1.0.0"}

# ─────────────────────────────────────────
# Tool schemas (advertised over MCP tools/list)
# ─────────────────────────────────────────
TOOLS = [
    {
        "name": "list_documents",
        "description": "List the documents currently available to read.",
        "inputSchema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "read_document",
        "description": "Read the full text of one document by its file name.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "File name, e.g. policy.txt"}
            },
            "required": ["name"],
        },
    },
    {
        "name": "search_documents",
        "description": "Case-insensitive search for a phrase across all documents.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Phrase to look for"}
            },
            "required": ["query"],
        },
    },
]


def _safe_path(name: str) -> Path:
    """Resolve `name` inside DOCUMENTS_DIR, refusing traversal."""
    candidate = (DOCUMENTS_DIR / Path(name).name).resolve()
    root = DOCUMENTS_DIR.resolve()
    if root not in candidate.parents and candidate != root:
        raise ValueError("path outside the documents directory")
    return candidate


def list_documents() -> dict:
    DOCUMENTS_DIR.mkdir(parents=True, exist_ok=True)
    files = []
    for p in sorted(DOCUMENTS_DIR.iterdir()):
        if p.is_file() and not p.name.startswith("."):
            files.append({"name": p.name, "bytes": p.stat().st_size})
    return {"documents": files, "count": len(files)}


def read_document(name: str) -> dict:
    path = _safe_path(name)
    if not path.is_file():
        return {"error": f"no such document: {name}"}
    text = path.read_text(encoding="utf-8", errors="replace")
    truncated = len(text) > MAX_CHARS
    return {"name": path.name, "content": text[:MAX_CHARS], "truncated": truncated}


def search_documents(query: str) -> dict:
    DOCUMENTS_DIR.mkdir(parents=True, exist_ok=True)
    needle = query.lower()
    hits = []
    for p in sorted(DOCUMENTS_DIR.iterdir()):
        if not p.is_file() or p.name.startswith("."):
            continue
        for i, line in enumerate(
            p.read_text(encoding="utf-8", errors="replace").splitlines(), start=1
        ):
            if needle in line.lower():
                hits.append({"document": p.name, "line": i, "text": line.strip()[:300]})
    return {"query": query, "hits": hits, "count": len(hits)}


DISPATCH = {
    "list_documents": lambda a: list_documents(),
    "read_document": lambda a: read_document(a.get("name", "")),
    "search_documents": lambda a: search_documents(a.get("query", "")),
}


def call_tool(name: str, arguments: dict) -> dict:
    """Direct entry point used by app.py (no JSON-RPC envelope)."""
    fn = DISPATCH.get(name)
    if fn is None:
        return {"error": f"unknown tool: {name}"}
    try:
        return fn(arguments or {})
    except Exception as exc:  # surfaced to the model as a tool error
        return {"error": str(exc)}


# ─────────────────────────────────────────
# MCP stdio transport (JSON-RPC 2.0)
# ─────────────────────────────────────────
def _handle(req: dict):
    method = req.get("method")
    req_id = req.get("id")

    if method == "initialize":
        result = {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO,
        }
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        params = req.get("params", {})
        payload = call_tool(params.get("name", ""), params.get("arguments", {}))
        result = {
            "content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False)}],
            "isError": "error" in payload,
        }
    elif method in ("notifications/initialized", "initialized"):
        return None  # notification – no response
    else:
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"method not found: {method}"},
        }

    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            response = _handle(json.loads(line))
        except json.JSONDecodeError:
            response = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": "parse error"},
            }
        if response is not None:
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
