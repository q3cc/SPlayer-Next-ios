import { convertFileSrc } from "@tauri-apps/api/core";
import { getCurrent, onOpenUrl } from "@tauri-apps/plugin-deep-link";
import { save, open } from "@tauri-apps/plugin-dialog";
import { readTextFile, writeFile } from "@tauri-apps/plugin-fs";
import { fetch as tauriFetch } from "@tauri-apps/plugin-http";
import { defaultHotkeyConfig } from "@shared/defaults/hotkeys";
import { mobileDownload } from "./download";
import type { HotkeyConfig } from "@shared/types/hotkey";
import type { NowPlayingSnapshot, NowPlayingUpdatePayload } from "@shared/types/nowPlaying";
import type { PlayerApi, PlayerEvent, Track } from "@shared/types/player";
import type { StreamingApi } from "@shared/types/streaming";
import { store } from "./shims/store";
import { setDiagnosticsEnabled } from "./diagnostics";
import { testNetworkProxy } from "./shims/proxy";
import { mobileLibrary } from "./library";
import { mobileComments } from "./comments";
import { mobileLyrics } from "./lyrics";
import { mobilePlaylist } from "./playlist";
import { mobileProviders } from "./providers";
import { mobileStats } from "./stats";
import { mobileMediaSession } from "./mediaSession";
import { mobileLyricPip } from "./lyricPip";
import { mobileUpdate } from "./update";

let playerPromise: Promise<PlayerApi> | undefined;
const playerEventListeners = new Set<(event: PlayerEvent) => void>();
let playerEventsInstalled = false;

const loadPlayer = async (): Promise<PlayerApi> => {
  playerPromise ??= import("./player").then(({ mobilePlayer }) => mobilePlayer);
  const player = await playerPromise;
  if (!playerEventsInstalled) {
    playerEventsInstalled = true;
    player.onEvent((event) => playerEventListeners.forEach((listener) => listener(event)));
  }
  return player;
};

/** 设置、恢复备份与重置都同步当前播放中的均衡器。 */
const syncMobileEqualizer = async (): Promise<void> => {
  const player = await loadPlayer();
  const equalizer = store.get("player.equalizer");
  const results = [
    await player.setEqualizerBands([...equalizer.bands]),
    await player.setPreampGain(equalizer.preamp),
    await player.setEqualizerEnabled(equalizer.enabled),
  ];
  const failed = results.find((result) => !result.success);
  if (failed) throw new Error(failed.error || "音效设置失败");
};

const mobilePlayer = new Proxy(
  {},
  {
    get: (_, property: string) => {
      if (property === "onEvent") {
        return (listener: (event: PlayerEvent) => void) => {
          playerEventListeners.add(listener);
          void loadPlayer();
          return () => playerEventListeners.delete(listener);
        };
      }
      if (property === "syncPlayMode" || property === "syncLikeState") {
        return (...args: unknown[]) => {
          void loadPlayer().then((player) =>
            Reflect.apply(
              player[property as keyof PlayerApi] as (...values: unknown[]) => unknown,
              player,
              args,
            ),
          );
        };
      }
      return (...args: unknown[]) =>
        loadPlayer().then((player) =>
          Reflect.apply(
            player[property as keyof PlayerApi] as (...values: unknown[]) => unknown,
            player,
            args,
          ),
        );
    },
  },
) as PlayerApi;

let streamingPromise: Promise<StreamingApi> | undefined;
const streamingListeners = new Set<(serverId: string) => void>();
let streamingEventsInstalled = false;

const loadStreaming = async (): Promise<StreamingApi> => {
  streamingPromise ??= import("./streaming").then(({ mobileStreaming }) => mobileStreaming);
  const streaming = await streamingPromise;
  if (!streamingEventsInstalled) {
    streamingEventsInstalled = true;
    streaming.onLibraryUpdated((serverId) =>
      streamingListeners.forEach((listener) => listener(serverId)),
    );
  }
  return streaming;
};

const mobileStreaming = new Proxy(
  {},
  {
    get: (_, property: string) => {
      if (property === "onLibraryUpdated") {
        return (listener: (serverId: string) => void) => {
          streamingListeners.add(listener);
          void loadStreaming();
          return () => streamingListeners.delete(listener);
        };
      }
      return (...args: unknown[]) =>
        loadStreaming().then((streaming) =>
          Reflect.apply(
            streaming[property as keyof StreamingApi] as (...values: unknown[]) => unknown,
            streaming,
            args,
          ),
        );
    },
  },
) as StreamingApi;

const noop = (): void => undefined;
const unsubscribe = (): (() => void) => noop;
const unsupported = async () => ({ ok: false, error: "unsupported on iOS" });

