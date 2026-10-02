import vm from "node:vm";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createPluginRuntime } from "@main/plugins/runtime";
import type { SandboxIn, SandboxOut } from "@shared/types/plugin";

const cleanups: Array<() => void> = [];
const registration = `{
  sources: { wy: { type: "music", actions: ["musicUrl"], qualitys: ["320k"] } }
}`;

/** 只执行测试内的可信脚本，直接验证生产运行时的注入与消息处理。 */
const setup = (source: string, environment?: "desktop" | "mobile") => {
  const messages: SandboxOut[] = [];
  let receive!: (event: { data: SandboxIn }) => void;
  let globals!: Record<string, any>;
  createPluginRuntime(
    {
      on: (_event, callback) => (receive = callback),
      postMessage: (message) => messages.push(message),
      evaluate: (script, injected) => {
        globals = injected;
        vm.runInNewContext(script, injected, { timeout: 1000 });
      },
    },
    environment,
  );
  const send = (data: SandboxIn) => receive({ data });
  send({
    kind: "loadPlugin",
    pluginId: "test.lx",
    source,
    apiLevel: 3,
    locale: "zh-CN",
    appVersion: "99.0.0",
    userSettings: {},
    scriptInfo: { name: "测试", version: "1", author: "", description: "", homepage: "" },
  });
  cleanups.push(() => send({ kind: "unloadPlugin", pluginId: "test.lx" }));
  return {
    messages,
    globals,
    send,
    call: (quality = "hq") =>
      send({
        kind: "call",
        pluginId: "test.lx",
        requestId: "test-request",
        action: "musicUrl",
        params: { source: "wy", quality, musicInfo: { songmid: "123" } },
      }),
  };
};

afterEach(() => {
  cleanups.splice(0).forEach((cleanup) => cleanup());
  vi.useRealTimers();
});

