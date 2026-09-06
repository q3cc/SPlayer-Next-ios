import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateEvent } from "@shared/types/update";

const mocks = vi.hoisted(() => ({
  fetch: vi.fn(),
  open: vi.fn(),
  get: vi.fn(),
  invoke: vi.fn(),
  addListener: vi.fn(),
  unregister: vi.fn(),
}));
vi.mock("@tauri-apps/api/core", () => ({
  invoke: mocks.invoke,
  addPluginListener: mocks.addListener,
}));
vi.mock("./shims/proxy", () => ({ fetchWithProxy: mocks.fetch }));
vi.mock("./shims/store", () => ({ store: { get: mocks.get } }));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: mocks.open }));

beforeEach(() => {
  vi.resetModules();
  mocks.fetch.mockReset();
  mocks.invoke.mockReset().mockResolvedValue(undefined);
  mocks.addListener.mockReset().mockResolvedValue({ unregister: mocks.unregister });
  mocks.get.mockImplementation((key) => (key === "update.autoCheck" ? true : "stable"));
});

const release = (tag = "ios-v1.1.0", extra = {}) => ({
  tag_name: tag,
  draft: false,
  prerelease: false,
  body: "更新说明",
  published_at: "2026-09-05T00:00:00Z",
  assets: [
    {
      name: "SPlayer-Next-iOS-unsigned.ipa",
      size: 1234,
      state: "uploaded",
      browser_download_url: `https://github.com/q3cc/SPlayer-Next-ios/releases/download/${tag}/SPlayer-Next-iOS-unsigned.ipa`,
      digest: "sha256:test",
    },
  ],
  ...extra,
});

