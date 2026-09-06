import { addPluginListener, invoke } from "@tauri-apps/api/core";
import type {
  IpcResponse,
  LoadResult,
  PlayerApi,
  PlayerEvent,
  PlayerStatus,
} from "@shared/types/player";
import { mobileMediaSession } from "./mediaSession";
import { mobileLyricPip } from "./lyricPip";

/** iOS 使用原生流式引擎，浏览器预览保留原播放器。 */
export const createNativePlayer = (fallback: PlayerApi): PlayerApi => {
  const listeners = new Set<(event: PlayerEvent) => void>();
  let status: PlayerStatus = {
    state: "idle",
    position: 0,
    duration: 0,
    volume: 1,
    speed: 1,
    isFinished: false,
  };
  let generation = 0;
  let cover: string | null = null;
  let configuring: Promise<IpcResponse> = Promise.resolve({ success: true });
  let effects = {
    volume: 1,
    speed: 1,
    pitch: 0,
    pitchSync: true,
    enabled: false,
    bands: Array(10).fill(0) as number[],
    preamp: 0,
  };
  let ready: Promise<void> | undefined;

  const emit = (event: PlayerEvent): void => {
    for (const listener of listeners) listener(event);
  };
  const update = (value: PlayerStatus, positionOnly = false): void => {
    status = value;
    mobileMediaSession.setPosition(value.position);
    mobileLyricPip.sync(value);
    emit(
      positionOnly
        ? { type: "position", data: { position: value.position, duration: value.duration } }
        : { type: "status", data: value },
    );
  };
  const initialize = (): Promise<void> => {
    ready ??= (async () => {
      const subscriptions: Awaited<ReturnType<typeof addPluginListener>>[] = [];
      try {
        subscriptions.push(
          await addPluginListener<PlayerStatus>("native-audio", "position", (value) =>
            update(value, true),
          ),
        );
        subscriptions.push(
          await addPluginListener<PlayerStatus>("native-audio", "state", (value) => update(value)),
        );
        subscriptions.push(
          await addPluginListener("native-audio", "ended", () => emit({ type: "ended" })),
        );
        subscriptions.push(
          await addPluginListener<{ message: string }>("native-audio", "error", (value) => {
            console.warn("[native-audio] 播放失败", value.message);
            emit({ type: "sourceError" });
          }),
        );
        subscriptions.push(
          await addPluginListener<{ type: "next" | "prev" }>("native-audio", "action", (value) =>
            emit({ type: value.type }),
          ),
        );
        await invoke("plugin:native-audio|visibility", { visible: !document.hidden });
      } catch (error) {
        await Promise.all(subscriptions.map((subscription) => subscription.unregister()));
        ready = undefined;
        throw error;
      }
    })();
    return ready;
  };

  document.addEventListener("visibilitychange", () => {
    if (!ready) return;
    void ready
      .then(async () => {
        await invoke("plugin:native-audio|visibility", { visible: !document.hidden });
        if (!document.hidden) update(await invoke<PlayerStatus>("plugin:native-audio|status"));
      })
      .catch((error) => console.warn("[native-audio] 前后台同步失败", error));
  });

  /** 所有音效参数统一下发，避免调频段时覆盖其他设置。 */
  const configure = (patch: Partial<typeof effects>): Promise<IpcResponse> => {
    configuring = configuring.then(async () => {
      const next = { ...effects, ...patch };
      try {
        await invoke("plugin:native-audio|configure", next);
        effects = next;
        return { success: true };
      } catch (error) {
        return { success: false, error: String(error) };
      }
    });
    return configuring;
  };
  const control = async (action: string, position?: number): Promise<IpcResponse> => {
    try {
      await initialize();
      update(
        await invoke<PlayerStatus>("plugin:native-audio|control", {
          action,
          position: position ?? null,
        }),
      );
      return { success: true };
    } catch (error) {
      return { success: false, error: String(error) };
    }
  };

  return {
    ...fallback,
    load: async (source, options = {}): Promise<IpcResponse<LoadResult>> => {
      const current = ++generation;
      try {
        await initialize();
        await invoke("plugin:native-audio|siri", {
          request: JSON.stringify({ action: "interrupt" }),
        });
        const value = await invoke<PlayerStatus>("plugin:native-audio|load", {
          source,
          autoPlay: options.autoPlay !== false,
        });
        if (current !== generation) return { success: false, error: "已切换歌曲" };
        cover = options.meta?.coverOriginal ?? options.meta?.cover ?? null;
        mobileMediaSession.setTrack(options.meta ?? null);
        update(value);
        const quality = options.meta?.quality ?? {
          sampleRate: 0,
          channels: 2,
          bitsPerSample: 0,
          bitRate: 0,
          codec: "Audio",
        };
        return {
          success: true,
          data: {
            detail: { quality, externalLyrics: [] },
            mediaInfo: {
              title: options.meta?.title,
              artists: options.meta?.artists,
              album: options.meta?.album,
              cover: options.meta?.cover,
              duration: value.duration || options.meta?.duration || 0,
              quality,
            },
          },
        };
      } catch (error) {
        if (current === generation) {
          status = { ...status, state: "idle" };
          mobileMediaSession.setTrack(null);
        }
        return { success: false, error: String(error) };
      }
    },
    play: () => control("play"),
    pause: () => control("pause"),
    stop: () => {
      generation++;
      return control("stop");
    },
    seek: (position) => control("seek", position),
    getStatus: async () => {
      try {
        return { success: true, data: await invoke<PlayerStatus>("plugin:native-audio|status") };
      } catch (error) {
        return { success: false, error: String(error) };
      }
    },
    getVolume: async () => ({ success: true, data: effects.volume }),
    getCoverRaw: async () => ({ success: true, data: cover }),
    setVolume: (volume) => configure({ volume }),
    setSpeed: (speed) => configure({ speed }),
    setPitch: (pitch) => configure({ pitch }),
    setPitchSync: (pitchSync) => configure({ pitchSync }),
    setEqualizerEnabled: (enabled) => configure({ enabled }),
    setEqualizerBands: (bands) => configure({ bands: [...bands] }),
    setPreampGain: (preamp) => configure({ preamp }),
    dispatch: (type) => emit({ type } as PlayerEvent),
    onEvent: (callback) => {
      listeners.add(callback);
      void initialize().catch((error) => console.warn("[native-audio] 初始化失败", error));
      return () => listeners.delete(callback);
    },
  };
};
