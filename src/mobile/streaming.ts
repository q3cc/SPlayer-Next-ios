import { parseStreamingSource } from "@shared/utils/streamingSource";
import { streamPages } from "@main/services/streaming/pagination";
import { StreamingPlaybackSession } from "@main/services/streaming/playbackSession";
import type { StreamingFavoriteChange, StreamingSyncState } from "@shared/types/streaming";
import {
  resolveStreamingAdapter,
  invalidateStreamingSession,
} from "@main/services/streaming/adapters/resolve";
import type { StreamingAdapter } from "@main/services/streaming/adapters/types";
import type { Album, Artist, Playlist, Track } from "@shared/types/player";
import type {
  StreamingApi,
  StreamingLibrarySnapshot,
  StreamingRuntimeConfig,
  StreamingServerConfig,
  StreamingServerInput,
} from "@shared/types/streaming";

const CONFIG_KEY = "splayer.mobile.streaming.servers";
const ACTIVE_KEY = "splayer.mobile.streaming.active";
const snapshots = new Map<string, StreamingLibrarySnapshot>();
const listeners = new Set<(serverId: string) => void>();
const favoriteListeners = new Set<(change: StreamingFavoriteChange) => void>();
const syncListeners = new Set<(state: StreamingSyncState) => void>();
const syncs = new Map<string, { controller: AbortController; favorites: Map<string, boolean> }>();
/** 用服务器返回值更新快照，并保护正在同步的分页 */
const applyFavorite = (serverId: string, trackId: string, favorite: boolean): boolean => {
  const snapshot = snapshots.get(serverId);
  if (snapshot)
    snapshot.songs = snapshot.songs.map((track) =>
      track.originalId === trackId ? { ...track, favorite } : track,
    );
  syncs.get(serverId)?.favorites.set(trackId, favorite);
  for (const listener of favoriteListeners) listener({ serverId, trackId, favorite });
  return favorite;
};

const emptySnapshot = (): StreamingLibrarySnapshot => ({
  songs: [],
  albums: [],
  artists: [],
  playlists: [],
});

const readServers = (): StreamingRuntimeConfig[] => {
  try {
    return JSON.parse(localStorage.getItem(CONFIG_KEY) ?? "[]") as StreamingRuntimeConfig[];
  } catch {
    return [];
  }
};

let servers = readServers();
const persist = (): void => localStorage.setItem(CONFIG_KEY, JSON.stringify(servers));
const publicConfig = ({
  password,
  accessToken: _token,
  userId: _user,
  ...server
}: StreamingRuntimeConfig): StreamingServerConfig => ({
  ...server,
  hasPassword: Boolean(password),
});
const requireServer = (id: string): StreamingRuntimeConfig => {
  const server = servers.find((item) => item.id === id);
  if (!server) throw new Error(`streaming server not found: ${id}`);
  return server;
};

const resolved = (id: string) => resolveStreamingAdapter(requireServer(id));

const cover = async (
  value: string | undefined,
  config: StreamingRuntimeConfig,
  adapter: StreamingAdapter,
): Promise<string | undefined> => {
  if (!value?.startsWith("streaming-cover://")) return value;
  const url = new URL(value);
  const coverId = url.searchParams.get("coverId");
  if (!coverId) return undefined;
  return adapter.getCoverUrl(config, coverId, Number(url.searchParams.get("size")) || 500);
};

const hydrateTrack = async (
  track: Track,
  config: StreamingRuntimeConfig,
  adapter: StreamingAdapter,
): Promise<Track> => ({
  ...track,
  serverRevision: config.mediaRevision ?? 0,
  cover: await cover(track.cover, config, adapter),
  coverOriginal: await cover(track.coverOriginal, config, adapter),
});
const hydrateAlbum = async (
  album: Album,
  config: StreamingRuntimeConfig,
  adapter: StreamingAdapter,
): Promise<Album> => ({
  ...album,
  cover: await cover(album.cover, config, adapter),
});
const hydrateArtist = async (
  artist: Artist,
  config: StreamingRuntimeConfig,
  adapter: StreamingAdapter,
): Promise<Artist> => ({
  ...artist,
  avatar: await cover(artist.avatar, config, adapter),
});
const hydratePlaylist = async (
  playlist: Playlist,
  config: StreamingRuntimeConfig,
  adapter: StreamingAdapter,
): Promise<Playlist> => ({
  ...playlist,
  cover: await cover(playlist.cover, config, adapter),
});

const createServer = (
  input: StreamingServerInput,
  id: string = crypto.randomUUID(),
): StreamingRuntimeConfig => ({
  id,
  ...input,
  url: input.url.replace(/\/+$/, ""),
  hasPassword: Boolean(input.password),
});

