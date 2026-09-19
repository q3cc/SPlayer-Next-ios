import localforage from "localforage";
import { open } from "@tauri-apps/plugin-dialog";
import { readTextFile } from "@tauri-apps/plugin-fs";
import { parsePluginScript } from "@shared/utils/pluginScript";
import {
  ACTION_TIMEOUTS,
  HOST_API_LEVEL,
  INSTALL_URL_MAX_SIZE,
  PLUGIN_STORAGE_MAX_SIZE,
  PLUGIN_LOAD_TIMEOUT,
  PLUGIN_REGISTRY_URL,
  REQUEST_DEFAULT_TIMEOUT,
  REQUEST_MAX_TIMEOUT,
} from "@shared/defaults/plugin-api";
import type {
  ActionIO,
  HostRequestOptions,
  MarketPlugin,
  PlaybackEventKind,
  PluginAction,
  PluginInfo,
  PluginsApi,
  PluginMatchLyricArgs,
  PluginRegistration,
  SandboxIn,
  SandboxOut,
  MusicSearchCandidate,
  PluginMatchCommentArgs,
} from "@shared/types/plugin";
import type { NowPlayingSnapshot } from "@shared/types/nowPlaying";
import { pickBestCandidate } from "@main/apis/common/lyric/utils";
import { fetchPluginScript, requestPlugin } from "./network";
import { store } from "../shims/store";
import { pluginLog } from "../shims/logger";

interface SavedPlugin {
  info: PluginInfo;
  source: string;
}
interface Pending {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}
interface Runtime {
  worker: Worker;
  source: string;
  ready: Promise<void>;
  registration: Partial<PluginRegistration>;
  pending: Map<string, Pending>;
  requests: Set<AbortController>;
  restartAttempts: number;
}

const storage = localforage.createInstance({ name: "splayer", storeName: "plugins" });
const data = localforage.createInstance({ name: "splayer", storeName: "pluginData" });
const records = new Map<string, PluginInfo>();
const runtimes = new Map<string, Runtime>();
const listeners = new Set<(info: PluginInfo) => void>();
const MAX_PLUGINS = 16;
const MAX_RESTART_ATTEMPTS = 3;
const RESTART_DELAYS = [2_000, 8_000, 30_000] as const;
let initialization: Promise<void> | undefined;
let sequence = 0;
let playbackSnapshotProvider: (() => Promise<NowPlayingSnapshot>) | undefined;

const errorText = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);
const announce = (info: PluginInfo): void =>
  listeners.forEach((listener) => listener(structuredClone(info)));

/** 终止线程时同步拒绝调用并取消网络请求，避免禁用后继续活动。 */
const stop = (id: string, error = new Error("插件已停止")): void => {
  const runtime = runtimes.get(id);
  if (!runtime) return;
  runtimes.delete(id);
  runtime.worker.terminate();
  runtime.requests.forEach((controller) => controller.abort());
  runtime.pending.forEach((pending) => {
    clearTimeout(pending.timer);
    pending.reject(error);
  });
  runtime.pending.clear();
};

