import { beforeEach, describe, expect, it, vi } from "vitest";
import { streamingSourceForTrack } from "@shared/utils/streamingSource";

const mocks = vi.hoisted(() => ({
  adapter: {
    listSongs: vi.fn(),
    listAlbums: vi.fn(),
    listArtists: vi.fn(),
    listPlaylists: vi.fn(),
    getFavorite: vi.fn(),
    setFavorite: vi.fn(),
    getDownloadUrl: vi.fn(),
    preparePlayback: vi.fn(),
    reportPlayback: vi.fn(),
  },
  invalidate: vi.fn(),
}));
vi.mock("@main/services/streaming/adapters/resolve", () => ({
  resolveStreamingAdapter: async (config: unknown) => ({ config, adapter: mocks.adapter }),
  invalidateStreamingSession: mocks.invalidate,
}));
const server = {
  name: "Test",
  type: "navidrome" as const,
  url: "https://music.example",
  username: "tester",
  password: "test",
};

beforeEach(() => {
  vi.resetModules();
  localStorage.clear();
  vi.resetAllMocks();
  mocks.adapter.listSongs.mockResolvedValue([]);
  mocks.adapter.listAlbums.mockResolvedValue([]);
  mocks.adapter.listArtists.mockResolvedValue([]);
  mocks.adapter.listPlaylists.mockResolvedValue([]);
  mocks.adapter.reportPlayback.mockResolvedValue(undefined);
});

describe("移动流媒体上游契约", () => {
  it("持续分页到空页，同步失败保持最后完整快照", async () => {
    const { mobileStreaming: api } = await import("./streaming");
    const { id } = await api.addServer(server);
    const song = (n: number) => ({
      id: `${id}:${n}`,
      originalId: String(n),
      serverId: id,
      source: "streaming",
      title: `Song ${n}`,
      artists: [],
      duration: 10000,
    });
    mocks.adapter.listSongs.mockImplementation(async (_config, params) =>
      Array.from({ length: Math.min(100, Math.max(0, 1201 - params.offset)) }, (_, n) =>
        song(n + params.offset),
      ),
    );
    const updates = vi.fn();
    api.onSyncState(updates);
    await api.sync(id);
    expect((await api.getSnapshot(id)).songs).toHaveLength(1201);
    expect(updates).toHaveBeenLastCalledWith(expect.objectContaining({ state: "completed" }));
    mocks.adapter.listSongs.mockRejectedValueOnce(new Error("offline"));
    await expect(api.sync(id)).rejects.toThrow("offline");
    expect((await api.getSnapshot(id)).songs).toHaveLength(1201);
    expect(updates).toHaveBeenLastCalledWith(expect.objectContaining({ state: "failed" }));
  });
  it("重命名保持媒体身份，更换账号拒绝旧曲目；下载不会上报播放", async () => {
    const { mobileStreaming: api, resolveMobileStreamingDownload } = await import("./streaming");
    const { id } = await api.addServer(server);
    const source = streamingSourceForTrack({
      id: `${id}:one`,
      source: "streaming",
      serverId: id,
      originalId: "one",
      title: "One",
      artists: [],
      duration: 10000,
    });
    mocks.adapter.getDownloadUrl.mockResolvedValue("https://music.example/download/one");
    await api.updateServer(id, { ...server, name: "Renamed", password: "" });
    expect(await resolveMobileStreamingDownload(source)).toBe("https://music.example/download/one");
    expect(mocks.adapter.reportPlayback).not.toHaveBeenCalled();
    await api.updateServer(id, { ...server, username: "other" });
    await expect(resolveMobileStreamingDownload(source)).rejects.toThrow("旧服务器身份");
  });
  it("收藏采用服务端确认值并发布单曲事件", async () => {
    const { mobileStreaming: api } = await import("./streaming");
    const { id } = await api.addServer(server);
    const changed = vi.fn();
    api.onFavoriteChanged(changed);
    mocks.adapter.setFavorite.mockResolvedValue(false);
    expect(await api.setFavorite(id, "one", true)).toBe(false);
    expect(changed).toHaveBeenCalledWith({ serverId: id, trackId: "one", favorite: false });
  });
});

it("缓存播放不等待联网，实际播放后才开始和结束上报", async () => {
  const { mobileStreaming: api, prepareMobileStreamingPlayback } = await import("./streaming");
  const { id } = await api.addServer(server);
  const prepared = await prepareMobileStreamingPlayback(
    `streaming://${id}/one`,
    200000,
    "/Downloads/one.flac",
  );
  expect(prepared.source).toBe("/Downloads/one.flac");
  expect(mocks.adapter.preparePlayback).not.toHaveBeenCalled();
  expect(mocks.adapter.reportPlayback).not.toHaveBeenCalled();
  prepared.session.state(true);
  await vi.waitFor(() =>
    expect(mocks.adapter.reportPlayback).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ event: "start", trackId: "one" }),
    ),
  );
  await prepared.session.stop();
  expect(mocks.adapter.reportPlayback).toHaveBeenLastCalledWith(
    expect.anything(),
    expect.objectContaining({ event: "stop", trackId: "one" }),
  );
});
