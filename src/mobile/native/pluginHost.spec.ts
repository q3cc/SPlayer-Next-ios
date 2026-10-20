import { beforeEach, expect, it, vi } from "vitest";
import { dispatchNativePluginRequest } from "./pluginHost";
const mocks = vi.hoisted(() => ({ api: vi.fn(), search: vi.fn() }));
vi.mock("../providers", () => ({ mobileProviders: { call: mocks.api } }));
vi.mock("@/apis/search", () => ({ searchSongs: mocks.search }));
beforeEach(() => vi.resetAllMocks());
it("原生宿主拒绝插件注入认证路由并过滤嵌套凭据", async () => {
  for (const key of ["cookie", "domain", "proxy", "headers"]) {
    await expect(
      dispatchNativePluginRequest("api.call", ["netease", "song_detail", { [key]: "secret" }]),
    ).rejects.toThrow(key);
  }
  expect(mocks.api).not.toHaveBeenCalled();
  mocks.api.mockResolvedValue({
    ok: true,
    body: {
      cookie: "secret",
      data: [{ title: "歌", access_token: "secret" }],
      "Set-Cookie": "secret",
    },
  });
  expect(
    await dispatchNativePluginRequest("api.call", ["netease", "song_detail", { ids: "1" }]),
  ).toEqual({ ok: true, body: { data: [{ title: "歌" }] } });
});
it("原生宿主保持毫秒单位并限制队列和曲库参数", async () => {
  expect(await dispatchNativePluginRequest("player.seek", [12345])).toEqual([12345]);
  await expect(dispatchNativePluginRequest("player.seek", [NaN])).rejects.toThrow();
  await expect(dispatchNativePluginRequest("player.getQueue", [{ limit: 101 }])).rejects.toThrow();
  await expect(dispatchNativePluginRequest("music.searchLibrary", ["歌", 101])).rejects.toThrow();
  await expect(
    dispatchNativePluginRequest("player.playTrack", [{ id: "1", source: "plugin" }]),
  ).rejects.toThrow();
});
it("独立搜索保留插件身份和分页，丢弃无效候选", async () => {
  const result = await dispatchNativePluginRequest("normalizeSearch", [
    { pluginId: "test", source: "wy", keyword: "歌", page: 2, limit: 20 },
    { list: [{ id: "1", name: "歌", durationMs: 123000 }, { id: "2" }], total: 42 },
  ]);
  expect(result).toMatchObject({
    total: 42,
    hasMore: true,
    items: [{ source: "plugin", duration: 123000, plugin: { pluginId: "test", source: "wy" } }],
  });
});
