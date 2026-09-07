import { beforeEach, expect, it, vi } from "vitest";
import type { Track } from "@shared/types/player";
const mocks = vi.hoisted(() => ({
  artists: vi.fn(),
  songs: vi.fn(),
  netease: vi.fn(),
  qqmusic: vi.fn(),
}));
vi.mock("@/apis/search", () => ({ searchArtists: mocks.artists, searchSongs: mocks.songs }));
vi.mock("@/apis/artist/netease", () => ({ fetchArtistSongs: mocks.netease }));
vi.mock("@/apis/artist/qqmusic", () => ({ fetchQQMusicArtistSongs: mocks.qqmusic }));
import { loadSiriArtistPage } from "./artistCollection";
import { siriCollectionArtist } from "./searchMatching";
const song = (id: string, source: Track["source"] = "netease", name = "周杰伦"): Track => ({
  source,
  id,
  title: id,
  artists: [{ id: "jay", name }],
  duration: 100000,
});
const options = { source: "netease" as const, scope: "online", library: [] as Track[] };
beforeEach(() => {
  vi.resetAllMocks();
  mocks.artists.mockResolvedValue({ items: [{ id: "jay", title: "周杰伦" }] });
  mocks.netease.mockResolvedValue({ tracks: [], more: false });
  mocks.qqmusic.mockResolvedValue({ tracks: [], more: false });
  mocks.songs.mockResolvedValue({ items: [], hasMore: false });
});
it("识别歌手集合但不误认具体歌名", () => {
  expect(siriCollectionArtist("周杰伦的所有歌", "")).toBe("周杰伦");
  expect(siriCollectionArtist("", "周杰伦")).toBe("周杰伦");
  expect(siriCollectionArtist("方大同的特别的人", "")).toBeNull();
});

it("同名陶喆优先选择作品量充分的歌手身份，不让用户逐个确认", async () => {
  mocks.artists.mockResolvedValue({
    items: [
      { id: "user", title: "陶喆", artistSongCount: 1, artistAlbumCount: 0 },
      { id: "jay", title: "陶喆", artistSongCount: 200, artistAlbumCount: 20 },
    ],
  });
  mocks.netease.mockResolvedValue({ tracks: [song("普通朋友", "netease", "陶喆")], more: false });
  const result = await loadSiriArtistPage("陶喆", options);
  expect(mocks.netease).toHaveBeenCalledWith("jay", 0, 50);
  expect(result.needsConfirmation).toBe(false);
  expect(result.tracks[0].title).toBe("普通朋友");
});
it("超过十首仍保留完整首批，分页去重并保留现场及合作曲", async () => {
  const first = Array.from({ length: 50 }, (_, index) => song(`歌${index}`));
  mocks.netease.mockResolvedValueOnce({ tracks: first, more: true }).mockResolvedValueOnce({
    tracks: [
      first[0],
      song("晴天（Live）"),
      { ...song("合作"), artists: [{ id: "jay", name: "周杰伦" }, { name: "乙" }] },
      song("冒充", "netease", "其他人"),
    ],
    more: false,
  });
  mocks.qqmusic.mockResolvedValue({ tracks: [song("歌0", "qqmusic")], more: false });
  const result = await loadSiriArtistPage("周杰伦", options);
  expect(result.tracks).toHaveLength(50);
  expect(result.needsConfirmation).toBe(false);
  const next = await loadSiriArtistPage("周杰伦", { ...options, collection: result.collection });
  expect(next.tracks.map((track) => track.title).sort()).toEqual(["合作", "晴天（Live）"]);
  expect(mocks.netease).toHaveBeenLastCalledWith("jay", 50, 50);
  expect(next.collection?.cursors.every((cursor) => cursor.done)).toBe(true);
});
it("优先本地立即返回但仍保留在线游标，仅本地不查询网络", async () => {
  const result = await loadSiriArtistPage("周杰伦", {
    ...options,
    scope: "localFirst",
    library: [song("本地", "local")],
  });
  expect(result.tracks).toHaveLength(1);
  expect(result.collection?.cursors).toHaveLength(3);
  expect(mocks.artists).not.toHaveBeenCalled();
  const local = await loadSiriArtistPage("周杰伦", {
    ...options,
    scope: "local",
    library: [song("本地", "local")],
  });
  expect(local.collection?.cursors).toEqual([]);
});
it("失败保留游标，下次重试；平台重复返回同一页时停止本轮补页", async () => {
  mocks.netease
    .mockRejectedValueOnce(new Error("断网"))
    .mockResolvedValue({ tracks: [song("晴天")], more: true });
  const failed = await loadSiriArtistPage("周杰伦", options);
  expect(failed.pageFailed).toBe(true);
  expect(failed.collection?.cursors[0].offset).toBe(0);
  const next = await loadSiriArtistPage("周杰伦", { ...options, collection: failed.collection });
  const repeated = await loadSiriArtistPage("周杰伦", { ...options, collection: next.collection });
  expect(repeated.pageFailed).toBe(true);
  expect(repeated.tracks).toEqual([]);
});
