// @vitest-environment node
import { expect, it, vi } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { handleMobileMcp } from "./mcpEndpoint";
const mocks = vi.hoisted(() => ({ pause: vi.fn(), setVolume: vi.fn() }));
vi.mock("@/core/player", () => mocks);

it("官方客户端可以初始化、发现工具和调用；拒绝非法参数", async () => {
  const client = new Client({ name: "test", version: "1.0" });
  const transport = new StreamableHTTPClientTransport(new URL("http://localhost/mcp"), {
    fetch: async (url, init) => handleMobileMcp(new Request(url, init)),
  });
  try {
    await client.connect(transport);
    const listed = await client.listTools();
    expect(listed.tools.map((tool) => tool.name)).toContain("search_online_songs");
    expect(listed.tools).toHaveLength(12);
    expect((await client.callTool({ name: "pause", arguments: {} })).isError).not.toBe(true);
    expect(mocks.pause).toHaveBeenCalledOnce();
    expect((await client.callTool({ name: "set_volume", arguments: { volume: 2 } })).isError).toBe(
      true,
    );
    expect(mocks.setVolume).not.toHaveBeenCalled();
    expect((await client.callTool({ name: "unknown", arguments: {} })).isError).toBe(true);
  } finally {
    await client.close();
  }
});