let pendingProtocolUrl: string | null = null;
let pendingAudioFiles: string[] = [];
const protocolListeners = new Set<(url: string) => void>();
const openFileListeners = new Set<(paths: string[]) => void>();

const routeIncomingUrls = (urls: string[]): void => {
  const files: string[] = [];
  for (const url of urls) {
    if (url.startsWith("file://")) {
      try {
        files.push(decodeURIComponent(new URL(url).pathname));
      } catch {
        // 忽略系统传入的无效 URL。
      }
    } else if (url.startsWith("orpheus://")) {
      pendingProtocolUrl = url;
      protocolListeners.forEach((listener) => listener(url));
    }
  }
  if (files.length) {
    pendingAudioFiles = files;
    openFileListeners.forEach((listener) => listener(files));
  }
};

const initializeDeepLinks = (): void => {
  void getCurrent().then((urls) => urls && routeIncomingUrls(urls));
  void onOpenUrl(routeIncomingUrls);
};

let nowPlaying: NowPlayingUpdatePayload = { track: null, lyric: [], source: null };
const lyricOffsets = new Map<string, number>();
const offsetListeners = new Set<(value: { trackId: string | null; offsetMs: number }) => void>();
const trackListeners = new Set<(value: { track: Track | null }) => void>();
const lyricListeners = new Set<(value: NowPlayingSnapshot) => void>();

const snapshot = async (): Promise<NowPlayingSnapshot> => {
  const result = await mobilePlayer.getStatus();
  const status = result.data ?? {
    state: "idle" as const,
    position: 0,
    duration: 0,
    volume: 1,
    speed: 1,
    isFinished: false,
  };
  return {
    ...nowPlaying,
    position: status.position,
    playing: status.state === "playing",
    state: status.state,
    speed: status.speed,
    lyricOffsetMs: nowPlaying.track ? (lyricOffsets.get(nowPlaying.track.id) ?? 0) : 0,
    sendTimestamp: Date.now(),
  };
};

let hotkeys: HotkeyConfig = structuredClone(defaultHotkeyConfig);

mobileLyricPip.configure(snapshot, (playing) => {
  void loadPlayer().then((player) => player.dispatch(playing ? "play" : "pause"));
});