const hostCall = async (
  info: PluginInfo,
  runtime: Runtime,
  message: Extract<SandboxOut, { kind: "hostCall" }>,
): Promise<void> => {
  const { method, args, callId } = message;
  const id = info.manifest.id;
  try {
    let result: unknown;
    if (method === "request") {
      if (!info.manifest.grant.includes("network")) throw new Error("插件未声明联网权限");
      if (runtime.requests.size >= 16) throw new Error("插件请求过多");
      const controller = new AbortController();
      const options = (args[1] ?? {}) as HostRequestOptions;
      const timeout = Math.min(
        Math.max(options.timeout ?? REQUEST_DEFAULT_TIMEOUT, 1_000),
        REQUEST_MAX_TIMEOUT,
      );
      const timer = setTimeout(() => controller.abort(), timeout);
      runtime.requests.add(controller);
      try {
        result = await requestPlugin(String(args[0]), options, controller.signal);
      } finally {
        clearTimeout(timer);
        runtime.requests.delete(controller);
      }
    } else if (method.startsWith("storage.")) {
      const prefix = id + ":";
      const key = prefix + String(args[0]);
      if (method === "storage.get") result = await data.getItem(key);
      else if (method === "storage.remove") await data.removeItem(key);
      else if (method === "storage.keys")
        result = (await data.keys())
          .filter((key) => key.startsWith(prefix))
          .map((key) => key.slice(prefix.length));
      else if (method === "storage.set") {
        const encoded = JSON.stringify(args[1]);
        if (new TextEncoder().encode(encoded).length > 4 * 1024 * 1024)
          throw new Error("插件数据超过大小限制");
        const keys = (await data.keys()).filter((key) => key.startsWith(prefix));
        if (keys.length >= 128 && !keys.includes(key)) throw new Error("插件数据条目过多");
        const values = await Promise.all(keys.map((item) => data.getItem<unknown>(item)));
        const existingSize = values.reduce<number>(
          (size, value) =>
            size + (value == null ? 0 : new TextEncoder().encode(JSON.stringify(value)).length),
          0,
        );
        const oldValue = await data.getItem<unknown>(key);
        const oldSize =
          oldValue == null ? 0 : new TextEncoder().encode(JSON.stringify(oldValue)).length;
        if (
          existingSize - oldSize + new TextEncoder().encode(encoded).length >
          PLUGIN_STORAGE_MAX_SIZE
        )
          throw new Error("插件数据总量超过大小限制");
        await data.setItem(key, args[1]);
      }
    } else if (method.startsWith("player.")) {
      if (!info.manifest.grant.includes("control")) throw new Error("插件未声明播放控制权限");
      const { mobilePlayer } = await import("../player");
      if (method === "player.getPosition")
        result = (await mobilePlayer.getStatus()).data?.position ?? 0;
      else if (method === "player.seek") await mobilePlayer.seek(Number(args[0]));
      else if (method === "player.setVolume") await mobilePlayer.setVolume(Number(args[0]));
      else mobilePlayer.dispatch(method.slice(7) as "play" | "pause" | "next" | "prev");
    } else throw new Error("未知插件操作");
    if (runtimes.get(id) === runtime)
      runtime.worker.postMessage({
        kind: "hostResult",
        pluginId: id,
        callId,
        ok: true,
        data: result,
      } satisfies SandboxIn);
  } catch (error) {
    if (runtimes.get(id) === runtime)
      runtime.worker.postMessage({
        kind: "hostResult",
        pluginId: id,
        callId,
        ok: false,
        error: { code: "PLUGIN_HOST_ERROR", message: errorText(error) },
      } satisfies SandboxIn);
  }
};

