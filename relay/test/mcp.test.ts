import { describe, expect, it } from "vitest";
import { handleMcpRequest, handleRpcMessage, textResult, type ToolBackend } from "../src/mcp";
import { TOOLS } from "../src/tools";

const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
const backend: ToolBackend = {
  async callTool(name, args) {
    calls.push({ name, args });
    return textResult(`called ${name}`);
  },
};

function post(body: unknown): Request {
  return new Request("https://relay.example/tok/mcp", {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
    body: JSON.stringify(body),
  });
}

describe("MCP handler", () => {
  it("negotiates a supported protocol version", async () => {
    const res = await handleRpcMessage(
      { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26" } },
      backend,
    );
    expect(res?.result).toMatchObject({ protocolVersion: "2025-03-26", capabilities: { tools: {} } });
  });

  it("falls back to the newest version for unknown requests", async () => {
    const res = await handleRpcMessage(
      { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "1999-01-01" } },
      backend,
    );
    expect((res?.result as { protocolVersion: string }).protocolVersion).toBe("2025-06-18");
  });

  it("lists every tool with a schema", async () => {
    const res = await handleRpcMessage({ jsonrpc: "2.0", id: 2, method: "tools/list" }, backend);
    const tools = (res?.result as { tools: typeof TOOLS }).tools;
    expect(tools.length).toBe(TOOLS.length);
    for (const tool of tools) {
      expect(tool.inputSchema).toMatchObject({ type: "object" });
      expect(tool.description.length).toBeGreaterThan(10);
    }
    expect(new Set(tools.map((t) => t.name)).size).toBe(tools.length);
  });

  it("forwards tool calls to the backend", async () => {
    const res = await handleRpcMessage(
      { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "tail_file", arguments: { path: "Madeira/log.txt" } } },
      backend,
    );
    expect(res?.result).toEqual(textResult("called tail_file"));
    expect(calls.at(-1)).toEqual({ name: "tail_file", args: { path: "Madeira/log.txt" } });
  });

  it("rejects unknown tools", async () => {
    const res = await handleRpcMessage(
      { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "rm_rf", arguments: {} } },
      backend,
    );
    expect(res?.error?.code).toBe(-32602);
  });

  it("turns backend exceptions into tool errors", async () => {
    const failing: ToolBackend = {
      async callTool() {
        throw new Error("boom");
      },
    };
    const res = await handleRpcMessage(
      { jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "device_status", arguments: {} } },
      failing,
    );
    expect(res?.result).toMatchObject({ isError: true });
  });

  it("returns 202 for notifications", async () => {
    const res = await handleMcpRequest(post({ jsonrpc: "2.0", method: "notifications/initialized" }), backend);
    expect(res.status).toBe(202);
  });

  it("returns JSON for requests", async () => {
    const res = await handleMcpRequest(post({ jsonrpc: "2.0", id: 6, method: "ping" }), backend);
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/json");
    expect(await res.json()).toEqual({ jsonrpc: "2.0", id: 6, result: {} });
  });

  it("handles batches", async () => {
    const res = await handleMcpRequest(
      post([
        { jsonrpc: "2.0", id: 7, method: "ping" },
        { jsonrpc: "2.0", method: "notifications/initialized" },
      ]),
      backend,
    );
    expect(await res.json()).toEqual([{ jsonrpc: "2.0", id: 7, result: {} }]);
  });

  it("rejects GET (no SSE stream)", async () => {
    const res = await handleMcpRequest(new Request("https://relay.example/tok/mcp"), backend);
    expect(res.status).toBe(405);
  });

  it("reports parse errors", async () => {
    const res = await handleMcpRequest(
      new Request("https://relay.example/tok/mcp", { method: "POST", body: "{not json" }),
      backend,
    );
    expect(res.status).toBe(400);
  });
});