export const mobileStreaming: StreamingApi = {
  loadServers: async () => ({
    servers: servers.map(publicConfig),
    activeServerId: localStorage.getItem(ACTIVE_KEY),
  }),
  addServer: async (input) => {
    if (servers.length >= 16) throw new Error("最多保存 16 个流媒体服务器");
    const server = createServer(input);
    servers.push(server);
    persist();
    return publicConfig(server);
  },
  updateServer: async (id, input) => {
    const index = servers.findIndex((server) => server.id === id);
    if (index < 0) throw new Error(`streaming server not found: ${id}`);
    const previous = servers[index];
    const password = input.password || previous.password;
    const next = createServer({ ...input, password }, id);
    const identityChanged = ["url", "type", "username", "password"].some(
      (key) =>
        previous[key as keyof StreamingRuntimeConfig] !== next[key as keyof StreamingRuntimeConfig],
    );
    next.revision = (previous.revision ?? 0) + 1;
    next.mediaRevision = (previous.mediaRevision ?? 0) + Number(identityChanged);
    servers[index] = next;
    if (identityChanged) {
      syncs.get(id)?.controller.abort();
      invalidateStreamingSession(id);
      snapshots.delete(id);
    }
    persist();
    return publicConfig(servers[index]);
  },
  removeServer: async (id) => {
    syncs.get(id)?.controller.abort();
    servers = servers.filter((server) => server.id !== id);
    snapshots.delete(id);
    invalidateStreamingSession(id);
    if (localStorage.getItem(ACTIVE_KEY) === id) localStorage.removeItem(ACTIVE_KEY);
    persist();
  },
  setActiveServer: async (id) => {
    if (id) localStorage.setItem(ACTIVE_KEY, id);
    else localStorage.removeItem(ACTIVE_KEY);
  },
  testConnection: async (input, id) => {
    const config = createServer(input, id ?? "test");
    try {
      const { config: authenticated, adapter } = await resolveStreamingAdapter(config);
      return adapter.ping(authenticated);
    } catch (error) {
      return {
        ok: false,
        code: "network",
        error: error instanceof Error ? error.message : String(error),
      };
    }
  },
  connect: async (id) => {
    try {
      const { config, adapter } = await resolved(id);
      const ping = await adapter.ping(config);
      if (!ping.ok)
        return {
          ok: false,
          code: ping.code ?? "network",
          error: ping.error ?? "connection failed",
        };
      const server = requireServer(id);
      server.lastConnected = Date.now();
      persist();
      return { ok: true, server: publicConfig(server) };
    } catch (error) {
      return {
        ok: false,
        code: "auth",
        error: error instanceof Error ? error.message : String(error),
      };
    }
  },
  disconnect: async (id) => invalidateStreamingSession(id),
  getSnapshot: async (id) => snapshots.get(id) ?? emptySnapshot(),
  sync: async (id) => {
    if (syncs.has(id)) return false;
    const identity = requireServer(id).mediaRevision ?? 0;
    const task = { controller: new AbortController(), favorites: new Map<string, boolean>() };
    syncs.set(id, task);
    const publish = (state: StreamingSyncState["state"], error?: string): void => {
      for (const listener of syncListeners) listener({ serverId: id, state, error });
    };
    publish("running");
    try {
      const resolvedServer = await resolved(id);
      const config = { ...resolvedServer.config, signal: task.controller.signal };
      const adapter = resolvedServer.adapter;
      const songs: Track[] = [];
      const albums: Album[] = [];
      const songPages =
        adapter.scanSongs?.(config) ??
        streamPages(
          (params) => adapter.listSongs(config, params),
          (track) => track.id,
          config.signal,
        );
      for await (const page of songPages)
        songs.push(...(await Promise.all(page.map((item) => hydrateTrack(item, config, adapter)))));
      for await (const page of streamPages(
        (params) => adapter.listAlbums(config, params),
        (album) => album.id,
        config.signal,
      ))
        albums.push(
          ...(await Promise.all(page.map((item) => hydrateAlbum(item, config, adapter)))),
        );
      const [artists, playlists] = await Promise.all([
        adapter.listArtists(config),
        adapter.listPlaylists(config),
      ]);
      const snapshot = {
        songs,
        albums,
        artists: await Promise.all(artists.map((item) => hydrateArtist(item, config, adapter))),
        playlists: await Promise.all(
          playlists.map((item) => hydratePlaylist(item, config, adapter)),
        ),
      };
      config.signal.throwIfAborted();
      if ((requireServer(id).mediaRevision ?? 0) !== identity) throw new Error("服务器身份已变更");
      snapshot.songs = songs.map((track) =>
        task.favorites.has(track.originalId!)
          ? { ...track, favorite: task.favorites.get(track.originalId!) }
          : track,
      );
      snapshots.set(id, snapshot);
      listeners.forEach((listener) => listener(id));
      publish("completed");
      return true;
    } catch (error) {
      publish(task.controller.signal.aborted ? "cancelled" : "failed", String(error));
      throw error;
    } finally {
      syncs.delete(id);
    }
  },
  onSyncState: (callback) => {
    syncListeners.add(callback);
    return () => {
      syncListeners.delete(callback);
    };
  },
  onFavoriteChanged: (callback) => {
    favoriteListeners.add(callback);
    return () => {
      favoriteListeners.delete(callback);
    };
  },
  getFavorite: async (id, trackId) => {
    const { config, adapter } = await resolved(id);
    const favorite = await adapter.getFavorite(config, trackId);
    if ((requireServer(id).mediaRevision ?? 0) !== (config.mediaRevision ?? 0))
      throw new Error("服务器身份已变更");
    return applyFavorite(id, trackId, favorite);
  },
  setFavorite: async (id, trackId, favorite) => {
    const { config, adapter } = await resolved(id);
    const confirmed = await adapter.setFavorite(config, trackId, favorite);
    if ((requireServer(id).mediaRevision ?? 0) !== (config.mediaRevision ?? 0))
      throw new Error("服务器身份已变更");
    return applyFavorite(id, trackId, confirmed);
  },
  onLibraryUpdated: (callback) => {
    listeners.add(callback);
    return () => listeners.delete(callback);
  },
  search: async (id, query) => {
    const value = query.trim().toLocaleLowerCase();
    const snapshot = snapshots.get(id) ?? emptySnapshot();
    return {
      songs: snapshot.songs.filter((song) =>
        [song.title, song.album?.name, ...song.artists.map((artist) => artist.name)].some((item) =>
          item?.toLocaleLowerCase().includes(value),
        ),
      ),
      albums: snapshot.albums.filter((album) => album.name.toLocaleLowerCase().includes(value)),
      artists: snapshot.artists.filter((artist) => artist.name.toLocaleLowerCase().includes(value)),
    };
  },
  getAlbumSongs: async (id, albumId) => {
    const { config, adapter } = await resolved(id);
    const items = await adapter.getAlbumSongs(config, albumId);
    return Promise.all(items.map((item) => hydrateTrack(item, config, adapter)));
  },
  getPlaylistSongs: async (id, playlistId) => {
    const { config, adapter } = await resolved(id);
    const items = await adapter.getPlaylistSongs(config, playlistId);
    return Promise.all(items.map((item) => hydrateTrack(item, config, adapter)));
  },
  getArtistAlbums: async (id, artistId) => {
    const { config, adapter } = await resolved(id);
    const items = await adapter.getArtistAlbums(config, artistId);
    return Promise.all(items.map((item) => hydrateAlbum(item, config, adapter)));
  },
  getArtistSongs: async (id, artistId) => {
    const { config, adapter } = await resolved(id);
    const items = await adapter.getArtistSongs(config, artistId);
    return Promise.all(items.map((item) => hydrateTrack(item, config, adapter)));
  },
  getLyrics: async (id, trackId, hint) => {
    const { config, adapter } = await resolved(id);
    return adapter.getLyrics(config, trackId, hint);
  },
};