/** 每个已安装插件最多一个线程；状态表由安装数量上限约束。 */
const start = (info: PluginInfo, source: string): Runtime => {
  const id = info.manifest.id;
  stop(id);
  info.status = { state: "loading" };
  const worker = new Worker(new URL("./worker.ts", import.meta.url), { type: "module" });
  const runtime: Runtime = {
    worker,
    source,
    ready: Promise.resolve(),
    registration: {},
    pending: new Map(),
    requests: new Set(),
    restartAttempts: 0,
  };
  runtimes.set(id, runtime);
  runtime.ready = new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => fail(new Error("插件加载超时")), PLUGIN_LOAD_TIMEOUT);
    runtime.pending.set("load", { resolve: () => resolve(), reject, timer });
  });
  const fail = (error: Error): void => {
    info.status = {
      state: "error",
      error: { code: "PLUGIN_SCRIPT_ERROR", message: error.message },
    };
    stop(id, error);
    announce(info);
  };
  worker.onerror = (event) => {
    event.preventDefault();
    const error = new Error(event.message || "插件运行失败");
    if (info.enabled && runtime.restartAttempts < MAX_RESTART_ATTEMPTS) {
      runtime.restartAttempts += 1;
      stop(id, error);
      info.status = { state: "loading" };
      announce(info);
      const delay = RESTART_DELAYS[runtime.restartAttempts - 1] ?? RESTART_DELAYS[2];
      setTimeout(() => {
        if (records.get(id) === info && info.enabled) start(info, runtime.source);
      }, delay);
      return;
    }
    fail(error);
  };
  worker.onmessage = ({ data: message }: MessageEvent<SandboxOut>) => {
    if (runtimes.get(id) !== runtime) return;
    switch (message.kind) {
      case "hostReady": {
        const manifest = info.manifest;
        worker.postMessage({
          kind: "loadPlugin",
          pluginId: id,
          apiLevel: HOST_API_LEVEL,
          locale: document.documentElement.lang || "zh-CN",
          appVersion: __APP_VERSION__,
          source,
          userSettings: info.settingsValues ?? {},
          scriptInfo: {
            name: manifest.name,
            description: manifest.description ?? "",
            version: manifest.version,
            author: manifest.author ?? "",
            homepage: manifest.homepage ?? "",
          },
        } satisfies SandboxIn);
        // 源码发送后不再由消息闭包保留。
        source = "";
        break;
      }
      case "ready": {
        runtime.restartAttempts = 0;
        info.status = { state: "ready", sources: message.sources, ...runtime.registration };
        const pending = runtime.pending.get("load");
        if (pending) {
          clearTimeout(pending.timer);
          runtime.pending.delete("load");
          pending.resolve(undefined);
        }
        announce(info);
        if (info.manifest.type === "control") void primePluginPlayback(id);
        break;
      }
      case "sourcesUpdate":
        if (info.status.state === "ready") {
          info.status.sources = message.sources;
          announce(info);
        }
        break;
      case "registered":
        runtime.registration = {
          events: message.events,
          controls: message.controls,
          settings: message.settings,
          menus: info.manifest.grant.includes("ui") ? message.menus : [],
        };
        if (info.status.state === "ready") {
          Object.assign(info.status, runtime.registration);
          announce(info);
        }
        break;
      case "result": {
        const pending = runtime.pending.get(message.requestId);
        if (pending) {
          clearTimeout(pending.timer);
          runtime.pending.delete(message.requestId);
          if (message.ok) pending.resolve(message.data);
          else pending.reject(new Error(message.error?.message ?? "插件调用失败"));
        }
        break;
      }
      case "hostCall":
        void hostCall(info, runtime, message);
        break;
      case "fatal":
        fail(new Error(message.error.message));
        break;
      case "updateAvailable":
        info.updateInfo = message.info;
        announce(info);
        break;
      case "log":
        pluginLog[message.level](`[${id}]`, ...message.args);
        break;
    }
  };
  void runtime.ready.catch(() => {});
  announce(info);
  return runtime;
};

const initialize = (): Promise<void> => {
  initialization ??= (async () => {
    const ids = await storage.keys();
    for (const id of ids.slice(0, MAX_PLUGINS)) {
      const saved = await storage.getItem<SavedPlugin>(id);
      if (!saved) continue;
      const enabledMap = store.get("plugins.enabled");
      if (Object.prototype.hasOwnProperty.call(enabledMap, id))
        saved.info.enabled = enabledMap[id] === true;
      const persistedSettings = store.get(`plugins.perPlugin.${id}` as never) as
        Record<string, unknown> | undefined;
      if (persistedSettings) saved.info.settingsValues = persistedSettings;
      records.set(id, saved.info);
      saved.info.status = { state: saved.info.enabled ? "unloaded" : "disabled" };
      if (saved.info.enabled) start(saved.info, saved.source);
    }
    const updateTargets = [...records.values()].filter((info) => info.manifest.updateUrl);
    void Promise.resolve().then(() =>
      Promise.allSettled(updateTargets.map((info) => mobilePlugins.checkUpdate(info.manifest.id))),
    );
  })().catch((error) => {
    initialization = undefined;
    throw error;
  });
  return initialization;
};

const call = async <A extends PluginAction>(
  id: string,
  action: A,
  params: ActionIO[A]["req"],
): Promise<ActionIO[A]["res"]> => {
  await initialize();
  const runtime = runtimes.get(id);
  if (!runtime) throw new Error("插件未启用");
  await runtime.ready;
  if (runtimes.get(id) !== runtime) throw new Error("插件已停止");
  if (runtime.pending.size >= 32) throw new Error("插件调用过多");
  const requestId = String(++sequence);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      const error = new Error("插件调用超时");
      stop(id, error);
      const info = records.get(id)!;
      info.status = {
        state: "error",
        error: { code: "PLUGIN_REQUEST_TIMEOUT", message: error.message },
      };
      announce(info);
    }, ACTION_TIMEOUTS[action]);
    runtime.pending.set(requestId, {
      resolve: (value) => resolve(value as ActionIO[A]["res"]),
      reject,
      timer,
    });
    runtime.worker.postMessage({
      kind: "call",
      pluginId: id,
      requestId,
      action,
      params: JSON.parse(JSON.stringify(params)),
    } satisfies SandboxIn);
  });
};

