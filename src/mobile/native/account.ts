import { fetchLoginStatus, logoutNetease } from "@/apis/login/netease";
import { clearNeteaseSession } from "@/apis/netease";
import {
  fetchSubcount,
  fetchUserAlbums,
  fetchUserArtists,
  fetchUserLevel,
  fetchUserPlaylists,
} from "@/apis/user/netease";
import { fetchRadarPlaylists, fetchRecommendPlaylists } from "@/apis/recommend/netease";
import { fetchAlbum } from "@/apis/album/netease";
import { fetchArtist } from "@/apis/artist/netease";
import { albumToCoverItem, artistToCoverItem, playlistToCoverItem } from "@/utils/format/coverItem";
import type { CoverItem } from "@/types/artist";
import type { Playlist, Track } from "@shared/types/player";

/** 原生卡片可打开的内容类型 */
export type NativeCoverKind = "playlist" | "album" | "artist";

/** 原生卡片，与 Swift 的 NativeCover 字段一致 */
export interface NativeCover {
  id: string;
  title: string;
  cover: string;
  subtitle?: string;
  kind: NativeCoverKind;
}

/** 登录后展示的账号信息，对应原版 user store 的资料、等级、计数与歌单分组 */
export interface NativeAccount {
  userId: number;
  nickname: string;
  avatarUrl?: string;
  signature?: string;
  vipType: number;
  level?: number;
  playlistCount: number;
  albumCount: number;
  artistCount: number;
  /** 「我喜欢的音乐」歌单 */
  liked?: NativeCover;
  /** 自建歌单，不含「我喜欢的音乐」 */
  created: NativeCover[];
  /** 收藏歌单 */
  subscribed: NativeCover[];
  albums: NativeCover[];
  artists: NativeCover[];
}

/**
 * 展示模型转为原生卡片
 * @param item - 平台展示模型
 * @param kind - 内容类型
 * @param subtitle - 副标题
 * @returns 原生卡片
 */
export const toNativeCover = (
  item: CoverItem,
  kind: NativeCoverKind,
  subtitle = item.subtitle,
): NativeCover => ({
  id: item.id,
  title: item.title,
  cover: item.cover ?? "",
  ...(subtitle ? { subtitle } : {}),
  kind,
});

/**
 * 按原版规则拆分用户歌单：前 N 个为自建（第一个是「我喜欢的音乐」），其余为收藏
 * @param playlists - 平台返回的全部歌单
 * @param createdCount - 自建歌单数，缺失时视为只有「我喜欢的音乐」
 * @returns 自建与收藏两组
 */
export const splitPlaylists = (
  playlists: Playlist[],
  createdCount: number,
): { created: Playlist[]; subscribed: Playlist[] } => ({
  created: playlists.slice(0, createdCount > 0 ? createdCount : 1),
  subscribed: playlists.slice(createdCount > 0 ? createdCount : 1),
});

/**
 * 歌单卡片的副标题为歌曲数
 * @param playlist - 歌单
 * @returns 原生卡片
 */
const playlistCover = (playlist: Playlist): NativeCover => {
  const item = playlistToCoverItem(playlist);
  return toNativeCover(item, "playlist", item.trackCount ? `${item.trackCount} 首` : undefined);
};

/**
 * 读取网易云账号信息；单项失败只影响对应区块，与原版各自独立拉取一致
 * @returns 未登录时为 null
 */
export const loadNativeAccount = async (): Promise<NativeAccount | null> => {
  const profile = await fetchLoginStatus();
  if (!profile) return null;
  const [level, subcount, playlists, albums, artists] = await Promise.all([
    fetchUserLevel().catch(() => undefined),
    fetchSubcount().catch(() => undefined),
    fetchUserPlaylists(profile.userId).catch(() => [] as Playlist[]),
    fetchUserAlbums().catch(() => []),
    fetchUserArtists().catch(() => []),
  ]);
  const groups = splitPlaylists(playlists, subcount?.createdPlaylistCount ?? 0);
  return {
    userId: profile.userId,
    nickname: profile.nickname,
    avatarUrl: profile.avatarUrl,
    signature: profile.signature,
    vipType: profile.vipType ?? 0,
    level,
    playlistCount:
      (subcount?.createdPlaylistCount ?? 0) + (subcount?.subPlaylistCount ?? 0) || playlists.length,
    albumCount: albums.length,
    artistCount: subcount?.artistCount ?? artists.length,
    liked: groups.created[0] ? playlistCover(groups.created[0]) : undefined,
    created: groups.created.slice(1).map(playlistCover),
    subscribed: groups.subscribed.map(playlistCover),
    albums: albums.map((album) => toNativeCover(albumToCoverItem(album), "album")),
    artists: artists.map((artist) => toNativeCover(artistToCoverItem(artist), "artist")),
  };
};

/** 退出网易云：先结束服务端会话，再清本地 cookie，与原版 logout 一致 */
export const logoutNativeAccount = async (): Promise<void> => {
  try {
    await logoutNetease();
  } catch {
    console.warn("[account] 服务端登出失败，继续清理本地会话");
  }
  await clearNeteaseSession();
};

/**
 * 首页推荐：登录后为专属歌单并附带雷达歌单，雷达失败不影响推荐
 * @param loggedIn - 是否已登录
 * @returns 推荐歌单与雷达歌单
 */
export const loadNativeHome = async (
  loggedIn: boolean,
): Promise<{ recommend: NativeCover[]; radar: NativeCover[] }> => {
  const [recommend, radar] = await Promise.all([
    fetchRecommendPlaylists(loggedIn),
    loggedIn ? fetchRadarPlaylists().catch(() => [] as CoverItem[]) : Promise.resolve([]),
  ]);
  return {
    recommend: recommend.map((item) => toNativeCover(item, "playlist")),
    radar: radar.map((item) => toNativeCover(item, "playlist")),
  };
};

/**
 * 读取专辑或歌手的曲目，供原生歌单详情页展示
 * @param kind - 专辑或歌手
 * @param id - 平台 id
 * @returns 曲目列表
 */
export const loadNativeCollection = async (
  kind: "album" | "artist",
  id: string,
): Promise<{ tracks: Track[] }> => {
  if (!/^\d{1,20}$/.test(id)) throw new Error("无效的内容 id");
  const result = kind === "album" ? await fetchAlbum(id) : await fetchArtist(id);
  if (!result) throw new Error(kind === "album" ? "专辑不存在" : "歌手不存在");
  return { tracks: result.tracks };
};