const api = {
  config: {
    get: async (key: string) => store.get(key as never),
    set: async (key: string, value: unknown) => {
      if (key === "system.diagnosticLogging") await setDiagnosticsEnabled(value === true);
      store.set(key, value);
      if (!store.get("download.enabled")) await mobileDownload.cancelAll();
      if (key === "player.equalizer" || key.startsWith("player.equalizer.")) {
        await syncMobileEqualizer();
      }
      if (key === "update.channel") void mobileUpdate.check(true);
      if (key.startsWith("media.")) mobileMediaSession.refresh();
      if (key === "desktopLyric" || key.startsWith("desktopLyric.")) await mobileLyricPip.update();
    },
    getAll: async () => store.store,
    reset: async () => {
      await setDiagnosticsEnabled(false);
      store.clear();
      await mobileDownload.cancelAll();
      await syncMobileEqualizer();
      mobileMediaSession.refresh();
      await mobileLyricPip.update();
    },
    replaceAll: async (value: unknown) => {
      store.replaceAll(value);
      if (!store.get("download.enabled")) await mobileDownload.cancelAll();
      await syncMobileEqualizer();
      await setDiagnosticsEnabled(store.get("system.diagnosticLogging") === true);
      mobileMediaSession.refresh();
      await mobileLyricPip.update();
    },
    exportToFile: async (value: unknown) => {
      const path = await save({ defaultPath: "splayer-settings.json" });
      if (!path) return { ok: false, reason: "canceled" as const };
      try {
        await writeFile(path, new TextEncoder().encode(JSON.stringify(value, null, 2)));
        return { ok: true };
      } catch {
        return { ok: false, reason: "writeFailed" as const };
      }
    },
    importFromFile: async () => {
      const path = await open({
        multiple: false,
        directory: false,
        filters: [{ name: "JSON", extensions: ["json"] }],
      });
      if (!path || Array.isArray(path)) return { ok: false as const, reason: "canceled" as const };
      try {
        return { ok: true as const, data: JSON.parse(await readTextFile(path)) as unknown };
      } catch {
        return { ok: false as const, reason: "parseFailed" as const };
      }
    },
  },
  player: mobilePlayer,
  system: {
    installType: "ipa",
    platform: "ios",
    osInfo: { type: "iOS", arch: "arm64", release: "" },
    toggleDevTools: async () => undefined,
    showInExplorer: async () => undefined,
    openLogsDir: async () => "",
    setLocale: noop,
    focusMainWindow: async () => undefined,
    openSettings: async () => undefined,
    onOpenSettings: unsubscribe,
    listFonts: async () => ["system-ui"],
    fetchRemoteBytes: async (url: string) => {
      try {
        const response = await tauriFetch(url);
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return {
          success: true,
          data: new Uint8Array(await response.arrayBuffer()) as unknown as Buffer,
        };
      } catch (error) {
        return { success: false, error: error instanceof Error ? error.message : String(error) };
      }
    },
    saveFile: async (data: ArrayBuffer, name: string) => {
      try {
        const path = await save({ defaultPath: name });
        if (!path) return { success: false, error: "canceled" };
        await writeFile(path, new Uint8Array(data));
        return { success: true, path };
      } catch (error) {
        return { success: false, error: error instanceof Error ? error.message : String(error) };
      }
    },
    relaunch: async () => location.reload(),
    testNetworkProxy,
    onProtocolUrl: (callback: (url: string) => void) => {
      protocolListeners.add(callback);
      return () => protocolListeners.delete(callback);
    },
    consumePendingProtocolUrl: async () => {
      const url = pendingProtocolUrl;
      pendingProtocolUrl = null;
      return url;
    },
    onOpenFiles: (callback: (paths: string[]) => void) => {
      openFileListeners.add(callback);
      return () => openFileListeners.delete(callback);
    },
    consumePendingAudioFiles: async () => {
      const paths = pendingAudioFiles;
      pendingAudioFiles = [];
      return paths;
    },
    getPathForFile: (file: File) => URL.createObjectURL(file),
  },
  library: mobileLibrary,
  playlist: mobilePlaylist,
  window: {
    toggleDesktopLyric: mobileLyricPip.toggle,
    closeDesktopLyric: mobileLyricPip.close,
    isDesktopLyricOpen: mobileLyricPip.isOpen,
    onDesktopLyricVisibilityChange: mobileLyricPip.onVisibility,
    toggleDynamicIsland: async () => undefined,
    closeDynamicIsland: async () => undefined,
    isDynamicIslandOpen: async () => false,
    onDynamicIslandVisibilityChange: unsubscribe,
    toggleTaskbarLyric: async () => undefined,
    closeTaskbarLyric: async () => undefined,
    isTaskbarLyricOpen: async () => false,
    onTaskbarLyricVisibilityChange: unsubscribe,
    minimize: noop,
    toggleMaximize: noop,
    isMaximized: async () => false,
    onMaximizeChange: unsubscribe,
    toggleFullscreen: noop,
    isFullscreen: async () => false,
    onFullscreenChange: unsubscribe,
    hide: noop,
    quit: noop,
  },
  desktopLyric: {
    onConfigChange: unsubscribe,
    setHeight: async () => undefined,
    setUnlockButtonBounds: noop,
    move: noop,
    saveState: noop,
    onCursorInside: unsubscribe,
  },
  dynamicIsland: {
    onConfigChange: unsubscribe,
    move: noop,
    saveState: noop,
    resize: noop,
    setShape: noop,
    setHeight: noop,
    getMode: async () => "snapped",
    onModeChange: unsubscribe,
    onCursorInside: unsubscribe,
  },
  taskbarLyric: { setContentWidth: noop, onLayout: unsubscribe, onConfigChange: unsubscribe },
  plugins: {
    list: async () => [],
    install: unsupported,
    pickAndInstall: async () => ({
      ok: false,
      error: "plugins are disabled on iOS",
      cancelled: true,
    }),
    installFromUrl: unsupported,
    uninstall: unsupported,
    setEnabled: async () => undefined,
    setSetting: async () => undefined,
    checkUpdate: async () => ({ ok: false, hasUpdate: false, error: "unsupported on iOS" }),
    applyUpdate: unsupported,
    resolveUrl: async () => {
      throw new Error("plugins are disabled on iOS");
    },
    invokeMenu: unsupported,
    matchLyric: unsupported,
    matchCover: unsupported,
    market: async () => ({ ok: true, plugins: [] }),
    onStatus: unsubscribe,
  },
  apis: mobileProviders,
  cloud: {
    pickSongs: async () => [],
    uploadSong: async () => ({ success: false, instant: false, errorCode: -1 }),
    onUploadProgress: unsubscribe,
  },
  lyrics: mobileLyrics,
  opencc: { convert: async (text: string) => text, convertBatch: async (texts: string[]) => texts },
  comments: mobileComments,
  download: mobileDownload,
  nowPlaying: {
    update: (value: NowPlayingUpdatePayload) => {
      const changed = value.track?.id !== nowPlaying.track?.id;
      nowPlaying = value;
      void mobileLyricPip
        .update()
        .catch((error) => console.warn("[lyric-pip] 歌词同步失败", error));
      mobileMediaSession.setLyrics(
        value,
        value.track ? (lyricOffsets.get(value.track.id) ?? 0) : 0,
      );
      if (changed) trackListeners.forEach((listener) => listener({ track: value.track }));
      void snapshot().then((value) => lyricListeners.forEach((listener) => listener(value)));
    },
    requestSnapshot: snapshot,
    setLyricOffset: (id: string, offset: number) => {
      lyricOffsets.set(id, offset);
      void mobileLyricPip
        .update()
        .catch((error) => console.warn("[lyric-pip] 偏移同步失败", error));
      mobileMediaSession.setOffset(id, offset);
      offsetListeners.forEach((listener) => listener({ trackId: id, offsetMs: offset }));
    },
    onTrackChange: (callback: (value: { track: Track | null }) => void) => {
      trackListeners.add(callback);
      return () => trackListeners.delete(callback);
    },
    onLyricChange: (callback: (value: NowPlayingSnapshot) => void) => {
      lyricListeners.add(callback);
      return () => lyricListeners.delete(callback);
    },
    onPositionSync: (callback: (value: unknown) => void) =>
      mobilePlayer.onEvent((event: PlayerEvent) => {
        if (event.type !== "position") return;
        void snapshot().then(callback);
      }),
    onLyricOffsetChange: (
      callback: (value: { trackId: string | null; offsetMs: number }) => void,
    ) => {
      offsetListeners.add(callback);
      return () => offsetListeners.delete(callback);
    },
  },
  theme: {
    pickBackgroundImage: async () => {
      const path = await open({
        multiple: false,
        directory: false,
        filters: [{ name: "Images", extensions: ["png", "jpg", "jpeg", "webp"] }],
      });
      return typeof path === "string" ? convertFileSrc(path) : null;
    },
    clearBackgroundImages: async () => undefined,
  },
  cache: {
    getStats: async () => [],
    clear: async () => undefined,
    clearAllByKind: async () => undefined,
    getDir: async () => "Application Cache",
    pickDir: async () => ({ ok: true, dir: "Application Cache" }),
    resetDir: async () => "Application Cache",
    song: { lookup: async () => null, fetch: async () => null, cancel: async () => undefined },
  },
  streaming: mobileStreaming,
  recognition: {
    isSupported: async () => false,
    start: unsupported,
    cancel: unsupported,
    submitPcm: unsupported,
    onEvent: unsubscribe,
  },
  lastfm: {
    connect: async () => ({ connected: false, reason: "error" }),
    cancelConnect: async () => undefined,
    disconnect: async () => undefined,
    getStatus: async () => ({ connected: false, username: "" }),
    love: async () => undefined,
  },
  externalApi: {
    restart: async () => ({ running: false }),
    getStatus: async () => ({ running: false }),
    onStatus: unsubscribe,
  },
  mcp: {
    restart: async () => ({ running: false }),
    getStatus: async () => ({ running: false }),
    getClientConfigParams: async () => ({ port: 0, accessKey: "" }),
    detectAgents: async () => [],
    injectAgentConfig: async () => false,
    onStatus: unsubscribe,
  },
  aiModel: {
    list: async () => ({ models: [], activeModelId: null }),
    save: async () => ({ models: [], activeModelId: null }),
    remove: async () => ({ models: [], activeModelId: null }),
    setActive: async () => ({ models: [], activeModelId: null }),
  },
  update: mobileUpdate,
  stats: mobileStats,
  hotkey: {
    getAll: async () => hotkeys,
    set: async (
      id: keyof HotkeyConfig["bindings"],
      binding: HotkeyConfig["bindings"][typeof id],
    ) => {
      hotkeys.bindings[id] = binding;
      return hotkeys;
    },
    reset: async () => {
      hotkeys = structuredClone(defaultHotkeyConfig);
      return hotkeys;
    },
    setGlobalEnabled: async (enabled: boolean) => {
      hotkeys.globalEnabled = enabled;
      return hotkeys;
    },
    probe: async () => false,
    getConflicts: async () => [],
    onTrigger: unsubscribe,
    onConflicts: unsubscribe,
  },
};

export const installMobileApi = (): void => {
  window.api = api as unknown as Window["api"];
  document.documentElement.classList.add("mobile", "ios");
  // WKWebView 解析首屏模块时调用 deep-link 插件可能阻塞渲染，延后注册原生监听。
  window.setTimeout(initializeDeepLinks, 1_000);
};
