import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateEvent } from "@shared/types/update";

const mocks = vi.hoisted(() => ({
  fetch: vi.fn(),
  invoke: vi.fn(),
  addListener: vi.fn(),
  unregister: vi.fn(),
  get: vi.fn(),
  open: vi.fn(),
}));
vi.mock("@tauri-apps/api/core", () => ({
  invoke: mocks.invoke,
  addPluginListener: mocks.addListener,
}));
vi.mock("./shims/proxy", () => ({ fetchWithProxy: mocks.fetch }));
vi.mock("./shims/store", () => ({ store: { get: mocks.get } }));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: mocks.open }));

const asset = (arch: string) => ({
  name: `SPlayer-Next-Android-${arch}-abcdef0.apk`,
  size: 1234,
  state: "uploaded",
  digest: "sha256:deadbeef",
  browser_download_url: `https://github.com/q3cc/SPlayer-Next-ios/releases/download/android-action-latest/SPlayer-Next-Android-${arch}-abcdef0.apk`,
});
const release = (commit = "abcdef0" + "1".repeat(33)) => ({
  tag_name: "android-action-latest",
  draft: false,
  prerelease: true,
  body: `<!-- splayer-android-action:${JSON.stringify({ commit, version: "2.0.0", date: "2099-01-01T00:00:00Z" })} -->`,
  published_at: "2099-01-01T00:00:00Z",
  assets: [asset("arm64"), asset("arm32"), asset("x64")],
});

beforeEach(() => {
  vi.resetModules();
  mocks.fetch.mockReset().mockResolvedValue(Response.json(release()));
  mocks.invoke
    .mockReset()
    .mockImplementation((command) =>
      command === "plugin:native-audio|device_abi"
        ? Promise.resolve("armeabi-v7a")
        : Promise.resolve("/cache/update.apk"),
    );
  mocks.addListener.mockReset().mockResolvedValue({ unregister: mocks.unregister });
  mocks.unregister.mockReset();
  mocks.get.mockReset().mockImplementation((key) => (key === "update.autoCheck" ? true : "action"));
  mocks.open.mockReset();
});

