import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { createPluginRuntime } from "../electron/main/plugins/runtime";
import { parsePluginScript } from "../shared/utils/pluginScript";
import { ACTION_TIMEOUTS, PLUGIN_LOAD_TIMEOUT } from "../shared/defaults/plugin-api";
import type { SandboxIn, SandboxOut, SourceCapability } from "../shared/types/plugin";

// 此入口只能在文件系统只读、网络隔离的外部沙箱内运行；vm 本身不是安全边界。
if (process.env.LX_AUDIT_SANDBOX !== "1") throw new Error("请按维护文档在断网沙箱内运行");
const raw = readFileSync(process.argv[2], "utf8");
const { source, manifest } = parsePluginScript(raw);
const report = {
  sha256: createHash("sha256").update(raw).digest("hex"),
  name: manifest.name,
  version: manifest.version,
  imported: true,
  initialization: "pending",
  sources: {} as Record<string, SourceCapability>,
  blockedRequests: 0,
  runtimeErrors: 0,
  resolution: {} as Record<string, string>,
};
let receive!: (event: { data: SandboxIn }) => void;
let initialized!: () => void;
const ready = new Promise<void>((resolve) => (initialized = resolve));
const pending = new Map<string, (status: string) => void>();
process.on("unhandledRejection", () => {
  report.runtimeErrors += 1;
});
process.on("uncaughtException", () => {
  report.runtimeErrors += 1;
});

/** 网络全部拒绝，不输出脚本日志、鉴权信息或返回链接。 */
const onMessage = (message: SandboxOut): void => {
  if (message.kind === "ready") {
    report.initialization = "ready";
    report.sources = message.sources;
    initialized();
  } else if (message.kind === "fatal") {
    report.initialization = "failed";
    report.runtimeErrors += 1;
    initialized();
  } else if (message.kind === "hostCall") {
    if (message.method === "request") report.blockedRequests += 1;
    queueMicrotask(() =>
      receive({
        data: {
          kind: "hostResult",
          pluginId: manifest.id,
          callId: message.callId,
          ok: false,
          error: { code: "PLUGIN_NETWORK_ERROR", message: "离线审计：未访问第三方服务" },
        },
      }),
    );
  } else if (message.kind === "result") {
    pending.get(message.requestId)?.(message.ok ? "returned-unverified-url" : "rejected-offline");
  }
};

createPluginRuntime(
  {
    on: (_event, callback) => (receive = callback),
    postMessage: onMessage,
    evaluate: (script, globals) => {
      vm.runInNewContext(script, globals, { timeout: 1000 });
    },
  },
  "mobile",
);

const loadTimer = setTimeout(() => {
  report.initialization = "timeout";
  initialized();
}, PLUGIN_LOAD_TIMEOUT);
receive({
  data: {
    kind: "loadPlugin",
    pluginId: manifest.id,
    source,
    apiLevel: 3,
    appVersion: "2.0.0",
    locale: "zh-CN",
    userSettings: {},
    scriptInfo: {
      name: manifest.name,
      version: manifest.version,
      description: manifest.description ?? "",
      author: manifest.author ?? "",
      homepage: manifest.homepage ?? "",
    },
  },
});
await ready;
clearTimeout(loadTimer);
if (report.initialization === "ready") {
  await Promise.all(
    ["wy", "tx", "kg"].map(async (platform) => {
      const capability = report.sources[platform];
      const qualities = capability?.qualities ?? [];
      if (!capability?.actions.includes("musicUrl") || !qualities.length) {
        report.resolution[platform] = "not-declared";
        return;
      }
      report.resolution[platform] = await new Promise<string>((resolve) => {
        const timer = setTimeout(() => {
          pending.delete(platform);
          resolve("timeout");
        }, ACTION_TIMEOUTS.musicUrl);
        pending.set(platform, (status) => {
          clearTimeout(timer);
          pending.delete(platform);
          resolve(status);
        });
        receive({
          data: {
            kind: "call",
            pluginId: manifest.id,
            requestId: platform,
            action: "musicUrl",
            params: {
              source: platform,
              quality: qualities.includes("hq") ? "hq" : qualities[0],
              musicInfo: {
                songmid: "test-only",
                name: "测试",
                singer: "测试",
                ...(platform === "kg" ? { hash: "00000000000000000000000000000000" } : {}),
              },
            },
          },
        });
      });
    }),
  );
}
receive({ data: { kind: "unloadPlugin", pluginId: manifest.id } });
console.log(JSON.stringify(report));
