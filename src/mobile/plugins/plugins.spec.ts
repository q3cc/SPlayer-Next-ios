import vm from "node:vm";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
import { createPluginRuntime } from "@main/plugins/runtime";
import type { SandboxIn, SandboxOut } from "@shared/types/plugin";

const mocks = vi.hoisted(() => ({
  databases: new Map<string, Map<string, unknown>>(),
  pick: vi.fn(),
  read: vi.fn(),
  fetchScript: vi.fn(),
  request: vi.fn(),
}));
vi.mock("localforage", () => ({
  default: {
    createInstance: ({ storeName }: { storeName: string }) => {
      if (!mocks.databases.has(storeName)) mocks.databases.set(storeName, new Map());
      const entries = mocks.databases.get(storeName)!;
      return {
        keys: async () => [...entries.keys()],
        getItem: async (key: string) => structuredClone(entries.get(key) ?? null),
        setItem: async (key: string, value: unknown) => {
          entries.set(key, structuredClone(value));
        },
        removeItem: async (key: string) => {
          entries.delete(key);
        },
      };
    },
  },
}));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: mocks.pick }));
vi.mock("@tauri-apps/plugin-fs", () => ({ readTextFile: mocks.read }));
vi.mock("./network", () => ({
  fetchPluginScript: mocks.fetchScript,
  requestPlugin: mocks.request,
}));

/** 使用真实的共享运行时执行样例脚本，仅替换 Worker 传输和原生文件接口。 */
class TestWorker {
  static instances: TestWorker[] = [];
  onmessage?: (event: { data: SandboxOut }) => void;
  onerror?: (event: unknown) => void;
  terminated = false;
  receive?: (event: { data: SandboxIn }) => void;
  pluginId = "";
  constructor() {
    TestWorker.instances.push(this);
    createPluginRuntime({
      on: (_event, callback) => {
        this.receive = callback;
      },
      postMessage: (data) => {
        queueMicrotask(() => {
          if (!this.terminated) this.onmessage?.({ data });
        });
      },
      evaluate: (source, globals) => {
        vm.runInNewContext(source, globals, { timeout: 1000 });
      },
    });
  }
  postMessage(data: SandboxIn) {
    if (data.kind === "loadPlugin") this.pluginId = data.pluginId;
    if (!this.terminated) this.receive?.({ data });
  }
  terminate() {
    if (this.pluginId) this.receive?.({ data: { kind: "unloadPlugin", pluginId: this.pluginId } });
    this.terminated = true;
  }
}

const source = `/**
 * @id test.source
 * @name 测试音源
 * @version 1.0.0
 * @updateUrl https://example.com/plugin.js
 */
splayer.register({ sources: { wy: { name: "测试", actions: ["musicUrl"], qualities: ["hq"] } } });
splayer.on("musicUrl", async (req) => ({ url: "https://example.com/" + req.musicInfo.songmid, quality: req.quality }));`;