describe("Android 应用内更新", () => {
  it.each([
    ["arm64-v8a", "arm64"],
    ["armeabi-v7a", "arm32"],
    ["x86_64", "x64"],
  ])("为 %s 选择 %s APK，回报下载进度并交给系统安装", async (abi, arch) => {
    mocks.invoke.mockResolvedValueOnce(abi);
    const { androidUpdate } = await import("./androidUpdate");
    const events: UpdateEvent[] = [];
    androidUpdate.onEvent((event) => events.push(event));
    await androidUpdate.check(true);
    expect(events).toContainEqual(expect.objectContaining({ type: "available", canInstall: true }));
    mocks.addListener.mockImplementation(async (_plugin, _event, callback) => {
      callback({ percent: 50, downloadedBytes: 617, totalBytes: 1234, bytesPerSecond: 100 });
      return { unregister: mocks.unregister };
    });
    await androidUpdate.download();
    expect(mocks.invoke).toHaveBeenCalledWith("plugin:native-audio|download_update", {
      url: asset(arch).browser_download_url,
      size: 1234,
      digest: "sha256:deadbeef",
    });
    expect(events).toContainEqual(expect.objectContaining({ type: "progress", percent: 50 }));
    expect(events).toContainEqual(expect.objectContaining({ type: "downloaded" }));
    expect(mocks.unregister).toHaveBeenCalled();
    await androidUpdate.install();
    expect(mocks.invoke).toHaveBeenCalledWith("plugin:native-audio|install_update", {
      path: "/cache/update.apk",
    });
  });

  it("新旧构建附件共存时只下载发布信息指定的提交", async () => {
    const older = asset("arm32");
    older.name = older.name.replace("abcdef0", "abcdef1");
    older.browser_download_url = older.browser_download_url.replace("abcdef0", "abcdef1");
    mocks.fetch.mockResolvedValue(Response.json({ ...release(), assets: [older, asset("arm32")] }));
    const { androidUpdate } = await import("./androidUpdate");
    await androidUpdate.check(true);
    await androidUpdate.download();
    expect(mocks.invoke).toHaveBeenCalledWith("plugin:native-audio|download_update", {
      url: asset("arm32").browser_download_url,
      size: 1234,
      digest: "sha256:deadbeef",
    });
  });

  it("当前提交与 Action 构建相同时不重复更新", async () => {
    const current = asset("arm32");
    current.name = current.name.replace("abcdef0", "1234567");
    current.browser_download_url = current.browser_download_url.replace("abcdef0", "1234567");
    mocks.fetch.mockResolvedValue(
      Response.json({ ...release("1234567" + "0".repeat(33)), assets: [current] }),
    );
    const { androidUpdate } = await import("./androidUpdate");
    const events: UpdateEvent[] = [];
    androidUpdate.onEvent((event) => events.push(event));
    await androidUpdate.check(true);
    expect(events.at(-1)).toEqual({ type: "notAvailable", manual: true });
  });

  it("正式渠道忽略测试版并选择最新且架构匹配的正式版", async () => {
    mocks.get.mockImplementation((key) => (key === "update.autoCheck" ? true : "stable"));
    mocks.fetch.mockResolvedValue(
      Response.json([
        { ...release(), tag_name: "android-v4.0.0-beta.1" },
        { ...release(), tag_name: "android-v2.1.0", prerelease: false },
        { ...release(), tag_name: "android-v3.0.0", prerelease: false },
        { ...release(), tag_name: "android-v5.0.0", prerelease: false, assets: [asset("arm64")] },
      ]),
    );
    const { androidUpdate } = await import("./androidUpdate");
    const events: UpdateEvent[] = [];
    androidUpdate.onEvent((event) => events.push(event));
    await androidUpdate.check(true);
    expect(events.at(-1)).toMatchObject({ type: "available", meta: { version: "3.0.0" } });
  });

  it("下载失败时保留可重试的更新并注销进度监听", async () => {
    const { androidUpdate } = await import("./androidUpdate");
    const events: UpdateEvent[] = [];
    androidUpdate.onEvent((event) => events.push(event));
    await androidUpdate.check(true);
    mocks.invoke.mockRejectedValueOnce(new Error("网络连接中断"));
    await androidUpdate.download();
    expect(events.at(-1)).toMatchObject({ type: "error", manual: true });
    expect(mocks.unregister).toHaveBeenCalledOnce();
    await androidUpdate.download();
    expect(events.at(-1)).toMatchObject({ type: "downloaded" });
  });

  it("安装权限需要手动允许时保留已下载状态并说明原因", async () => {
    const { androidUpdate } = await import("./androidUpdate");
    const events: UpdateEvent[] = [];
    androidUpdate.onEvent((event) => events.push(event));
    await androidUpdate.check(true);
    await androidUpdate.download();
    mocks.invoke.mockRejectedValueOnce(new Error("请允许安装应用后返回，再点击安装"));
    await androidUpdate.install();
    expect(events.at(-1)).toMatchObject({ type: "error", stage: "install", manual: true });
  });

  it("没有对应架构附件时不提供错误 APK", async () => {
    mocks.fetch.mockResolvedValue(
      Response.json({ ...release(), assets: [asset("arm64"), asset("x64")] }),
    );
    const { androidUpdate } = await import("./androidUpdate");
    const events: UpdateEvent[] = [];
    androidUpdate.onEvent((event) => events.push(event));
    await androidUpdate.check(true);
    expect(events.at(-1)).toEqual({ type: "notAvailable", manual: true });
    expect(mocks.invoke).not.toHaveBeenCalledWith(
      "plugin:native-audio|download_update",
      expect.anything(),
    );
  });
});