describe("LX 生产运行时兼容", () => {
  it.each([undefined, "desktop", "mobile"] as const)(
    "正确报告环境 %s，协议版本独立于应用版本",
    async (environment) => {
      const { globals, messages } = setup(
        `lx.on("request", async () => "https://example.com/audio"); lx.send("inited", ${registration});`,
        environment,
      );
      expect(globals.lx.env).toBe(environment ?? "desktop");
      expect(globals.lx.version).toBe("2.0.0");
      await vi.waitFor(() => expect(messages.filter((m) => m.kind === "ready")).toHaveLength(1));
    },
  );

  it("真实注入的控制台支持 Huibq 与 ikun 使用的分组方法", async () => {
    const { globals, messages, call } = setup(`
      lx.on("request", async () => {
        console.group("请求"); console.groupCollapsed("详情"); console.groupEnd();
        console.table([]); console.dir({}); console.dirxml({}); console.trace("跟踪");
        console.time("请求"); console.timeLog("请求"); console.timeEnd("请求");
        console.count("次数"); console.countReset("次数"); console.clear();
        console.assert(true, "断言"); console.assert(false, "断言失败");
        return "https://example.com/audio";
      });
      lx.send("inited", ${registration});
    `);
    expect(globals.window.console).toBe(globals.console);
    expect(globals.self).toBe(globals.globalThis);
    call();
    await vi.waitFor(() =>
      expect(messages).toContainEqual(expect.objectContaining({ kind: "result", ok: true })),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({ kind: "log", level: "error", args: ["断言失败"] }),
    );
  });

  it("异步初始化完成之前不报告可用，完成后只报告一次", async () => {
    vi.useFakeTimers();
    const { messages } = setup(`
      lx.on("request", async () => "https://example.com/audio");
      setTimeout(() => lx.send("inited", ${registration}), 100);
    `);
    await vi.advanceTimersByTimeAsync(0);
    expect(messages.some((m) => m.kind === "ready")).toBe(false);
    await vi.advanceTimersByTimeAsync(100);
    expect(messages.filter((m) => m.kind === "ready")).toHaveLength(1);
  });

  it("inited 先到时仍等待请求处理器", async () => {
    vi.useFakeTimers();
    const { messages } = setup(`
      lx.send("inited", ${registration});
      setTimeout(() => lx.on("request", async () => "https://example.com/audio"), 100);
    `);
    await vi.advanceTimersByTimeAsync(0);
    expect(messages.some((m) => m.kind === "ready")).toBe(false);
    await vi.advanceTimersByTimeAsync(100);
    expect(messages.filter((m) => m.kind === "ready")).toHaveLength(1);
  });

  it.each([`{ status: false, message: "缺少密钥", sources: {} }`, `{}`])(
    "初始化失败不能被当成空音源就绪：%s",
    async (data) => {
      const { messages } = setup(
        `lx.on("request", async () => ""); lx.send("inited", ${data}).catch(() => {});`,
      );
      await vi.waitFor(() => expect(messages.some((m) => m.kind === "fatal")).toBe(true));
      expect(messages.some((m) => m.kind === "ready")).toBe(false);
    },
  );

  it("卸载后迟到的初始化和更新通知不再发布", async () => {
    const { globals, messages, send } = setup(
      `lx.on("request", async () => "https://example.com/audio");`,
    );
    send({ kind: "unloadPlugin", pluginId: "test.lx" });
    const count = messages.length;
    await globals.lx.send("inited", {
      sources: { wy: { actions: ["musicUrl"], qualitys: ["320k"] } },
    });
    await globals.lx.send("updateAlert", { log: "更新", updateUrl: "https://example.com/update" });
    expect(messages).toHaveLength(count);
  });

  it("原生 SPlayer 控制插件无音源时仍可就绪", async () => {
    const { messages } = setup(`splayer.register({ events: ["trackChange"] });`);
    await vi.waitFor(() => expect(messages.some((m) => m.kind === "ready")).toBe(true));
  });

  it.each(["24bit", "hires", "flac24bit"])("按脚本声明传递高解析音质别名 %s", async (quality) => {
    const { messages, call } = setup(`
      lx.on("request", async ({ info }) => "https://example.com/" + info.type);
      lx.send("inited", { sources: { wy: { type: "music", actions: ["musicUrl"], qualitys: ["${quality}"] } } });
    `);
    call("hi-res");
    await vi.waitFor(() =>
      expect(messages).toContainEqual(
        expect.objectContaining({
          kind: "result",
          ok: true,
          data: { url: "https://example.com/" + quality },
        }),
      ),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        kind: "ready",
        sources: { wy: { name: "wy", actions: ["musicUrl"], qualities: ["hi-res"] } },
      }),
    );
  });

  it("没有声明的音质不传给脚本，也不冒充解析成功", async () => {
    const { messages, call } = setup(`
      lx.on("request", async () => "https://example.com/unsupported");
      lx.send("inited", ${registration});
    `);
    call("hi-res");
    await vi.waitFor(() =>
      expect(messages).toContainEqual(expect.objectContaining({ kind: "result", ok: false })),
    );
  });

  it("LX 请求保留表单、响应回调与歌曲字段", async () => {
    const { messages, send, call } = setup(`
      lx.on("request", ({ info }) => new Promise((resolve, reject) => {
        lx.request("https://example.com/resolve", {
          method: "post", form: { id: info.musicInfo.songmid, quality: info.type },
          headers: { "X-Test": 123 }
        }, (error, response, body) => {
          if (error) return reject(error);
          if (response.body !== body || response.statusCode !== 200 || !response.raw.length) return reject(new Error("回调格式错误"));
          resolve(body.url);
        });
      }));
      lx.send("inited", ${registration});
    `);
    call();
    const request = messages.find((message) => message.kind === "hostCall");
    expect(request?.kind).toBe("hostCall");
    if (request?.kind !== "hostCall") throw new Error("缺少宿主请求");
    expect(request.args).toEqual([
      "https://example.com/resolve",
      expect.objectContaining({
        method: "POST",
        body: "id=123&quality=320k",
        headers: expect.objectContaining({
          "X-Test": "123",
          "content-type": "application/x-www-form-urlencoded",
        }),
      }),
    ]);
    send({
      kind: "hostResult",
      pluginId: "test.lx",
      callId: request.callId,
      ok: true,
      data: {
        status: 200,
        headers: {},
        body: JSON.stringify({ url: "https://example.com/audio" }),
      },
    });
    await vi.waitFor(() =>
      expect(messages).toContainEqual(
        expect.objectContaining({
          kind: "result",
          ok: true,
          data: { url: "https://example.com/audio" },
        }),
      ),
    );
  });

  it("LX 常用压缩与加密工具可供脚本调用", async () => {
    const { messages, call } = setup(`
      lx.on("request", async () => {
        const { buffer, zlib, crypto } = lx.utils;
        const input = buffer.from("abc");
        const restored = await zlib.inflate(await zlib.deflate(input));
        if (buffer.bufToString(restored) !== "abc") throw new Error("压缩往返失败");
        if (crypto.md5(input) !== "900150983cd24fb0d6963f7d28e17f72") throw new Error("摘要错误");
        const key = buffer.from("0123456789abcdef");
        if (!crypto.aesEncrypt(input, "aes-128-cbc", key, key).length) throw new Error("加密失败");
        if (crypto.randomBytes(16).length !== 16) throw new Error("随机数错误");
        return "https://example.com/audio";
      });
      lx.send("inited", ${registration});
    `);
    call();
    await vi.waitFor(() =>
      expect(messages).toContainEqual(expect.objectContaining({ kind: "result", ok: true })),
    );
  });
});