describe("iOS 检查当前仓库更新", () => {
  it("GitHub 限流时提供明确原因，不当作已是最新版", async () => {
    const { mobileUpdate } = await import("./update");
    const listener = vi.fn();
    mobileUpdate.onEvent(listener);
    mocks.fetch.mockResolvedValue(
      new Response(null, { status: 403, headers: { "x-ratelimit-remaining": "0" } }),
    );
    await mobileUpdate.check(true);
    expect(listener).toHaveBeenLastCalledWith(
      expect.objectContaining({
        type: "error",
        message: expect.stringContaining("请求次数已用完"),
      }),
    );
  });
  it("检查途中切换通道时忽略旧响应，再请求新通道", async () => {
    const { mobileUpdate } = await import("./update");
    const listener = vi.fn();
    mobileUpdate.onEvent(listener);
    let channel = "stable";
    mocks.get.mockImplementation((key) => (key === "update.channel" ? channel : true));
    let resolve!: (value: Response) => void;
    mocks.fetch.mockReturnValueOnce(
      new Promise<Response>((done) => {
        resolve = done;
      }),
    );
    const first = mobileUpdate.check(true);
    channel = "action";
    mocks.fetch.mockResolvedValueOnce(new Response(null, { status: 404 }));
    const second = mobileUpdate.check(true);
    resolve(Response.json([release()]));
    await Promise.all([first, second]);
    expect(mocks.fetch).toHaveBeenCalledTimes(2);
    expect(mocks.fetch.mock.calls[1][0]).toContain("/tags/action-latest");
    expect(listener).not.toHaveBeenCalledWith(expect.objectContaining({ type: "available" }));
    expect(listener).toHaveBeenLastCalledWith({ type: "notAvailable", manual: true });
  });
  it("立即更新传给原生下载器，转发进度，完成后打开分享并清理监听", async () => {
    const { mobileUpdate } = await import("./update");
    const listener = vi.fn();
    mobileUpdate.onEvent(listener);
    mocks.fetch.mockResolvedValue(Response.json([release()]));
    await mobileUpdate.check(true);
    mocks.addListener.mockImplementation(async (_plugin, _event, callback) => {
      callback({ percent: 50, bytesPerSecond: 100, downloadedBytes: 617, totalBytes: 1234 });
      return { unregister: mocks.unregister };
    });
    await mobileUpdate.download();
    expect(mocks.invoke).toHaveBeenNthCalledWith(1, "plugin:ipa-update|download", {
      url: release().assets[0].browser_download_url,
      size: 1234,
      digest: "sha256:test",
    });
    expect(mocks.invoke).toHaveBeenNthCalledWith(2, "plugin:ipa-update|share");
    expect(listener).toHaveBeenCalledWith({
      type: "progress",
      percent: 50,
      bytesPerSecond: 100,
      downloadedBytes: 617,
      totalBytes: 1234,
    });
    expect(listener).toHaveBeenLastCalledWith(expect.objectContaining({ type: "downloaded" }));
    expect(mocks.unregister).toHaveBeenCalled();
  });

  it("下载失败可重试，分享失败仍保留已下载状态", async () => {
    const { mobileUpdate } = await import("./update");
    const listener = vi.fn();
    mobileUpdate.onEvent(listener);
    mocks.fetch.mockResolvedValue(Response.json([release()]));
    await mobileUpdate.check(true);
    mocks.invoke.mockRejectedValueOnce(new Error("network"));
    await mobileUpdate.download();
    expect(listener).toHaveBeenLastCalledWith(expect.objectContaining({ type: "error" }));
    mocks.invoke.mockResolvedValueOnce(undefined).mockRejectedValueOnce(new Error("background"));
    await mobileUpdate.download();
    expect(listener).toHaveBeenCalledWith(expect.objectContaining({ type: "downloaded" }));
    expect(listener).toHaveBeenLastCalledWith(
      expect.objectContaining({ type: "error", stage: "share", message: "background" }),
    );
    await mobileUpdate.install();
    expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:ipa-update|share");
  });

  it("文件丢失时恢复下载入口并显示原生错误，重新下载后可以分享", async () => {
    const { mobileUpdate } = await import("./update");
    const listener = vi.fn();
    mobileUpdate.onEvent(listener);
    mocks.fetch.mockResolvedValue(Response.json([release()]));
    await mobileUpdate.check(true);
    mocks.invoke.mockResolvedValueOnce(undefined).mockRejectedValueOnce({
      code: "IPA_MISSING",
      message: "下载文件已丢失，请重新下载",
    });
    await mobileUpdate.download();
    expect(listener).toHaveBeenLastCalledWith({
      type: "error",
      manual: true,
      message: "下载文件已丢失，请重新下载",
    });
    await mobileUpdate.download();
    expect(listener).toHaveBeenLastCalledWith(expect.objectContaining({ type: "downloaded" }));
    expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:ipa-update|share");
  });

  it("进度达到 100% 后仍等待原生文件就绪才允许分享", async () => {
    const { mobileUpdate } = await import("./update");
    const listener = vi.fn();
    mobileUpdate.onEvent(listener);
    mocks.fetch.mockResolvedValue(Response.json([release()]));
    await mobileUpdate.check(true);
    let ready!: () => void;
    mocks.invoke.mockReturnValueOnce(
      new Promise<void>((resolve) => {
        ready = resolve;
      }),
    );
    mocks.addListener.mockImplementation(async (_plugin, _event, callback) => {
      callback({ percent: 100, downloadedBytes: 1234, totalBytes: 1234 });
      return { unregister: mocks.unregister };
    });
    const pending = mobileUpdate.download();
    await vi.waitFor(() => expect(mocks.invoke).toHaveBeenCalledTimes(1));
    expect(listener).not.toHaveBeenCalledWith(expect.objectContaining({ type: "downloaded" }));
    expect(mocks.invoke).not.toHaveBeenCalledWith("plugin:ipa-update|share");
    ready();
    await pending;
    expect(listener).toHaveBeenLastCalledWith(expect.objectContaining({ type: "downloaded" }));
    expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:ipa-update|share");
  });

  it.each([
    ["a".repeat(40), "2026-09-05T00:00:00Z", "available"],
    ["1234567".padEnd(40, "0"), "2026-09-05T00:00:00Z", "notAvailable"],
    ["a".repeat(40), "2026-08-01T00:00:00Z", "notAvailable"],
  ])("Action 按提交和日期识别同版本构建 %s", async (commit, date, expected) => {
    const { mobileUpdate } = await import("./update");
    mocks.get.mockImplementation((key) => (key === "update.channel" ? "action" : true));
    const listener = vi.fn();
    mobileUpdate.onEvent(listener);
    mocks.fetch.mockResolvedValue(
      Response.json(
        release("action-latest", {
          prerelease: true,
          body: `<!-- splayer-action:${JSON.stringify({ commit, date, version: "1.0.0", asset: "SPlayer-Next-iOS-unsigned.ipa" })} -->\nAction 更新`,
        }),
      ),
    );
    await mobileUpdate.check(true);
    expect(mocks.fetch.mock.calls[0][0]).toContain("/releases/tags/action-latest");
    expect(listener).toHaveBeenLastCalledWith(expect.objectContaining({ type: expected }));
  });
  it("识别 iOS 标签，复用弹窗并打开对应 Release，不提供自动安装", async () => {
    const { mobileUpdate } = await import("./update");
    const events: UpdateEvent[] = [];
    const stop = mobileUpdate.onEvent((event) => events.push(event));
    mocks.fetch.mockResolvedValue(Response.json([release()]));
    await mobileUpdate.check(true);
    expect(mocks.fetch.mock.calls[0][0]).toBe(
      "https://api.github.com/repos/q3cc/SPlayer-Next-ios/releases?per_page=100",
    );
    expect(events).toEqual([
      { type: "checking" },
      {
        type: "available",
        manual: true,
        canInstall: true,
        meta: {
          version: "1.1.0",
          releaseNotes: "更新说明",
          releaseDate: "2026-09-05T00:00:00Z",
          size: 1234,
        },
      },
    ]);
    await mobileUpdate.openDownloadPage();
    expect(mocks.open).toHaveBeenCalledWith(
      "https://github.com/q3cc/SPlayer-Next-ios/releases/tag/ios-v1.1.0",
    );
    stop();
    await mobileUpdate.check(true);
    expect(events).toHaveLength(2);
  });

  it.each(["ios-v1.0.0", "ios-v0.1.0"])("同版或旧版 %s 不提示更新", async (tag) => {
    const { mobileUpdate } = await import("./update");
    const listener = vi.fn();
    mobileUpdate.onEvent(listener);
    mocks.fetch.mockResolvedValue(Response.json([release(tag)]));
    await mobileUpdate.check(true);
    expect(listener).toHaveBeenLastCalledWith({ type: "notAvailable", manual: true });
  });

  it("正式通道忽略预发布、草稿和没有 IPA 的版本，按数字比较版本", async () => {
    const { mobileUpdate } = await import("./update");
    const listener = vi.fn();
    mobileUpdate.onEvent(listener);
    mocks.fetch.mockResolvedValue(
      Response.json([
        release("ios-v9.0.0", { prerelease: true }),
        release("ios-v8.0.0", { draft: true }),
        release("ios-v7.0.0", { assets: [] }),
        release("ios-v6.0.0-alpha.1"),
        release("ios-v1.2.0"),
        release("ios-v1.10.0"),
      ]),
    );
    await mobileUpdate.check(true);
    expect(listener).toHaveBeenLastCalledWith(
      expect.objectContaining({ meta: expect.objectContaining({ version: "1.10.0" }) }),
    );
  });

  it.each([
    ["beta", "2.0.0-beta.10"],
    ["alpha", "3.0.0-alpha.1"],
  ])("%s 通道筛选版本", async (channel, expected) => {
    const { mobileUpdate } = await import("./update");
    mocks.get.mockImplementation((key) => (key === "update.channel" ? channel : true));
    const listener = vi.fn();
    mobileUpdate.onEvent(listener);
    mocks.fetch.mockResolvedValue(
      Response.json([
        release("ios-v2.0.0-beta.2", { prerelease: true }),
        release("ios-v2.0.0-beta.10", { prerelease: true }),
        release("ios-v3.0.0-alpha.1", { prerelease: true }),
      ]),
    );
    await mobileUpdate.check(true);
    expect(listener).toHaveBeenLastCalledWith(
      expect.objectContaining({ meta: expect.objectContaining({ version: expected }) }),
    );
  });

  it("自动检查关闭时不请求；手动检查失败发出错误并允许重试", async () => {
    const { mobileUpdate } = await import("./update");
    mocks.get.mockReturnValue(false);
    const listener = vi.fn();
    mobileUpdate.onEvent(listener);
    await mobileUpdate.check(false);
    expect(mocks.fetch).not.toHaveBeenCalled();
    mocks.fetch.mockResolvedValueOnce(new Response(null, { status: 403 }));
    await mobileUpdate.check(true);
    expect(listener).toHaveBeenLastCalledWith(
      expect.objectContaining({ type: "error", manual: true }),
    );
    mocks.fetch.mockResolvedValueOnce(Response.json([]));
    await mobileUpdate.check(true);
    expect(listener).toHaveBeenLastCalledWith({ type: "notAvailable", manual: true });
  });

  it("合并并发检查，保留手动检查反馈", async () => {
    const { mobileUpdate } = await import("./update");
    const listener = vi.fn();
    mobileUpdate.onEvent(listener);
    let resolve!: (value: Response) => void;
    mocks.fetch.mockReturnValue(
      new Promise<Response>((done) => {
        resolve = done;
      }),
    );
    const first = mobileUpdate.check(false);
    const second = mobileUpdate.check(true);
    resolve(Response.json([]));
    await Promise.all([first, second]);
    expect(mocks.fetch).toHaveBeenCalledTimes(1);
    expect(listener).toHaveBeenLastCalledWith({ type: "notAvailable", manual: true });
  });
});
