// Minimal MCP server over the Streamable HTTP transport (JSON responses only,
// no SSE stream). Kept free of Worker-specific imports so it can be unit tested.

import { SERVER_INSTRUCTIONS, TOOLS, TOOL_NAMES } from "./tools";

export const SERVER_NAME = "claude-files-access";
export const SERVER_VERSION = "1.0.0";
export const SUPPORTED_PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];

export interface ToolContent {
  type: string;
  [key: string]: unknown;
}

export interface ToolResult {
  content: ToolContent[];
  isError?: boolean;
}

export interface ToolBackend {
  callTool(name: string, args: Record<string, unknown>): Promise<ToolResult>;
}

type JsonRpcId = string | number | null;

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id?: JsonRpcId;
  method: string;
  params?: Record<string, unknown>;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: JsonRpcId;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, GET, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Accept, Mcp-Session-Id, Mcp-Protocol-Version, Authorization",
  "Access-Control-Expose-Headers": "Mcp-Session-Id",
};

export function textResult(text: string, isError = false): ToolResult {
  return { content: [{ type: "text", text }], isError };
}

function rpcError(id: JsonRpcId, code: number, message: string): JsonRpcResponse {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

/** Handles one JSON-RPC message. Returns null for notifications. */
export async function handleRpcMessage(msg: unknown, backend: ToolBackend): Promise<JsonRpcResponse | null> {
  if (typeof msg !== "object" || msg === null || (msg as JsonRpcRequest).jsonrpc !== "2.0") {
    return rpcError(null, -32600, "Invalid Request");
  }
  const req = msg as JsonRpcRequest;
  const isNotification = req.id === undefined;
  // Responses from the client (to server requests we never send) and notifications need no reply.
  if (typeof req.method !== "string") return isNotification ? null : rpcError(req.id ?? null, -32600, "Invalid Request");
  if (isNotification) return null;
  const id = req.id ?? null;

  switch (req.method) {
    case "initialize": {
      const requested = req.params?.protocolVersion;
      const protocolVersion =
        typeof requested === "string" && SUPPORTED_PROTOCOL_VERSIONS.includes(requested)
          ? requested
          : SUPPORTED_PROTOCOL_VERSIONS[0];
      return {
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion,
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: SERVER_NAME, title: "Claude Files Access (iOS)", version: SERVER_VERSION },
          instructions: SERVER_INSTRUCTIONS,
        },
      };
    }
    case "ping":
      return { jsonrpc: "2.0", id, result: {} };
    case "tools/list":
      return { jsonrpc: "2.0", id, result: { tools: TOOLS } };
    case "tools/call": {
      const name = req.params?.name;
      const args = req.params?.arguments ?? {};
      if (typeof name !== "string" || !TOOL_NAMES.has(name)) {
        return rpcError(id, -32602, `Unknown tool: ${String(name)}`);
      }
      if (typeof args !== "object" || args === null || Array.isArray(args)) {
        return rpcError(id, -32602, "Tool arguments must be an object");
      }
      let result: ToolResult;
      try {
        result = await backend.callTool(name, args as Record<string, unknown>);
      } catch (err) {
        result = textResult(`Relay error: ${err instanceof Error ? err.message : String(err)}`, true);
      }
      return { jsonrpc: "2.0", id, result };
    }
    case "resources/list":
      return { jsonrpc: "2.0", id, result: { resources: [] } };
    case "prompts/list":
      return { jsonrpc: "2.0", id, result: { prompts: [] } };
    default:
      return rpcError(id, -32601, `Method not found: ${req.method}`);
  }
}

/** Handles an HTTP request to the MCP endpoint. */
export async function handleMcpRequest(request: Request, backend: ToolBackend): Promise<Response> {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (request.method === "DELETE") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (request.method !== "POST") {
    // No server-initiated SSE stream is offered.
    return new Response("Method Not Allowed", { status: 405, headers: { Allow: "POST, DELETE, OPTIONS", ...CORS_HEADERS } });
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json(rpcError(null, -32700, "Parse error"), 400);
  }

  if (Array.isArray(body)) {
    if (body.length === 0) return json(rpcError(null, -32600, "Invalid Request"), 400);
    const responses = (await Promise.all(body.map((m) => handleRpcMessage(m, backend)))).filter(
      (r): r is JsonRpcResponse => r !== null,
    );
    return responses.length ? json(responses) : new Response(null, { status: 202, headers: CORS_HEADERS });
  }

  const response = await handleRpcMessage(body, backend);
  return response ? json(response) : new Response(null, { status: 202, headers: CORS_HEADERS });
}