/** 安装成功只表示保存成功，脚本加载错误仍通过卡片状态反馈。 */
export const installMobilePlugin = async (
  raw: string,
  expectedId?: string,
): Promise<{ ok: boolean; id?: string; error?: string }> => {
  try {
    await initialize();
    if (new TextEncoder().encode(raw).length > INSTALL_URL_MAX_SIZE)
      throw new Error("插件文件过大");
    const { source, manifest } = parsePluginScript(raw);
    if (new TextEncoder().encode(source).length > INSTALL_URL_MAX_SIZE)
      throw new Error("插件解压后过大");
    if (expectedId && manifest.id !== expectedId) throw new Error("更新文件与当前插件不匹配");
    const previous = records.get(manifest.id);
    if (!previous && records.size >= MAX_PLUGINS)
      throw new Error("已安装插件过多，请先卸载不再使用的插件");
    if (previous) {
      manifest.installedAt = previous.manifest.installedAt;
      manifest.updatedAt = Date.now();
    }
    const info: PluginInfo = {
      manifest,
      enabled: previous?.enabled ?? true,
      status: { state: "unloaded" },
      settingsValues: previous?.settingsValues ?? {},
    };
    await storage.setItem(manifest.id, { info, source } satisfies SavedPlugin);
    const enabledMap = { ...store.get("plugins.enabled"), [manifest.id]: info.enabled };
    store.set("plugins.enabled", enabledMap);
    stop(manifest.id);
    records.set(manifest.id, info);
    if (info.enabled) start(info, source);
    else {
      info.status = { state: "disabled" };
      announce(info);
    }
    return { ok: true, id: manifest.id };
  } catch (error) {
    return { ok: false, error: errorText(error) };
  }
};

const findMatch = async ({
  pluginId,
  source,
  track,
}: PluginMatchLyricArgs): Promise<MusicSearchCandidate | null> => {
  const platforms: Record<string, string> = { netease: "wy", qqmusic: "tx", kugou: "kg" };
  if (platforms[track.source] === source)
    return {
      id: track.id,
      name: track.title,
      singer: track.artists.map((artist) => artist.name).join("/"),
      durationMs: track.duration,
    };
  const result = await call(pluginId, "musicSearch", {
    source,
    keyword: [track.title, ...track.artists.map((artist) => artist.name)].join(" "),
  });
  return (
    pickBestCandidate(
      result.list.map((item) => ({
        name: item.name,
        artist: item.singer ?? "",
        album: item.album,
        duration: item.durationMs,
        extra: item,
      })),
      track,
    )?.extra ?? null
  );
};

