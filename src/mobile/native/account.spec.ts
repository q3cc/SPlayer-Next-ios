import { beforeEach, expect, it, vi } from "vitest";
import {
  loadNativeAccount,
  loadNativeCollection,
  loadNativeHome,
  logoutNativeAccount,
  splitPlaylists,
} from "./account";

const mocks = vi.hoisted(() => ({
  status: vi.fn(),
  logout: vi.fn(),
  clear: vi.fn(),
  level: vi.fn(),
  subcount: vi.fn(),
  playlists: vi.fn(),
  albums: vi.fn(),
  artists: vi.fn(),
  recommend: vi.fn(),
  radar: vi.fn(),
  album: vi.fn(),
  artist: vi.fn(),
}));
vi.mock("@/apis/login/netease", () => ({
  fetchLoginStatus: mocks.status,
  logoutNetease: mocks.logout,
}));
vi.mock("@/apis/netease", () => ({ clearNeteaseSession: mocks.clear }));
vi.mock("@/apis/user/netease", () => ({
  fetchUserLevel: mocks.level,
  fetchSubcount: mocks.subcount,
  fetchUserPlaylists: mocks.playlists,
  fetchUserAlbums: mocks.albums,
  fetchUserArtists: mocks.artists,
}));
vi.mock("@/apis/recommend/netease", () => ({
  fetchRecommendPlaylists: mocks.recommend,
  fetchRadarPlaylists: mocks.radar,
}));
vi.mock("@/apis/album/netease", () => ({ fetchAlbum: mocks.album }));
vi.mock("@/apis/artist/netease", () => ({ fetchArtist: mocks.artist }));

beforeEach(() => vi.resetAllMocks());

const playlist = (id: string, trackCount = 3) => ({
  id,
  name: "歌单" + id,
  cover: "https://p.cn/" + id,
  trackCount,
});

it("按自建数量拆分歌单，缺失时只把第一个视为自建", () => {
  const all = ["1", "2", "3", "4"].map((id) => playlist(id));
  expect(splitPlaylists(all, 2).created.map((item) => item.id)).toEqual(["1", "2"]);
  expect(splitPlaylists(all, 2).subscribed.map((item) => item.id)).toEqual(["3", "4"]);
  expect(splitPlaylists(all, 0).created.map((item) => item.id)).toEqual(["1"]);
});

it("未登录返回 null，不拉取账号数据", async () => {
  mocks.status.mockResolvedValue(null);
  expect(await loadNativeAccount()).toBeNull();
  expect(mocks.playlists).not.toHaveBeenCalled();
});

it("登录后汇总资料、计数与歌单分组，单项失败不影响其他区块", async () => {
  mocks.status.mockResolvedValue({
    userId: 7,
    nickname: "听众",
    avatarUrl: "https://a.cn/1",
    signature: "签名",
    vipType: 11,
  });
  mocks.level.mockRejectedValue(new Error("网络"));
  mocks.subcount.mockResolvedValue({ createdPlaylistCount: 2, subPlaylistCount: 1, artistCount: 5 });
  mocks.playlists.mockResolvedValue([playlist("1", 10), playlist("2"), playlist("3", 0)]);
  mocks.albums.mockResolvedValue([{ id: "9", name: "专辑", cover: "c", artist: "歌手" }]);
  mocks.artists.mockResolvedValue([{ id: "8", name: "歌手", avatar: "a" }]);
  const account = await loadNativeAccount();
  expect(mocks.playlists).toHaveBeenCalledWith(7);
  expect(account).toMatchObject({
    nickname: "听众",
    vipType: 11,
    level: undefined,
    playlistCount: 3,
    albumCount: 1,
    artistCount: 5,
    liked: { id: "1", subtitle: "10 首", kind: "playlist" },
    created: [{ id: "2", kind: "playlist" }],
    subscribed: [{ id: "3", kind: "playlist" }],
    albums: [{ id: "9", title: "专辑", subtitle: "歌手", kind: "album" }],
    artists: [{ id: "8", title: "歌手", cover: "a", kind: "artist" }],
  });
  expect(account?.subscribed[0]).not.toHaveProperty("subtitle");
});

it("退出登录即使服务端失败也清除本地会话", async () => {
  mocks.logout.mockRejectedValue(new Error("网络"));
  await logoutNativeAccount();
  expect(mocks.clear).toHaveBeenCalledOnce();
});

it("首页登录后附带雷达歌单，雷达失败不影响推荐；未登录不请求雷达", async () => {
  mocks.recommend.mockResolvedValue([{ id: "1", title: "推荐", cover: "c", trackCount: 0 }]);
  mocks.radar.mockRejectedValue(new Error("网络"));
  expect(await loadNativeHome(true)).toEqual({
    recommend: [{ id: "1", title: "推荐", cover: "c", kind: "playlist" }],
    radar: [],
  });
  expect(mocks.recommend).toHaveBeenCalledWith(true);
  await loadNativeHome(false);
  expect(mocks.recommend).toHaveBeenLastCalledWith(false);
  expect(mocks.radar).toHaveBeenCalledOnce();
});

it("专辑与歌手只接受数字 id 并返回曲目", async () => {
  await expect(loadNativeCollection("album", "1&cookie=x")).rejects.toThrow("无效");
  mocks.album.mockResolvedValue({ album: {}, tracks: [{ id: "t" }] });
  expect(await loadNativeCollection("album", "12")).toEqual({ tracks: [{ id: "t" }] });
  mocks.artist.mockResolvedValue(null);
  await expect(loadNativeCollection("artist", "3")).rejects.toThrow("歌手不存在");
});
