import "./textEncoding";
import { loadNativeLyrics } from "./lyrics";
import { mobileProviders } from "../providers";
import { fetchUserCloud } from "@/apis/cloud/netease";
import { searchSongs } from "@/apis/search";
import {
  fetchRecommendPlaylists,
  fetchDailySongs,
  fetchPersonalFm,
} from "@/apis/recommend/netease";
import { fetchPlaylist } from "@/apis/playlist/netease";
import { songsByIds } from "@/apis/song/netease";
import { run as resolve } from "../siri/background";
import { neteaseQrLoginAdapter, fetchLoginStatus } from "@/apis/login/netease";
import { qqmusicQrLoginAdapter, fetchQQMusicLoginStatus } from "@/apis/login/qqmusic";
import { kugouQrLoginAdapter, fetchKugouLoginStatus } from "@/apis/login/kugou";
import { dispatchNativePluginRequest } from "./pluginHost";
import type { Track } from "@shared/types/player";
import type { Platform } from "@shared/types/platform";

interface NativeRequest {
  action:
    | "cloud"
    | "loginCreate"
    | "loginCheck"
    | "loginStatus"
    | "pluginHost"
    | "search"
    | "home"
    | "playlist"
    | "resolve"
    | "lyrics"
    | "detail"
    | "daily"
    | "fm";
  key?: string;
  method?: string;
  args?: unknown[];
  source?: Platform;
  query?: string;
  offset?: number;
  id?: string;
  track?: Track;
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
      return fetchRecommendPlaylists(false);
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
    case "fm":
      return fetchPersonalFm();
    case "lyrics":
      return loadNativeLyrics(request.track);
    case "resolve":
      if (!request.track) throw new Error("请选择歌曲");
      return resolve({
        action: "resolve",
        source,
        scope: "online",
        library: [],
        track: request.track,
        allowTrial: false,
        quality: "hq",
      });
  }
};