/** 为缓存或下载解析原文件地址，不建立播放上报会话 */
export const resolveMobileStreamingDownload = async (source: string): Promise<string> => {
  const { serverId, trackId, serverRevision } = parseStreamingSource(source);
  const { config, adapter } = await resolved(serverId);
  if ((config.mediaRevision ?? 0) !== serverRevision) throw new Error("流媒体歌曲属于旧服务器身份");
  return adapter.getDownloadUrl(config, trackId);
};

/** 为一次原生加载创建独立会话，离线文件不等待认证，只有实际播放才上报 */
export const prepareMobileStreamingPlayback = async (
  source: string,
  durationMs: number,
  localSource?: string,
) => {
  const { serverId, trackId, serverRevision } = parseStreamingSource(source);
  const server = requireServer(serverId);
  if ((server.mediaRevision ?? 0) !== serverRevision) throw new Error("流媒体歌曲属于旧服务器身份");
  const sessionId = crypto.randomUUID();
  const remote = localSource ? undefined : await resolved(serverId);
  const prepared = remote
    ? await remote.adapter.preparePlayback(remote.config, trackId, sessionId)
    : { url: localSource!, mediaSourceId: undefined };
  let mediaSourceId = prepared.mediaSourceId;
  let started = false;
  const session = new StreamingPlaybackSession(
    { trackId, sessionId, durationMs, mediaSourceId },
    async (event) => {
      try {
        if ((requireServer(serverId).mediaRevision ?? 0) !== serverRevision) return;
        if (event.event !== "start" && !started) return;
        const { config, adapter } = remote ?? (await resolved(serverId));
        if (
          event.event === "start" &&
          !mediaSourceId &&
          (config.type === "jellyfin" || config.type === "emby")
        ) {
          mediaSourceId = (await adapter.preparePlayback(config, trackId, sessionId)).mediaSourceId;
        }
        if ((requireServer(serverId).mediaRevision ?? 0) !== serverRevision) return;
        await adapter.reportPlayback(config, { ...event, mediaSourceId });
        if (event.event === "start") started = true;
      } catch (error) {
        console.warn("[streaming] 播放会话上报失败", error);
      }
    },
  );
  return { source: prepared.url, session };
};
