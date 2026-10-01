import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { LastfmApi } from "@shared/types/lastfm";
import type { Track, PlayerEvent } from "@shared/types/player";
import { store } from "./shims/store";
import * as scrobbler from "@main/services/lastfm/scrobbler";

interface Session {
  username: string;
  sessionKey: string;
}
let session: Session | null = null;
let trackGeneration = 0;
let loading: Promise<void> | undefined;
let authorization: AbortController | undefined;
const client = () => import("@main/services/lastfm/client");
const config = () => store.get("lastfm");
const credentials = (action: string, value?: Session) =>
  invoke<{ value: string | null }>("plugin:native-audio|lastfm_credentials", {
    action,
    value: value ? JSON.stringify(value) : null,
  });
const initialize = (): Promise<void> =>
  (loading ??= credentials("get")
    .then(({ value }) => {
      session = value ? (JSON.parse(value) as Session) : null;
    })
    .catch((error) => {
      loading = undefined;
      throw error;
    }));

scrobbler.setHandlers({
  onNowPlaying: (track) => {
    if (!config().enabled || !config().nowPlaying || !session) return;
    const key = session.sessionKey;
    void client()
      .then((api) =>
        api.updateNowPlaying(key, track.title, track.artist, track.album, track.durationSec),
      )
      .catch(() => console.warn("[lastfm] 正在播放上报失败"));
  },
  onScrobble: (track) => {
    if (!config().enabled || !config().scrobble || !session) return;
    const key = session.sessionKey;
    void client()
      .then((api) =>
        api.scrobble(
          key,
          track.title,
          track.artist,
          track.timestamp,
          track.album,
          track.durationSec,
        ),
      )
      .catch(() => console.warn("[lastfm] 播放记录上报失败"));
  },
});

export const lastfmTrackLoaded = async (
  track: Track | undefined,
  duration: number,
  autoPlay: boolean,
): Promise<void> => {
  const current = ++trackGeneration;
  scrobbler.reset();
  if (!config().enabled || !track) return;
  try {
    await initialize();
  } catch {
    return;
  }
  if (current !== trackGeneration || !config().enabled) return;
  scrobbler.onTrackLoaded({
    title: track.title,
    artist: track.artists[0]?.name ?? "",
    album: track.album?.name ?? "",
    durationMs: duration,
    autoPlay,
  });
};
export const lastfmPlayerEvent = (event: PlayerEvent): void => {
  if (!config().enabled) {
    scrobbler.reset();
    return;
  }
  if (event.type === "status") scrobbler.onState(event.data.state === "playing");
  else if (event.type === "position") scrobbler.onPosition();
  else if (event.type === "ended") scrobbler.onEnded();
};

export const mobileLastfm: LastfmApi = {
  getStatus: async () => {
    await initialize();
    return { connected: Boolean(session), username: session?.username ?? "" };
  },
  connect: async () => {
    if (authorization) return { connected: false, reason: "error" };
    const controller = new AbortController();
    authorization = controller;
    const { signal } = controller;
    const timeout = setTimeout(() => controller.abort("timeout"), 120000);
    try {
      await initialize();
      const api = await client();
      const token = await api.getToken(signal);
      signal.throwIfAborted();
      await openUrl(api.getAuthUrl(token));
      const deadline = Date.now() + 120000;
      while (Date.now() < deadline) {
        await new Promise<void>((resolve) => {
          const finish = () => {
            clearTimeout(timer);
            signal.removeEventListener("abort", finish);
            resolve();
          };
          const timer = setTimeout(finish, 3000);
          signal.addEventListener("abort", finish, { once: true });
          if (signal.aborted) finish();
        });
        signal.throwIfAborted();
        let result;
        try {
          result = await api.getSession(token, signal);
        } catch (error) {
          if (String(error).includes("Last.fm 14")) continue;
          throw error;
        }
        signal.throwIfAborted();
        const next = { username: result.name, sessionKey: result.key };
        await credentials("set", next);
        if (signal.aborted) {
          await credentials("clear");
          signal.throwIfAborted();
        }
        session = next;
        return { connected: true, username: result.name };
      }
      return { connected: false, reason: "timeout" };
    } catch {
      return {
        connected: false,
        reason: signal.aborted ? (signal.reason === "timeout" ? "timeout" : "canceled") : "error",
      };
    } finally {
      clearTimeout(timeout);
      if (authorization === controller) authorization = undefined;
    }
  },
  cancelConnect: async () => {
    authorization?.abort();
  },
  disconnect: async () => {
    authorization?.abort();
    await initialize();
    await credentials("clear");
    session = null;
    scrobbler.reset();
  },
  love: async (artist, track, loved) => {
    if (!config().enabled || !config().loveSync || !artist || !track) return;
    await initialize();
    if (session) await (await client()).love(session.sessionKey, track, artist, loved);
  },
};
