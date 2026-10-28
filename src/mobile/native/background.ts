import "./textEncoding";
import { exportNativeLyrics, loadNativeLyrics, parseNativeLyrics } from "./lyrics";
import {
  loadNativeAccount,
  loadNativeCollection,
  loadNativeHome,
  logoutNativeAccount,
} from "./account";
import { mobileProviders } from "../providers";
import { fetchUserCloud } from "@/apis/cloud/netease";
import { searchSongs } from "@/apis/search";
import {
  fetchDailySongs,
  fetchPersonalFm,
  fetchHeartModeList,
  submitFmTrash,
} from "@/apis/recommend/netease";
import { fetchUserPlaylists, fetchLikelist, toggleLikeSong } from "@/apis/user/netease";
import { fetchPlaylist } from "@/apis/playlist/netease";
import { songsByIds } from "@/apis/song/netease";
import { run as resolve } from "../siri/background";
import { neteaseQrLoginAdapter, fetchLoginStatus } from "@/apis/login/netease";
import { qqmusicQrLoginAdapter, fetchQQMusicLoginStatus } from "@/apis/login/qqmusic";
import { kugouQrLoginAdapter, fetchKugouLoginStatus } from "@/apis/login/kugou";
import { dispatchNativePluginRequest } from "./pluginHost";
import { matchFingerprint } from "../recognitionMatch";
import type { QualityLevel } from "@/utils/quality";
import type { Track } from "@shared/types/player";
import type { Platform } from "@shared/types/platform";
import type { PersonalFmMode, PersonalFmSubMode } from "@shared/types/platform/netease";

/** 与 Next 原版 FM 模式弹窗一致的可选模式与场景 */
const FM_MODES: PersonalFmMode[] = ["DEFAULT", "FAMILIAR", "EXPLORE", "SCENE_RCMD"];
const FM_SUBMODES = new Set<string>([
  "EXERCISE", "FOCUS", "SLEEP_HELP", "COMMUTE", "COFFEE_SHOP", "TAKE_SHOWER", "GAMES",
  "RELAX", "CHEERFUL", "NIGHT_EMO", "CURE", "LYRICAL", "SWEET", "INSPIRATIONAL", "RAINY",
  "GUOFENG", "CHINESE", "ENGLISH", "YUEYU", "JAPANESE", "K_POP", "FRANCH", "GLOBAL",
  "ELECTRONIC", "RAP", "ROCK", "FOLK", "ACG", "LIGHT", "JAZZ", "GUDIAN", "RHYTHM_BLUES",
  "BLUE", "PUNK", "DANCE", "LATIN", "COUNTRY", "MANYAO", "JINGDIAN", "ORIGINAL_MUSICIAL",
  "MUSICAL", "YINGSHI",
]);

/** 需要账号的网易云操作统一先确认登录，错误提示与原版一致 */
const requireNeteaseUser = async (message: string): Promise<number> => {
  const profile = await fetchLoginStatus();
  if (!profile) throw new Error(message);
  return profile.userId;
};

/** 平台曲目 ID 只接受纯数字，防止拼入其他接口参数 */
const neteaseId = (value: unknown): string => {
  const id = String(value ?? "");
  if (!/^\d{1,20}$/.test(id)) throw new Error("无效的网易云曲目");
  return id;
};

interface NativeRequest {
  action:
    | "cloud"
    | "loginCreate"
    | "loginCheck"
    | "loginStatus"
    | "pluginHost"
    | "search"
    | "home"
    | "account"
    | "logout"
    | "album"
    | "artist"
    | "playlist"
    | "resolve"
    | "lyrics"
    | "lyricExport"
    | "parseLyrics"
    | "detail"
    | "daily"
    | "fm"
    | "fmTrash"
    | "heart"
    | "like"
    | "likelist"
    | "recognize";
  key?: string;
  method?: string;
  args?: unknown[];
  source?: Platform;
  query?: string;
  content?: string;
  offset?: number;
  id?: string;
  track?: Track;
  quality?: QualityLevel;
  fingerprint?: string;
  duration?: number;
  mode?: string;
  submode?: string;
  like?: boolean;
  time?: number;
  format?: string;
  loggedIn?: boolean;
}

/** 原生界面复用已更新的平台接口；所有显示和交互由 SwiftUI/UIKit 完成
 * @param request - 原生界面发送的有界请求
 * @returns 不含登录凭据的业务数据
 */
