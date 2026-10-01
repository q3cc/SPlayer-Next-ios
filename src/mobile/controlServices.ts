import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { store } from "./shims/store";
import type { ExternalApiStatus, McpStatus } from "@shared/types/settings";

type Kind = "mcp" | "external";
type Status = ExternalApiStatus & McpStatus;
const subscribers = {
  mcp: new Set<(status: Status) => void>(),
  external: new Set<(status: Status) => void>(),
};
const stopped = (): Status => ({
  listening: false,
  allowLan: false,
  host: null,
  port: null,
  error: null,
});
let initialized: Promise<void> | undefined;
let sequence = Promise.resolve();
let unlisten: (() => void) | undefined;
const onVisibilityChange = (): void => {
  void restartControlServices().catch((error) => console.error("控制服务启停失败", error));
};

const key = (kind: Kind): string => {
  const path = kind === "mcp" ? "mcp.accessKey" : "externalApi.accessKey";
  let value = store.get(path) ?? "";
  if (!value) {
    value = Array.from(crypto.getRandomValues(new Uint8Array(32)), (byte) =>
      byte.toString(16).padStart(2, "0"),
    ).join("");
    store.set(path, value);
  }
  return value;
};

interface ControlRequest {
  id: number;
  kind: Kind;
  method: string;
  path: string;
  body: string;
  accept: string;
  protocol?: string;
}
const receive = async ({
  id,
  kind,
  method,
  path,
  body,
  accept,
  protocol,
}: ControlRequest): Promise<void> => {
  let response: Response;
  try {
    if (document.hidden) throw new Error("请保持 SPlayer 在前台");
    if (kind === "mcp") {
      const { handleMobileMcp } = await import("./mcpEndpoint");
      response = await handleMobileMcp(
        new Request("http://127.0.0.1/mcp", {
          method,
          headers: {
            "content-type": "application/json",
            accept,
            ...(protocol ? { "mcp-protocol-version": protocol } : {}),
          },
          body,
        }),
      );
    } else {
      const { runControlTool } = await import("./controlTools");
      const routes: Record<string, string> = {
        "/status": "get_playback_status",
        "/now-playing": "get_now_playing",
        "/play": "play",
        "/pause": "pause",
        "/stop": "stop",
        "/next": "next_track",
        "/prev": "previous_track",
        "/seek": "seek",
        "/volume": "set_volume",
      };
      const route = path.replace(/^\/api(?=\/|$)/, "");
      if (route === "/info" && method === "GET")
        response = Response.json({ name: "SPlayer Next", version: __APP_VERSION__, wsClients: 0 });
      else {
        const operation = routes[route];
        if (!operation) {
          response = Response.json({ error: "not found" }, { status: 404 });
        } else if (method !== (["/status", "/now-playing"].includes(route) ? "GET" : "POST"))
          response = Response.json({ error: "method not allowed" }, { status: 405 });
        else
          response = Response.json(await runControlTool(operation, body ? JSON.parse(body) : {}));
      }
    }
  } catch (error) {
    response = Response.json(
      { error: error instanceof Error ? error.message : "控制请求失败" },
      { status: 400 },
    );
  }
  await invoke("control_reply", {
    id,
    reply: {
      status: response.status,
      body: await response.text(),
      content_type: response.headers.get("content-type") ?? "application/json",
    },
  });
};

export const initializeControlServices = (): Promise<void> =>
  (initialized ??= (async () => {
    unlisten = await listen<ControlRequest>("mobile-control-request", ({ payload }) => {
      void receive(payload).catch((error) => console.error("控制请求回传失败", error));
    });
    document.addEventListener("visibilitychange", onVisibilityChange);
  })().catch((error) => {
    initialized = undefined;
    throw error;
  }));

if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    unlisten?.();
    document.removeEventListener("visibilitychange", onVisibilityChange);
  });
}

const restart = async (kind: Kind): Promise<Status> => {
  await initializeControlServices();
  const settings = store.get(kind === "mcp" ? "mcp" : "externalApi");
  let result = stopped();
  try {
    await invoke("control_stop", { kind });
    if (settings.enabled && !document.hidden)
      result = await invoke<Status>("control_start", {
        kind,
        port: settings.port,
        allowLan: settings.allowLan ?? false,
        key: key(kind),
      });
  } catch (error) {
    result.error = { code: "START_FAILED", message: String(error) };
  }
  subscribers[kind].forEach((callback) => callback(result));
  return result;
};

const enqueueRestart = <T>(operation: () => Promise<T>): Promise<T> => {
  const next = sequence.catch(() => {}).then(operation);
  sequence = next.then(
    () => {},
    () => {},
  );
  return next;
};

export const restartControlServices = (): Promise<void> =>
  enqueueRestart(async () => {
    await restart("mcp");
    await restart("external");
  });

export const mobileMcp = {
  restart: () => enqueueRestart(() => restart("mcp")),
  getStatus: () => invoke<Status>("control_status", { kind: "mcp" }),
  getClientConfigParams: async () => {
    const status = await mobileMcp.getStatus();
    return {
      port: status.port ?? store.get("mcp.port"),
      host: status.host ?? "127.0.0.1",
      accessKey: key("mcp"),
    };
  },
  detectAgents: async () => [],
  injectAgentConfig: async () => {
    throw new Error("移动端不能改写其他应用配置，请复制连接配置到 AI 客户端");
  },
  onStatus: (callback: (status: Status) => void) => {
    subscribers.mcp.add(callback);
    return () => subscribers.mcp.delete(callback);
  },
};
export const mobileExternalApi = {
  restart: () => enqueueRestart(() => restart("external")),
  getStatus: () => invoke<Status>("control_status", { kind: "external" }),
  onStatus: (callback: (status: Status) => void) => {
    subscribers.external.add(callback);
    return () => subscribers.external.delete(callback);
  },
};