export const mobilePlugins: PluginsApi = {
  list: async () => {
    await initialize();
    return structuredClone([...records.values()]);
  },
  install: async (path) => {
    try {
      return await installMobilePlugin(await readTextFile(path));
    } catch (error) {
      return { ok: false, error: errorText(error) };
    }
  },
  pickAndInstall: async () => {
    try {
      const path = await open({
        multiple: false,
        directory: false,
        filters: [{ name: "JavaScript", extensions: ["js"] }],
      });
      return typeof path === "string"
        ? mobilePlugins.install(path)
        : { ok: false, cancelled: true };
    } catch (error) {
      return { ok: false, error: errorText(error) };
    }
  },
  installFromUrl: async (url) => {
    try {
      return await installMobilePlugin(await fetchPluginScript(url));
    } catch (error) {
      return { ok: false, error: errorText(error) };
    }
  },
  uninstall: async (id) => {
    try {
      await initialize();
      await storage.removeItem(id);
      const enabledMap = { ...store.get("plugins.enabled") };
      delete enabledMap[id];
      store.set("plugins.enabled", enabledMap);
      const perPlugin = { ...store.get("plugins.perPlugin") };
      delete perPlugin[id];
      store.set("plugins.perPlugin", perPlugin);
      stop(id);
      records.delete(id);
      for (const key of await data.keys()) if (key.startsWith(id + ":")) await data.removeItem(key);
      return { ok: true };
    } catch (error) {
      return { ok: false, error: errorText(error) };
    }
  },
  setEnabled: async (id, enabled) => {
    await initialize();
    const saved = await storage.getItem<SavedPlugin>(id);
    if (!saved) throw new Error("插件未安装");
    saved.info.enabled = enabled;
    await storage.setItem(id, saved);
    store.set("plugins.enabled", { ...store.get("plugins.enabled"), [id]: enabled });
    const info = records.get(id)!;
    info.enabled = enabled;
    if (enabled) start(info, saved.source);
    else {
      stop(id);
      info.status = { state: "disabled" };
      announce(info);
    }
  },
  setSetting: async (id, key, value) => {
    await initialize();
    const info = records.get(id);
    const item =
      info?.status.state === "ready"
        ? info.status.settings?.find((item) => item.key === key)
        : undefined;
    if (!info || !item) throw new Error("插件设置不存在");
    if (
      (item.type === "switch" && typeof value !== "boolean") ||
      (item.type === "number" &&
        (typeof value !== "number" ||
          !Number.isFinite(value) ||
          value < (item.min ?? -Infinity) ||
          value > (item.max ?? Infinity))) ||
      (item.type === "text" && typeof value !== "string") ||
      (item.type === "select" && !item.options?.some((option) => option.value === value))
    )
      throw new Error("插件设置值无效");
    const saved = await storage.getItem<SavedPlugin>(id);
    if (!saved) throw new Error("插件未安装");
    const settings = { ...info.settingsValues, [key]: value };
    saved.info.settingsValues = settings;
    await storage.setItem(id, saved);
    info.settingsValues = settings;
    store.set(`plugins.perPlugin.${id}` as never, settings);
    runtimes
      .get(id)
      ?.worker.postMessage({ kind: "settingsUpdate", pluginId: id, settings } satisfies SandboxIn);
    announce(info);
  },
  checkUpdate: async (id) => {
    try {
      await initialize();
      const info = records.get(id);
      if (!info?.manifest.updateUrl) throw new Error("插件未提供更新地址");
      const { manifest } = parsePluginScript(await fetchPluginScript(info.manifest.updateUrl));
      if (manifest.id !== id) throw new Error("更新文件与当前插件不匹配");
      if ((manifest.type ?? "source") !== (info.manifest.type ?? "source"))
        throw new Error("更新文件插件类型不匹配，请重新安装");
      const hasUpdate =
        manifest.version.localeCompare(info.manifest.version, undefined, { numeric: true }) > 0;
      info.updateInfo = hasUpdate
        ? {
            version: manifest.version,
            log: manifest.changelog,
            updateUrl: info.manifest.updateUrl,
            updatedAt: Date.now(),
          }
        : null;
      announce(info);
      return { ok: true, hasUpdate, plugin: structuredClone(info) };
    } catch (error) {
      return { ok: false, hasUpdate: false, error: errorText(error) };
    }
  },
  applyUpdate: async (id) => {
    await initialize();
    const fallbackUrl = records.get(id)?.manifest.updateUrl;
    try {
      if (!fallbackUrl) throw new Error("插件未提供更新地址");
      const result = await installMobilePlugin(await fetchPluginScript(fallbackUrl), id);
      return {
        ...result,
        plugin: result.ok ? structuredClone(records.get(id)!) : undefined,
        fallbackUrl,
      };
    } catch (error) {
      return { ok: false, error: errorText(error), fallbackUrl };
    }
  },
  resolveUrl: async ({ pluginId, source, quality, musicInfo }) => {
    const result = await call(pluginId, "musicUrl", {
      source,
      quality: quality ?? "hq",
      musicInfo,
    });
    if (!["https:", "http:"].includes(new URL(result.url).protocol))
      throw new Error("插件返回了无效的播放链接");
    return result;
  },
  invokeMenu: async ({ pluginId, menuId, track }) => {
    try {
      await initialize();
      if (!records.get(pluginId)?.manifest.grant.includes("ui"))
        throw new Error("插件未声明菜单权限");
      return { ok: true, ...(await call(pluginId, "menuClick", { menuId, track })) };
    } catch (error) {
      return { ok: false, error: errorText(error) };
    }
  },
  matchLyric: async (args) => {
    try {
      const musicInfo = await findMatch(args);
      if (!musicInfo) return { ok: false };
      const data = await call(args.pluginId, "musicLyric", { source: args.source, musicInfo });
      return { ok: Boolean(data.lyric), data };
    } catch (error) {
      return { ok: false, error: errorText(error) };
    }
  },
  matchCover: async (args) => {
    try {
      const musicInfo = await findMatch(args);
      if (!musicInfo) return { ok: false };
      const data = await call(args.pluginId, "musicPic", { source: args.source, musicInfo });
      return { ok: Boolean(data.url), data };
    } catch (error) {
      return { ok: false, error: errorText(error) };
    }
  },
  matchComment: async (args: PluginMatchCommentArgs) => {
    try {
      const musicInfo = await findMatch(args);
      if (!musicInfo)
        return { ok: true, data: { list: [], total: 0, page: args.page, limit: args.limit } };
      const data = await call(args.pluginId, "musicComment", {
        source: args.source,
        musicInfo,
        type: args.type,
        page: args.page,
        limit: args.limit,
        cursor: args.cursor,
      });
      return { ok: true, data };
    } catch (error) {
      return { ok: false, error: errorText(error) };
    }
  },
  market: async () => {
    try {
      const result = await requestPlugin(PLUGIN_REGISTRY_URL, { responseType: "json" });
      if (result.status !== 200) throw new Error(`HTTP ${result.status}`);
      const plugins = (result.body as { plugins?: MarketPlugin[] }).plugins;
      if (!Array.isArray(plugins)) throw new Error("插件列表格式无效");
      return { ok: true, plugins: plugins.filter((plugin) => plugin.id && plugin.updateUrl) };
    } catch (error) {
      return { ok: false, plugins: [], error: errorText(error) };
    }
  },
  onStatus: (listener) => {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  },
};

