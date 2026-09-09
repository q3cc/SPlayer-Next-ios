import { addPluginListener, invoke, isTauri } from "@tauri-apps/api/core";
import { nextTick, watch } from "vue";
import { store } from "./shims/store";
import { getSessionCookies } from "./shims/sessions";
import { mobileMediaSession } from "./mediaSession";
import { playbackDuration } from "@shared/utils/playbackDuration";
import { useSettingsStore } from "@/stores/settings";
import { useStatusStore } from "@/stores/status";
import { useMediaStore } from "@/stores/media";
import { useDataStore } from "@/stores/data";
import { useUserStore } from "@/stores/user";
import * as playback from "@/services/playback";
import * as lyrics from "@/services/lyric/loader";
import { adoptNativePlayback } from "@/core/player";
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
let applying = 0;
let installed = false;
let pendingSync = false;
let syncing = false;
let adoption = 0;
let lyricTrack: string | null = null;

const adopt = async (snapshot: SiriSnapshot): Promise<void> => {
  if (snapshot.revision < revision) return;
  revision = snapshot.revision;
  const token = ++adoption;
  const current = snapshot.queue.findIndex((track) => key(track) === snapshot.currentId);
  if (current < 0) return;
  applying++;
  try {
    const native = (await window.api.player.getStatus()).data;
    if (token !== adoption || snapshot.revision < revision) return;
    const status = useStatusStore();
    const track = snapshot.queue[current];
    const media = useMediaStore();
    const changed = !media.track || key(media.track) !== key(track);
    if (changed || status.trackLoading || lyricTrack === null) adoptNativePlayback();
    playbackQueue.setQueue(snapshot.queue);
    status.playIndex = current;
    if (snapshot.repeatMode) status.repeatMode = snapshot.repeatMode;
    if (snapshot.shuffleMode) status.shuffleMode = snapshot.shuffleMode;
    status.trackLoading = false;
    status.position = native?.position ?? snapshot.position;
    status.duration = playbackDuration(native?.duration, track.duration || 0);
    status.state =
      native && native.state !== "idle" ? native.state : snapshot.playing ? "playing" : "paused";
    playback.setSeeking(false);
    playback.setDuration(status.duration);
    playback.setSpeed(native?.speed ?? status.speed ?? 1);
    playback.setPlaying(status.state === "playing");
    playback.setCurrentTime(status.position, { force: true });
    // Siri 不经过网页播放器的 load，接管时也要同步系统卡片的曲目身份。
    mobileMediaSession.setTrack(track);
    mobileMediaSession.setPosition(status.position);
    if (changed) {
      media.detail = null;
      media.setTrack(track);
      media.setPlaybackContext(undefined);
    }
    // 冷启动时队列可能已恢复，但歌词没有持久化，仍须加载；不能重新 load 音源。
    if (changed || lyricTrack !== key(track)) {
      lyricTrack = key(track);
      void lyrics.loadForTrack(media.detail).then(() => {
        if (token === adoption)
          media.updateLyricIndex(playback.getCurrentTime() + (status.lyricOffsetMs ?? 0));
      });
    }
    await nextTick();
  } finally {
    applying--;
  }
};

/** 合并队列变更，不在每次播放进度更新时发送整份队列。 */
const syncQueue = async (): Promise<void> => {
  if (applying || !installed || !useSettingsStore().system.siri.enabled) return;
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
        vipSources: [
          ...(useUserStore().profile?.vipType ? ["netease"] : []),
          ...(["qqmusic", "kugou"] as const).filter(
            (source) => useDataStore().getPlatformProfile(source)?.isVip,
          ),
        ],
      },
      storage,
      library: settings.system.siri.enabled
        ? JSON.parse(localStorage.getItem("splayer.mobile.library") ?? "[]")
        : [],
    });
    if (installed && settings.system.siri.enabled) await syncQueue();
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
        useUserStore().profile,
        useDataStore().platformProfiles,
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
    if (!active && !restored.pending) await syncQueue();
    const latest = await window.api.player.getStatus();
    return !!(
      active ||
      restored.pending ||
      latest.data?.state === "playing" ||
      latest.data?.state === "paused" ||
      latest.data?.state === "loading"
    );
  },
};
