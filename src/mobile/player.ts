import type {
  AudioDevice,
  FftData,
  IpcResponse,
  LoadOptions,
  LoadResult,
  PlayerApi,
  PlayerEvent,
  PlayerState,
  PlayerStatus,
} from "@shared/types/player";
import { resolveMobileAudioSource } from "./library";
import { mobileMediaSession } from "./mediaSession";
import { mobileLyricPip } from "./lyricPip";
import { isTauri } from "@tauri-apps/api/core";
import { createNativePlayer } from "./nativePlayer";
import { open } from "@tauri-apps/plugin-dialog";
import type { LyricFormat } from "@shared/types/lyrics";

type PlayerListener = (event: PlayerEvent) => void;

const listeners = new Set<PlayerListener>();
const audio = new Audio();
audio.preload = "auto";
audio.setAttribute("playsinline", "true");

let currentMeta: LoadOptions["meta"];
let state: PlayerState = "idle";
let fadeDuration = 0;
let pitch = 0;
let lastSystemPositionAt = -Infinity;

const emit = (event: PlayerEvent): void => {
  mobileLyricPip.sync(status());
  for (const listener of listeners) listener(event);
};

const durationMs = (): number => (Number.isFinite(audio.duration) ? audio.duration * 1000 : 0);
const positionMs = (): number =>
  Number.isFinite(audio.currentTime) ? audio.currentTime * 1000 : 0;

const status = (): PlayerStatus => ({
  state,
  position: positionMs(),
  duration: durationMs(),
  volume: audio.volume,
  speed: audio.playbackRate,
  isFinished: audio.ended,
});

audio.addEventListener("play", () => {
  state = "playing";
  emit({ type: "status", data: status() });
});
audio.addEventListener("pause", () => {
  if (!audio.ended) state = "paused";
  emit({ type: "status", data: status() });
});
audio.addEventListener("timeupdate", () => {
  mobileMediaSession.setPosition(positionMs());
  emit({ type: "position", data: { position: positionMs(), duration: durationMs() } });
  if (
    "mediaSession" in navigator &&
    durationMs() > 0 &&
    performance.now() - lastSystemPositionAt >= 1000
  ) {
    lastSystemPositionAt = performance.now();
    try {
      navigator.mediaSession.setPositionState({
        duration: audio.duration,
        playbackRate: audio.playbackRate,
        position: Math.min(audio.currentTime, audio.duration),
      });
    } catch {}
  }
});
audio.addEventListener("ended", () => {
  state = "stopped";
  emit({ type: "ended" });
});
audio.addEventListener("error", () => emit({ type: "sourceError" }));
audio.addEventListener("ratechange", () => mobileLyricPip.sync(status()));
audio.addEventListener("waiting", () => mobileLyricPip.sync({ ...status(), state: "paused" }));
audio.addEventListener("playing", () => mobileLyricPip.sync(status()));
audio.addEventListener("seeked", () => {
  lastSystemPositionAt = -Infinity;
  mobileLyricPip.sync(status(), true);
});
document.addEventListener("visibilitychange", () => {
  if (isTauri() || document.hidden) return;
  emit({ type: "status", data: status() });
  emit({ type: "position", data: { position: positionMs(), duration: durationMs() } });
});

const installMediaSession = (): void => {
  if (!("mediaSession" in navigator)) return;
  const action = (name: MediaSessionAction, handler: MediaSessionActionHandler | null): void => {
    try {
      navigator.mediaSession.setActionHandler(name, handler);
    } catch {}
  };
  action("play", () => emit({ type: "play" }));
  action("pause", () => emit({ type: "pause" }));
  action("previoustrack", () => emit({ type: "prev" }));
  action("nexttrack", () => emit({ type: "next" }));
  action("seekto", (details) => {
    if (details.seekTime == null) return;
    audio.currentTime = details.seekTime;
    emit({ type: "seek", data: { position: details.seekTime * 1000 } });
  });
  action("seekbackward", (details) => {
    audio.currentTime = Math.max(0, audio.currentTime - (details.seekOffset ?? 10));
  });
  action("seekforward", (details) => {
    audio.currentTime = Math.min(
      audio.duration || Infinity,
      audio.currentTime + (details.seekOffset ?? 10),
    );
  });
};

if (!isTauri()) installMediaSession();

const waitUntilReady = (): Promise<void> =>
  new Promise((resolve, reject) => {
    const timeout = window.setTimeout(() => finish(new Error("audio load timeout")), 20000);
    const finish = (error?: Error): void => {
      window.clearTimeout(timeout);
      audio.removeEventListener("loadedmetadata", ready);
      audio.removeEventListener("canplay", ready);
      audio.removeEventListener("error", failed);
      if (error) reject(error);
      else resolve();
    };
    const ready = (): void => finish();
    const failed = (): void => finish(new Error(`audio error ${audio.error?.code ?? "unknown"}`));
    audio.addEventListener("loadedmetadata", ready, { once: true });
    audio.addEventListener("canplay", ready, { once: true });
    audio.addEventListener("error", failed, { once: true });
  });

