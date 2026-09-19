import type { KGSong } from "@main/apis/kugou/core/types";
import { pickBestCandidate, type LyricCandidate } from "@main/apis/common/lyric/utils";
import {
  normalizeKugouCommentPage,
  normalizeNeteaseCommentPage,
  normalizeQQMusicCommentPage,
  type KugouCommentBody,
  type QQMusicCommentBody,
} from "@main/services/comments/data";
import type { CommentSource, MusicCommentPage, MusicCommentQuery } from "@shared/types/comment";
import type { Track } from "@shared/types/player";

const EMPTY = (query: MusicCommentQuery): MusicCommentPage => ({
  list: [],
  total: 0,
  page: query.page,
  limit: query.limit,
});

const parsePluginSource = (sourceId: string): { pluginId: string; source: string } | null => {
  if (!sourceId.startsWith("plugin:")) return null;
  const rest = sourceId.slice("plugin:".length);
  const separator = rest.indexOf(":");
  if (separator <= 0) return null;
  return { pluginId: rest.slice(0, separator), source: rest.slice(separator + 1) };
};

const callNetease = async (name: string, params: Record<string, unknown>) =>
  (await import("@main/apis/netease")).callNetease(name, params);
const callQQMusic = async (name: string, params: Record<string, unknown>) =>
  (await import("@main/apis/qqmusic")).callQQMusic(name, params);
const callKugou = async <T>(name: string, params: Record<string, unknown>) =>
  (await import("@main/apis/kugou")).callKugou<T>(name, params);

const keywordFor = (track: Track): string =>
  `${track.title} ${track.artists.map((artist) => artist.name).join(" ")}`.trim();

const findNeteaseId = async (track: Track): Promise<string | null> => {
  if (track.source === "netease" && track.id) return track.id;
  const { body } = await callNetease("search", {
    keywords: keywordFor(track),
    type: 1,
    limit: 20,
  });
  const candidates: LyricCandidate<{ id: string }>[] = (body.result?.songs ?? []).map(
    (song: {
      id: string | number;
      name?: string;
      artists?: { name: string }[];
      album?: { name?: string };
      duration?: number;
    }) => ({
      name: song.name ?? "",
      artist: (song.artists ?? []).map((artist) => artist.name).join(" / "),
      album: song.album?.name,
      duration: song.duration,
      extra: { id: String(song.id) },
    }),
  );
  return pickBestCandidate(candidates, track)?.extra.id ?? null;
};

const findQQMusicId = async (track: Track): Promise<string | null> => {
  if (track.source === "qqmusic") return track.extId || (/^\d+$/.test(track.id) ? track.id : null);
  const body = await callQQMusic("search", {
    keywords: keywordFor(track),
    type: 0,
    page: 1,
    limit: 20,
  });
  const candidates: LyricCandidate<{ id: string }>[] = (body.songs ?? []).map(
    (song: { id?: string; name?: string; artist?: string; album?: string; duration?: number }) => ({
      name: song.name ?? "",
      artist: song.artist ?? "",
      album: song.album,
      duration: song.duration,
      extra: { id: song.id ?? "" },
    }),
  );
  return pickBestCandidate(candidates, track)?.extra.id || null;
};

const findKugouId = async (track: Track): Promise<string | null> => {
  if (track.source === "kugou" && track.extId) return track.extId;
  const body = await callKugou<{ songs?: KGSong[] }>("search", {
    keywords: keywordFor(track),
    type: 0,
    page: 1,
    limit: 20,
  });
  const candidates: LyricCandidate<{ id: string }>[] = (body.songs ?? []).map((song) => ({
    name: song.name,
    artist: song.artist,
    album: song.album,
    duration: song.duration,
    extra: { id: song.albumAudioId ? String(song.albumAudioId) : "" },
  }));
  return pickBestCandidate(candidates, track)?.extra.id || null;
};

const get = async (
  raw: MusicCommentQuery,
): Promise<{ ok: true; data: MusicCommentPage } | { ok: false; error: string }> => {
  const query = {
    ...raw,
    page: Math.max(1, Math.floor(Number(raw.page) || 1)),
    limit: Math.min(50, Math.max(1, Math.floor(Number(raw.limit) || 20))),
  };
  try {
    if (query.sourceId === "builtin:netease") {
      const id = await findNeteaseId(query.track);
      if (!id) return { ok: true, data: EMPTY(query) };
      const { body } = await callNetease(query.type === "hot" ? "comment_hot" : "comment_music", {
        id,
        type: "R_SO_4_",
        limit: query.limit,
        offset: (query.page - 1) * query.limit,
      });
      return {
        ok: true,
        data: normalizeNeteaseCommentPage(body, query.type, query.page, query.limit),
      };
    }
    if (query.sourceId === "builtin:qqmusic") {
      const id = await findQQMusicId(query.track);
      if (!id) return { ok: true, data: EMPTY(query) };
      const body = await callQQMusic("comment", {
        id,
        type: query.type,
        page: query.page,
        limit: query.limit,
        cursor: query.cursor,
      });
      return {
        ok: true,
        data: normalizeQQMusicCommentPage(body as QQMusicCommentBody, query.page, query.limit),
      };
    }
    if (query.sourceId === "builtin:kugou") {
      if (query.type !== "hot") return { ok: true, data: EMPTY(query) };
      const id = await findKugouId(query.track);
      if (!id) return { ok: true, data: EMPTY(query) };
      const body = await callKugou<KugouCommentBody>("comment", {
        id,
        page: query.page,
        limit: query.limit,
      });
      return {
        ok: true,
        data: normalizeKugouCommentPage(body, query.page, query.limit),
      };
    }
    const plugin = parsePluginSource(query.sourceId);
    if (plugin) {
      const { mobilePlugins } = await import("./plugins");
      const result = await mobilePlugins.matchComment({
        ...plugin,
        track: query.track,
        type: query.type,
        page: query.page,
        limit: query.limit,
        cursor: query.cursor,
      });
      if (!result.ok) return { ok: false, error: result.error ?? "插件评论请求失败" };
      return { ok: true, data: result.data ?? EMPTY(query) };
    }
    return { ok: false, error: `unknown comment source: ${query.sourceId}` };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
};

const builtinSources: CommentSource[] = [
  { id: "builtin:netease", name: "网易云", kind: "builtin", platform: "netease" },
  { id: "builtin:qqmusic", name: "QQ音乐", kind: "builtin", platform: "qqmusic" },
  { id: "builtin:kugou", name: "酷狗", kind: "builtin", platform: "kugou", tabs: ["hot"] },
];

export const mobileComments = {
  sources: async (): Promise<CommentSource[]> => {
    const { mobilePlugins } = await import("./plugins");
    const plugins = await mobilePlugins.list();
    const sources = [...builtinSources];
    for (const info of plugins) {
      if (!info.enabled || info.status.state !== "ready") continue;
      for (const [source, capability] of Object.entries(info.status.sources)) {
        if (
          !capability.actions.includes("musicSearch") ||
          !capability.actions.includes("musicComment")
        )
          continue;
        sources.push({
          id: `plugin:${info.manifest.id}:${source}`,
          name: capability.name,
          kind: "plugin",
          pluginId: info.manifest.id,
          pluginSource: source,
        });
      }
    }
    return sources;
  },
  get,
};
