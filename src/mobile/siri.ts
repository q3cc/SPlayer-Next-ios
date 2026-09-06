import { addPluginListener, invoke, isTauri } from "@tauri-apps/api/core";
import { nextTick, watch } from "vue";
import { store } from "./shims/store";
import { getSessionCookies } from "./shims/sessions";
import { useSettingsStore } from "@/stores/settings";
import { useStatusStore } from "@/stores/status";
import { useMediaStore } from "@/stores/media";
import * as playbackQueue from "@/stores/queue";
import type { SiriSnapshot, SiriStatus } from "@shared/types/siri";
import type { Track } from "@shared/types/player";

const call = async <T>(value: Record<string, unknown>): Promise<T> => {
  const result = await invoke<{ json: string }>("plugin:native-audio|siri", {
    request: JSON.stringify(value),
  });
  return JSON.parse(result.json) as T;
};
const key = (track: Track): string => `${track.source}:${track.id}`;
let revision = 0;
let applying = false;
let installed = false;
let pendingSync = false;
let syncing = false;

const adopt = async (snapshot: SiriSnapshot): Promise<void> => {
  if (snapshot.revision < revision) return;
  revision = snapshot.revision;
  const current = snapshot.queue.findIndex((track) => key(track) === snapshot.currentId);
  if (current < 0) return;
  applying = true;
  try {
    const status = useStatusStore();
    const track = snapshot.queue[current];
    const changed = !status.currentTrack || key(status.currentTrack) !== key(track);
    playbackQueue.setQueue(snapshot.queue);
    status.playIndex = current;
    status.position = snapshot.position;
    status.state = snapshot.playing ? "playing" : "paused";
    if (changed) {
      const media = useMediaStore();
      media.setTrack(track);
      media.setPlaybackContext(undefined);
      const lyrics = await import("@/services/lyric/loader");
      void lyrics.loadForTrack(null);
    }
    await nextTick();
  } finally {
    applying = false;
  }
};

/** 合并队列变更，不在每次播放进度更新时发送整份队列。 */
const syncQueue = async (): Promise<void> => {
  if (applying || !installed) return;
  pendingSync = true;
  if (syncing) return;
  syncing = true;
  try {
    while (pendingSync) {
      pendingSync = false;
      const status = useStatusStore();
      const snapshot = {
        revision,
        queue: playbackQueue.queue.value,
        currentId: status.currentTrack ? key(status.currentTrack) : null,
        position: status.position,
        playing: status.state === "playing",
      };
      const result = await call<{ accepted: boolean; snapshot: SiriSnapshot }>({
        action: "syncQueue",
        snapshot,
      });
      if (result.accepted) revision = Math.max(revision, result.snapshot.revision);
      else await adopt(result.snapshot);
    }
  } catch (error) {
    console.warn("[siri] 队列同步失败", error);
  } finally {
    syncing = false;
  }
};

export const mobileSiri = {
  status: (): Promise<SiriStatus> => call({ action: "status" }),
  authorize: (): Promise<SiriStatus> => call({ action: "authorize" }),
  openSettings: (): Promise<SiriStatus> => call({ action: "openSettings" }),
  async configure(): Promise<void> {
    if (!isTauri()) return;
    const settings = useSettingsStore();
    const storage: Record<string, string> = {
      "splayer.mobile.settings": JSON.stringify(store.store),
    };
    for (const source of ["netease", "qqmusic", "kugou"] as const)
      storage[`splayer.mobile.session.${source}`] = JSON.stringify(getSessionCookies(source));
    await call({
      action: "configure",
      preferences: {
        settings: settings.system.siri,
        source: useStatusStore().searchPlatform,
        quality: settings.player.songLevel,
        allowTrial: settings.player.allowTrialPlay,
        repeatMode: useStatusStore().repeatMode,
        shuffleMode: useStatusStore().shuffleMode,
        mediaEnabled: store.get("media.systemMediaControls"),
      },
      storage,
      library: JSON.parse(localStorage.getItem("splayer.mobile.library") ?? "[]"),
    });
  },
  async initialize(): Promise<boolean> {
    if (!isTauri() || installed) return false;
    await addPluginListener<{ json: string }>("native-audio", "siriQueue", ({ json }) => {
      void adopt(JSON.parse(json) as SiriSnapshot).catch((error) =>
        console.warn("[siri] 播放状态同步失败", error),
      );
    });
    const restored = await call<SiriSnapshot>({ action: "snapshot" });
    revision = Math.max(revision, restored.revision);
    const native = await window.api.player.getStatus();
    const active =
      native.data?.state === "playing" ||
      native.data?.state === "paused" ||
      native.data?.state === "loading";
    if (active && restored.currentId)
      await adopt({
        ...restored,
        position: native.data!.position,
        playing: native.data!.state === "playing",
      });
    await mobileSiri.configure();
    installed = true;
    watch([playbackQueue.queueEntries, () => useStatusStore().playIndex], () => void syncQueue(), {
      flush: "post",
    });
    watch(
      () => [
        useSettingsStore().system.siri,
        useSettingsStore().player.songLevel,
        useSettingsStore().player.allowTrialPlay,
        useStatusStore().searchPlatform,
        useStatusStore().repeatMode,
        useStatusStore().shuffleMode,
        useSettingsStore().system.media.systemMediaControls,
      ],
      () => void mobileSiri.configure().catch(console.warn),
      { deep: true },
    );
    window.addEventListener(
      "splayer:siri-data-changed",
      () => void mobileSiri.configure().catch(console.warn),
    );
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden && useSettingsStore().system.siri.enabled)
        void call<SiriSnapshot>({ action: "snapshot" }).then(adopt).catch(console.warn);
    });
    if (!active) await syncQueue();
    return !!active;
  },
};