beforeEach(() => {
  vi.resetModules();
  mocks.databases.clear();
  mocks.pick.mockReset();
  mocks.read.mockReset();
  mocks.fetchScript.mockReset();
  mocks.request.mockReset();
  TestWorker.instances = [];
  vi.stubGlobal("Worker", TestWorker);
});
afterEach(() => {
  TestWorker.instances.forEach((worker) => worker.terminate());
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

it("从文件导入后能解析音源，禁用终止线程，重新启用和重载保留插件", async () => {
  const { mobilePlugins } = await import("./index");
  mocks.pick.mockResolvedValue("/plugin.js");
  mocks.read.mockResolvedValue(source);
  expect(await mobilePlugins.pickAndInstall()).toEqual({ ok: true, id: "test.source" });
  const args = { pluginId: "test.source", source: "wy", musicInfo: { songmid: "123" } };
  expect(await mobilePlugins.resolveUrl(args)).toMatchObject({
    url: "https://example.com/123",
    quality: "hq",
  });
  await mobilePlugins.setEnabled("test.source", false);
  expect(TestWorker.instances[0].terminated).toBe(true);
  await expect(mobilePlugins.resolveUrl(args)).rejects.toThrow("未启用");
  await mobilePlugins.setEnabled("test.source", true);
  expect((await mobilePlugins.resolveUrl(args)).url).toContain("123");
  TestWorker.instances.forEach((worker) => worker.terminate());
  vi.resetModules();
  const reloaded = (await import("./index")).mobilePlugins;
  expect(await reloaded.list()).toHaveLength(1);
  expect((await reloaded.resolveUrl(args)).url).toContain("123");
  expect(await reloaded.uninstall("test.source")).toEqual({ ok: true });
  expect(await reloaded.list()).toEqual([]);
});

it("兼容 LX 脚本注册与音质映射", async () => {
  const { installMobilePlugin, mobilePlugins } = await import("./index");
  const lx = `/** @name lx-test */
  lx.on(lx.EVENT_NAMES.request, async ({ info }) => "https://example.com/" + info.type);
  lx.send(lx.EVENT_NAMES.inited, { status: true, sources: { wy: { name: "网易", type: "music", actions: ["musicUrl"], qualitys: ["320k"] } } });`;
  const result = await installMobilePlugin(lx);
  expect(result.ok).toBe(true);
  expect(
    await mobilePlugins.resolveUrl({
      pluginId: result.id!,
      source: "wy",
      quality: "hq",
      musicInfo: { songmid: "1" },
    }),
  ).toMatchObject({ url: "https://example.com/320k" });
});

it("取消导入不安装，读取错误和非法脚本显示失败状态", async () => {
  const { installMobilePlugin, mobilePlugins } = await import("./index");
  mocks.pick.mockResolvedValue(null);
  expect(await mobilePlugins.pickAndInstall()).toEqual({ ok: false, cancelled: true });
  mocks.read.mockRejectedValue(new Error("读取失败"));
  expect(await mobilePlugins.install("/missing.js")).toMatchObject({
    ok: false,
    error: "读取失败",
  });
  const result = await installMobilePlugin(source + "\nsyntax !!!");
  await vi.waitFor(async () => expect((await mobilePlugins.list())[0].status.state).toBe("error"));
  await expect(
    mobilePlugins.resolveUrl({ pluginId: result.id!, source: "wy", musicInfo: { songmid: "1" } }),
  ).rejects.toThrow();
});

it("插件请求经过宿主并遵守网络权限", async () => {
  const { installMobilePlugin, mobilePlugins } = await import("./index");
  mocks.request.mockResolvedValue({ status: 200, headers: {}, body: "https://example.com/audio" });
  const requesting = source.replace(
    'url: "https://example.com/" + req.musicInfo.songmid',
    'url: (await splayer.request("https://example.com/resolve")).body',
  );
  await installMobilePlugin(requesting);
  const args = { pluginId: "test.source", source: "wy", musicInfo: { songmid: "1" } };
  expect((await mobilePlugins.resolveUrl(args)).url).toBe("https://example.com/audio");
  const control = requesting.replace(
    "@version 1.0.0",
    "@version 1.0.0\n * @type control\n * @apiLevel 2",
  );
  await installMobilePlugin(control);
  await expect(mobilePlugins.resolveUrl(args)).rejects.toThrow("联网权限");
  expect(mocks.request).toHaveBeenCalledTimes(1);
});

it("设置持久化且变更通知到脚本，更新保留设置并拒绝其他插件的文件", async () => {
  const { installMobilePlugin, mobilePlugins } = await import("./index");
  const configurable =
    source +
    `
    splayer.register({ settings: [{ key: "name", type: "text", label: "名称", default: "initial" }] });
    let name = splayer.getSetting("name");
    splayer.onSettingChange("name", value => name = value);
    splayer.on("musicUrl", async () => ({ url: "https://example.com/" + name }));`;
  await installMobilePlugin(configurable);
  const args = { pluginId: "test.source", source: "wy", musicInfo: { songmid: "1" } };
  expect((await mobilePlugins.resolveUrl(args)).url).toContain("initial");
  await mobilePlugins.setSetting("test.source", "name", "saved");
  await expect(mobilePlugins.setSetting("test.source", "name", false)).rejects.toThrow("无效");
  expect((await mobilePlugins.resolveUrl(args)).url).toContain("saved");
  mocks.fetchScript.mockResolvedValue(configurable.replace("1.0.0", "1.1.0"));
  expect(await mobilePlugins.checkUpdate("test.source")).toMatchObject({
    ok: true,
    hasUpdate: true,
  });
  expect(await mobilePlugins.applyUpdate("test.source")).toMatchObject({ ok: true });
  expect((await mobilePlugins.resolveUrl(args)).url).toContain("saved");
  mocks.fetchScript.mockResolvedValue(configurable.replace("test.source", "other.source"));
  expect(await mobilePlugins.applyUpdate("test.source")).toMatchObject({ ok: false });
  expect((await mobilePlugins.list())[0].manifest.version).toBe("1.1.0");
});

it("调用超时终止线程并清理在途请求", async () => {
  vi.useFakeTimers();
  const { installMobilePlugin, mobilePlugins } = await import("./index");
  await installMobilePlugin(source + '\nsplayer.on("musicUrl", () => new Promise(() => {}));');
  const pending = mobilePlugins.resolveUrl({
    pluginId: "test.source",
    source: "wy",
    musicInfo: { songmid: "1" },
  });
  const assertion = expect(pending).rejects.toThrow("超时");
  await vi.advanceTimersByTimeAsync(20001);
  await assertion;
  expect(TestWorker.instances[0].terminated).toBe(true);
  expect((await mobilePlugins.list())[0].status.state).toBe("error");
});
