import { beforeEach, expect, it, vi } from "vitest";
import { dispatchMobilePluginHost } from "./host";
const mocks = vi.hoisted(() => ({
  api: vi.fn(),
  search: vi.fn(),
  library: vi.fn(),
  play: vi.fn(),
  queue: vi.fn(),
}));
vi.mock("../providers", () => ({ mobileProviders: { call: mocks.api } }));
vi.mock("../library", () => ({ mobileLibrary: { searchTracks: mocks.library } }));
vi.mock("@/apis/search", () => ({ searchSongs: mocks.search }));
vi.mock("@/core/player", () => ({ playNow: mocks.play, insertManyToQueue: mocks.queue }));
beforeEach(() => vi.resetAllMocks());
it("平台接口拒绝覆写认证路由并递归过滤登录凭据", async () => {
  for (const key of ["cookie", "domain", "proxy", "headers"]) {
    await expect(
      dispatchMobilePluginHost(
        "api.call",
        ["netease", "song_detail", { [key]: "override" }],
        "测试",
      ),
    ).rejects.toThrow(key);
  }
  expect(mocks.api).not.toHaveBeenCalled();
  mocks.api.mockResolvedValue({
    ok: true,
    body: {
      name: "曲目",
      cookie: "secret",
      data: [{ access_token: "secret", title: "歌" }],
      "Set-Cookie": "secret",
    },
  });
  expect(
    await dispatchMobilePluginHost("api.call", ["netease", "song_detail", { ids: "1" }], "测试"),
  ).toEqual({ ok: true, body: { name: "曲目", data: [{ title: "歌" }] } });
});
it("搜索复用平台分页，曲库读取限制返回数量", async () => {
  mocks.search.mockResolvedValue({ items: [{ id: "one" }], total: 100, hasMore: true });
  expect(
    await dispatchMobilePluginHost(
      "music.searchOnline",
      [{ platform: "netease", query: "歌", page: 3, limit: 20 }],
      "测试",
    ),
  ).toMatchObject({ platform: "netease", page: 3, tracks: [{ id: "one" }], total: 100 });
  expect(mocks.search).toHaveBeenCalledWith("netease", "歌", 40, 20);
  mocks.library.mockResolvedValue({ success: true, data: [{ id: "1" }, { id: "2" }] });
  expect(await dispatchMobilePluginHost("music.searchLibrary", ["歌", 1], "测试")).toEqual({
    total: 2,
    tracks: [{ id: "1" }],
  });
  await expect(
    dispatchMobilePluginHost("music.searchLibrary", ["歌", 101], "测试"),
  ).rejects.toThrow();
  await expect(
    dispatchMobilePluginHost("player.playTrack", [{ id: "1", source: "plugin" }], "测试"),
  ).rejects.toThrow();
  expect(mocks.play).not.toHaveBeenCalled();
});
it("模块加载期间撤权也不能启动平台调用", async () => {
  await expect(
    dispatchMobilePluginHost("api.call", ["netease", "song_detail"], "测试", undefined, () => {
      throw new Error("权限已关闭");
    }),
  ).rejects.toThrow("权限已关闭");
  expect(mocks.api).not.toHaveBeenCalled();
});