const load = async (
  source: string,
  options: LoadOptions = {},
): Promise<IpcResponse<LoadResult>> => {
  try {
    state = "loading";
    currentMeta = options.meta;
    mobileMediaSession.setTrack(currentMeta ?? null);
    audio.pause();
    audio.src = resolveMobileAudioSource(source);
    audio.load();
    await waitUntilReady();
    const metaDuration = currentMeta?.duration ?? 0;
    const duration = durationMs() || metaDuration;
    const codec = source.split("?")[0].split(".").pop()?.toUpperCase() ?? "Audio";
    const quality = currentMeta?.quality ?? {
      sampleRate: 0,
      channels: 2,
      bitsPerSample: 0,
      bitRate: 0,
      codec,
    };
    state = options.autoPlay === false ? "paused" : "playing";
    if (options.autoPlay !== false) await audio.play();
    return {
      success: true,
      data: {
        detail: { quality, externalLyrics: [] },
        mediaInfo: {
          title: currentMeta?.title,
          artists: currentMeta?.artists,
          album: currentMeta?.album,
          cover: currentMeta?.cover,
          duration,
          quality,
        },
      },
    };
  } catch (error) {
    state = "idle";
    mobileMediaSession.setTrack(null);
    return { success: false, error: error instanceof Error ? error.message : String(error) };
  }
};

const ok = (): IpcResponse => ({ success: true });
const device: AudioDevice = { id: "ios-default", name: "iPhone / iPad", isDefault: true };
const emptyFft = (): FftData => ({ ldata: Array(64).fill(0), rdata: Array(64).fill(0) });

const webPlayer: PlayerApi = {
  load,
  play: async () => {
    try {
      await audio.play();
      state = "playing";
      return ok();
    } catch (error) {
      return { success: false, error: error instanceof Error ? error.message : String(error) };
    }
  },
  pause: async () => {
    audio.pause();
    state = "paused";
    return ok();
  },
  stop: async () => {
    audio.pause();
    audio.currentTime = 0;
    state = "stopped";
    mobileMediaSession.setPosition(0);
    mobileLyricPip.sync(status());
    return ok();
  },
  seek: async (position) => {
    audio.currentTime = Math.max(0, position / 1000);
    mobileMediaSession.setPosition(positionMs());
    emit({ type: "position", data: { position, duration: durationMs() } });
    return ok();
  },
  setVolume: async (volume) => {
    audio.volume = Math.max(0, Math.min(1, volume));
    return ok();
  },
  setPauseOnDeviceSwitch: async () => ok(),
  getVolume: async () => ({ success: true, data: audio.volume }),
  getStatus: async () => ({ success: true, data: status() }),
  setFftEnabled: async () => ok(),
  getFftData: async () => ({ success: true, data: emptyFft() }),
  setFadeDuration: async (ms) => {
    fadeDuration = ms;
    return ok();
  },
  getFadeDuration: async () => ({ success: true, data: fadeDuration }),
  getCoverRaw: async () => ({
    success: true,
    data: currentMeta?.coverOriginal ?? currentMeta?.cover ?? null,
  }),
  readLyricFile: async (filePath) => {
    if (!isTauri()) return { success: false, error: "local lyric files are not available" };
    try {
      const { readTextFile } = await import("@tauri-apps/plugin-fs");
      return { success: true, data: await readTextFile(filePath) };
    } catch (error) {
      return { success: false, error: error instanceof Error ? error.message : String(error) };
    }
  },
  pickLyricFile: async () => {
    if (!isTauri()) return { success: false, error: "local lyric files are not available" };
    try {
      const selected = await open({
        multiple: false,
        directory: false,
        fileAccessMode: "scoped",
        filters: [
          { name: "Lyrics", extensions: ["ttml", "lys", "qrc", "krc", "yrc", "lrc", "ass", "srt"] },
        ],
      });
      if (!selected || Array.isArray(selected)) return { success: false, error: "canceled" };
      const path = String(selected);
      const ext = path.split(".").pop()?.toLowerCase() as LyricFormat | undefined;
      if (!ext || !["ttml", "lys", "qrc", "krc", "yrc", "lrc", "ass", "srt"].includes(ext)) {
        return { success: false, error: "不支持的歌词文件类型" };
      }
      return { success: true, data: { path, format: ext } };
    } catch (error) {
      return { success: false, error: error instanceof Error ? error.message : String(error) };
    }
  },
  reinit: async () => ok(),
  setNormalizationEnabled: async () => ok(),
  setEqualizerEnabled: async () => ok(),
  setEqualizerBands: async () => ok(),
  setPreampGain: async () => ok(),
  setSpeed: async (speed) => {
    audio.playbackRate = Math.max(0.5, Math.min(2, speed));
    return ok();
  },
  setPitch: async (value) => {
    pitch = value;
    void pitch;
    return ok();
  },
  setPitchSync: async (value) => {
    audio.preservesPitch = value;
    return ok();
  },
  getOutputDevices: async () => ({ success: true, data: [device] }),
  getDefaultDeviceName: async () => ({ success: true, data: device.id }),
  setOutputDevice: async () => ok(),
  getSelectedDeviceName: async () => ({ success: true, data: device.id }),
  syncPlayMode: () => undefined,
  syncLikeState: () => undefined,
  dispatch: (type) => emit({ type } as PlayerEvent),
  onEvent: (callback) => {
    listeners.add(callback);
    return () => listeners.delete(callback);
  },
};

export const mobilePlayer = isTauri() ? createNativePlayer(webPlayer) : webPlayer;
