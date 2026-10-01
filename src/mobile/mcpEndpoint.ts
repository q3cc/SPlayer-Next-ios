import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { controlTools, runControlTool } from "./controlTools";

/** 无状态 JSON 响应，不让移动端后台冻结留下长连接或会话缓存。 */
export const handleMobileMcp = async (request: Request): Promise<Response> => {
  const server = new McpServer({ name: "splayer-next", version: __APP_VERSION__ });
  for (const [name, tool] of Object.entries(controlTools)) {
    server.registerTool(
      name,
      {
        description: tool.description,
        inputSchema: tool.schema.shape,
        annotations: { readOnlyHint: "readOnly" in tool && tool.readOnly, destructiveHint: false },
      },
      async (input) => ({
        content: [
          { type: "text" as const, text: JSON.stringify(await runControlTool(name, input)) },
        ],
      }),
    );
  }
  const transport = new WebStandardStreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
    enableJsonResponse: true,
  });
  try {
    await server.connect(transport);
    const response = await transport.handleRequest(request);
    const body = await response.text();
    return new Response(body || null, { status: response.status, headers: response.headers });
  } finally {
    await server.close();
  }
};
