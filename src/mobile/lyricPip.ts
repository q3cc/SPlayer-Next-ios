import { addPluginListener, invoke } from "@tauri-apps/api/core";
import type { NowPlayingSnapshot } from "@shared/types/nowPlaying";
import type { PlayerStatus } from "@shared/types/player";
import { toast } from "@/composables/useToast";
import { store } from "./shims/store";
import type { SystemConfig } from "@shared/types/settings";
import { hasRealWordTiming } from "@windows/desktop-lyric/utils";
import { colord } from "colord";

/** 复用已解析的歌词，仅把当前曲目的行文本交给系统画中画。 */
export const pipContent = (
  value: NowPlayingSnapshot,
  options: Pick<SystemConfig["desktopLyric"], "doubleLine" | "showTranslation"> &
    Partial<
      Pick<
        SystemConfig["desktopLyric"],
        "fontSize" | "playedColor" | "unplayedColor" | "pipFrameRate"
      >
    > = {
    doubleLine: false,
    showTranslation: true,
  },
) => ({
  title: value.track?.title ?? "",
  artist: value.track?.artists.map((artist) => artist.name).join(" / ") ?? "",
  cover: value.track?.cover ?? "",
  offset: value.lyricOffsetMs,
  style: {
    frameRate: [5, 10, 15, 20, 30, 60].includes(options.pipFrameRate ?? 60)
      ? (options.pipFrameRate ?? 60)
      : 60,
    fontSize: Math.max(16, Math.min(40, options.fontSize ?? 24)),
    playedColor: colord(options.playedColor ?? "rgb(254, 121, 113)").toRgb(),
    unplayedColor: colord(options.unplayedColor ?? "rgb(255, 255, 255)").toRgb(),
  },
  lines: value.lyric
    .filter((line) => !line.isBG)
    .map((line) => ({
      start: line.startTime,
      end: line.endTime,
      text: line.words
        .map((word) => word.word)
        .join("")
        .trim(),
      translation: line.translatedLyric,
      roman: line.romanLyric ?? "",
      words: hasRealWordTiming(line)
        ? line.words.map(({ word, startTime, endTime }) => ({
            text: word,
            start: startTime,
            end: endTime,
          }))
        : [],
    }))
    .filter((line) => line.text)
    .sort((a, b) => a.start - b.start)
    .map((line, index, lines) => {
      const extras = options.showTranslation
        ? [line.roman, line.translation].map((text) => text.trim()).filter(Boolean)
        : [];
      const next = lines[index + 1]?.text;
      return {
        start: line.start,
        end: line.end,
        primary: 0,
        nextPreview: !!(options.doubleLine && !extras.length && next),
        words: line.words,
        rows: extras.length
          ? [line.text, ...extras]
          : options.doubleLine && next
            ? [line.text, next]
            : [line.text],
      };
    }),
});

let active = false;
let starting = false;
let revision = 0;
let snapshot: (() => Promise<NowPlayingSnapshot>) | undefined;
let playback: ((playing: boolean) => void) | undefined;
let listenersReady: Promise<unknown> | undefined;
const visibilityListeners = new Set<(open: boolean) => void>();
let pendingAnchor: (PlayerStatus & { timestamp: number }) | undefined;
let syncing = false;
let lastAnchor: (PlayerStatus & { timestamp: number }) | undefined;

/** 合并尚未发送的进度，原生端阻塞时不积累 IPC 队列。 */
const flushAnchor = async (): Promise<void> => {
  if (syncing) return;
  syncing = true;
  try {
    while (pendingAnchor && (active || starting)) {
      const next = pendingAnchor;
      pendingAnchor = undefined;
      await invoke("plugin:lyric-pip|sync", {
        position: next.position,
        duration: next.duration,
        playing: next.state === "playing",
        speed: next.speed,
        timestamp: next.timestamp,
      });
    }
  } catch (error) {
    console.warn("[lyric-pip] 进度同步失败", error);
  } finally {
    syncing = false;
  }
};

export const mobileLyricPip = {
  async preview(): Promise<string> {
    const value = await snapshot?.();
    if (!value) return "";
    const result = await invoke<{ image: string }>("plugin:lyric-pip|preview", {
      content: pipContent(value, store.get("desktopLyric")),
      position: value.position,
      playing: value.playing,
    });
    return result.image;
  },
  async releasePreview(): Promise<void> {
    await invoke("plugin:lyric-pip|discard");
  },
  configure(
    getSnapshot: () => Promise<NowPlayingSnapshot>,
    onPlayback: (playing: boolean) => void,
  ): void {
    snapshot = getSnapshot;
    playback = onPlayback;
  },
  isOpen: async (): Promise<boolean> => active,
  onVisibility(callback: (open: boolean) => void): () => void {
    visibilityListeners.add(callback);
    return () => visibilityListeners.delete(callback);
  },
  sync(status: PlayerStatus, force = false): void {
    if (!active && !starting) return;
    const now = Date.now();
    if (!force && lastAnchor) {
      const elapsed = now - lastAnchor.timestamp;
      const expected =
        lastAnchor.position + (lastAnchor.state === "playing" ? elapsed * lastAnchor.speed : 0);
      if (
        elapsed < 1000 &&
        status.state === lastAnchor.state &&
        status.speed === lastAnchor.speed &&
        status.duration === lastAnchor.duration &&
        Math.abs(status.position - expected) < 250
      )
        return;
    }
    lastAnchor = { ...status, timestamp: now };
    pendingAnchor = lastAnchor;
    void flushAnchor();
  },
  async update(): Promise<void> {
    if ((!active && !starting) || !snapshot) return;
    const token = ++revision;
    const value = await snapshot();
    if (token !== revision || (!active && !starting)) return;
    await invoke("plugin:lyric-pip|update", pipContent(value, store.get("desktopLyric")));
  },
  async close(): Promise<void> {
    await invoke("plugin:lyric-pip|stop");
  },
  async toggle(): Promise<void> {
    if (starting) return;
    if (active) return mobileLyricPip.close();
    starting = true;
    try {
      listenersReady ??= (async () => {
        const visibility = await addPluginListener<{ active: boolean }>(
          "lyric-pip",
          "visibility",
          (event) => {
            active = event.active;
            if (!active) {
              revision++;
              pendingAnchor = undefined;
              lastAnchor = undefined;
            }
            visibilityListeners.forEach((listener) => listener(active));
          },
        );
        try {
          await addPluginListener<{ playing: boolean }>("lyric-pip", "playback", (event) => {
            playback?.(event.playing);
          });
        } catch (error) {
          await visibility.unregister();
          throw error;
        }
      })().catch((error: unknown) => {
        listenersReady = undefined;
        throw error;
      });
      await listenersReady;
      await mobileLyricPip.update();
      const value = await snapshot?.();
      if (!value?.track) throw new Error("请先选择并播放一首歌曲，再开启歌词小窗");
      await invoke("plugin:lyric-pip|sync", {
        position: value.position,
        duration: value.track.duration,
        playing: value.playing,
        speed: value.speed,
        timestamp: value.sendTimestamp,
      });
      await invoke("plugin:lyric-pip|start");
    } catch (error) {
      console.warn("[lyric-pip] 开启失败", error);
      toast.error(error instanceof Error ? error.message : String(error));
    } finally {
      starting = false;
    }
  },
};