/** 只转发插件订阅的播放事件，不创建额外高频轮询。 */
export const emitPluginPlayback = (event: PlaybackEventKind, data: unknown): void => {
  for (const [id, runtime] of runtimes) {
    const info = records.get(id);
    if (
      info?.enabled &&
      info.manifest.type === "control" &&
      info.status.state === "ready" &&
      runtime.registration.events?.includes(event)
    )
      runtime.worker.postMessage({ kind: "event", pluginId: id, event, data } satisfies SandboxIn);
  }
};

/** 注册播放快照提供者，控制插件就绪后立即收到当前状态。 */
export const setPluginPlaybackSnapshotProvider = (
  provider: () => Promise<NowPlayingSnapshot>,
): void => {
  playbackSnapshotProvider = provider;
};

/** 向单个刚就绪的控制插件补发当前播放快照。 */
export const primePluginPlayback = async (id: string): Promise<void> => {
  const runtime = runtimes.get(id);
  const info = records.get(id);
  const snapshot = playbackSnapshotProvider && (await playbackSnapshotProvider());
  if (!runtime || !info || !snapshot || info.status.state !== "ready") return;
  const send = (event: PlaybackEventKind, data: unknown): void => {
    if (runtime.registration.events?.includes(event))
      runtime.worker.postMessage({ kind: "event", pluginId: id, event, data } satisfies SandboxIn);
  };
  send("trackChange", { track: snapshot.track });
  send("lyricChange", { lines: snapshot.lyric });
  send("playStateChange", {
    state:
      snapshot.state === "playing"
        ? "playing"
        : snapshot.state === "stopped"
          ? "stopped"
          : "paused",
    position: snapshot.position,
  });
  const offset = snapshot.lyricOffsetMs;
  let index = -1;
  for (let i = 0; i < snapshot.lyric.length; i++) {
    if (snapshot.lyric[i].startTime <= snapshot.position + offset) index = i;
    else break;
  }
  if (index >= 0) send("lineChange", { index, position: snapshot.position });
};