export const run = async (request: NativeRequest): Promise<unknown> => {
  window.api = { apis: mobileProviders } as Window["api"];
  const source = request.source ?? "netease";
  switch (request.action) {
    case "cloud": {
      if (!(await fetchLoginStatus())) throw new Error("请先登录网易云账号");
      return fetchUserCloud(Math.max(0, request.offset ?? 0), 100);
    }
    case "loginCreate":
      return {
        netease: neteaseQrLoginAdapter,
        qqmusic: qqmusicQrLoginAdapter,
        kugou: kugouQrLoginAdapter,
      }[source].create();
    case "loginCheck": {
      if (!request.key || request.key.length > 2048) throw new Error("登录二维码无效");
      return {
        netease: neteaseQrLoginAdapter,
        qqmusic: qqmusicQrLoginAdapter,
        kugou: kugouQrLoginAdapter,
      }[source].check(request.key);
    }
    case "loginStatus":
      return {
        netease: fetchLoginStatus,
        qqmusic: fetchQQMusicLoginStatus,
        kugou: fetchKugouLoginStatus,
      }[source]();
    case "pluginHost":
      return dispatchNativePluginRequest(request.method ?? "", request.args ?? []);
    case "home":
      return loadNativeHome(request.loggedIn === true);
    case "account":
      return loadNativeAccount();
    case "logout":
      await logoutNativeAccount();
      return true;
    case "album":
    case "artist":
      return loadNativeCollection(request.action, String(request.id ?? ""));
    case "search": {
      const query = request.query?.trim();
      if (!query || query.length > 200) throw new Error("请输入 1–200 字的搜索内容");
      return searchSongs(source, query, Math.max(0, request.offset ?? 0), 30);
    }
    case "playlist": {
      const tracks: Track[] = [];
      let meta: unknown;
      await fetchPlaylist(String(request.id), {
        onMeta: (value) => {
          meta = value;
        },
        onBatch: (batch) => tracks.push(...batch),
      });
      return { meta, tracks };
    }
    case "detail":
      return songsByIds([String(request.id)]);
    case "daily":
      return fetchDailySongs();
    case "fm": {
      await requireNeteaseUser("登录后才能使用私人 FM");
      const mode = FM_MODES.find((value) => value === request.mode) ?? "DEFAULT";
      const submode =
        mode === "SCENE_RCMD" && request.submode && FM_SUBMODES.has(request.submode)
          ? (request.submode as PersonalFmSubMode)
          : undefined;
      if (mode === "SCENE_RCMD" && !submode) throw new Error("请选择场景");
      return fetchPersonalFm({ mode, submode });
    }
    case "fmTrash": {
      const time = Math.max(0, Math.round(request.time ?? 0));
      await submitFmTrash(neteaseId(request.id), time);
      return true;
    }
    case "heart": {
      const uid = await requireNeteaseUser("登录后才能使用心动模式");
      const playlistId = (await fetchUserPlaylists(uid, 1))[0]?.id;
      let seed = request.id ? neteaseId(request.id) : undefined;
      if (!seed) {
        const liked = await fetchLikelist(uid);
        seed = liked[Math.floor(Math.random() * liked.length)];
      }
      if (!playlistId || !seed) throw new Error("暂无可用的心动种子歌曲");
      const tracks = await fetchHeartModeList(seed, String(playlistId));
      if (!tracks.length) throw new Error("心动模式开启失败，请稍后重试");
      return tracks;
    }
    case "like": {
      const uid = await requireNeteaseUser("请先登录网易云账号");
      await toggleLikeSong(neteaseId(request.id), request.like === true, uid);
      return true;
    }
    case "likelist": {
      const profile = await fetchLoginStatus();
      return profile ? fetchLikelist(profile.userId) : [];
    }
    case "recognize": {
      const duration = request.duration ?? 0;
      if (!request.fingerprint || !(duration > 0 && duration <= 30)) {
        throw new Error("无效的听歌识曲参数");
      }
      return matchFingerprint(request.fingerprint, duration);
    }
    case "parseLyrics":
      if (typeof request.content !== "string") throw new Error("歌词内容无效");
      return parseNativeLyrics({ content: request.content });
    case "lyrics":
      return loadNativeLyrics(request.track);
    case "lyricExport":
      if (!request.track) throw new Error("请选择歌曲");
      return exportNativeLyrics(request.track, request.format === "lrc" ? "lrc" : "enhanced-lrc");
    case "resolve":
      if (!request.track) throw new Error("请选择歌曲");
      return resolve({
        action: "resolve",
        source,
        scope: "online",
        library: [],
        track: request.track,
        allowTrial: false,
        quality: request.quality ?? "hq",
      });
  }
};
