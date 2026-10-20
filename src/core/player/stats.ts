/**
 * 播放统计采集:累计每首歌的实际收听时长,结算后写入主进程 play_history 表
 *
 * 会话由两个 watcher 驱动:
 * - media.track 身份变化 → 结算旧会话、为新曲开会话
 * - status.state 进出 playing → 累计 / 暂停墙钟计时
 *
 * 单曲循环不切歌,由 events.ts 的 ended 分支显式调 onTrackEnded(true) 把每圈断成独立会话。
 * 墙钟用 Date.now() 差值,不依赖定时器与 position 事件,窗口隐藏时也准确。
 */

import type { Track } from "@shared/types/player";
import { useMediaStore } from "@/stores/media";
import { useStatusStore } from "@/stores/status";

/** 低于此收听时长不记录 */
const MIN_RECORD_MS = 5000;

interface Session {
  track: Track;
  /** 本次播放开始 unix ms */
  startedAt: number;
  /** 已累计的收听墙钟毫秒 */
  listenedMs: number;
  /** 进入 playing 的墙钟时刻 */
  playingSince: number | null;
}

let session: Session | null = null;
let installed = false;

/** 曲目身份标识 */
const trackKey = (track: Track): string => `${track.source}:${track.id}`;

/** 把进行中的 playing 区间结清进 listenedMs */
const settle = (): void => {
  if (!session || session.playingSince === null) return;
  session.listenedMs += Date.now() - session.playingSince;
  session.playingSince = null;
};

/** 为指定曲目开新会话 */
const begin = (track: Track, playing: boolean): void => {
  const now = Date.now();
  session = { track, startedAt: now, listenedMs: 0, playingSince: playing ? now : null };
};

/** 结算当前会话并落库 */
const finalize = (): void => {
  if (!session) return;
  settle();
  const { track, startedAt, listenedMs } = session;
  session = null;
  if (listenedMs < MIN_RECORD_MS) return;
  window.api.stats.recordPlay({ track, startedAt, listenedMs });
};

/**
 * 歌曲自然播完时调用
 * @param restart - 单曲循环:结算后立即为同一首开新会话,使每圈各成一行
 */
export const onTrackEnded = (restart: boolean): void => {
  finalize();
  if (!restart) return;
  const track = useMediaStore().track;
  if (track) begin(track, true);
};

/** 安装播放统计累加器 */
export const installPlayStats = (): void => {
  if (installed) return;
  installed = true;
  const media = useMediaStore();
  const status = useStatusStore();

  // 曲目身份变化时结算旧会话；同曲元数据补全时更新最终统计快照
  watch(
    () => media.track,
    (track) => {
      if (track && session && trackKey(track) === trackKey(session.track)) {
        session.track = track;
        return;
      }
      finalize();
      if (track) begin(track, status.state === "playing");
    },
  );

  // 播放态变化:在同一会话内累计 / 暂停计时
  watch(
    () => status.state,
    (state) => {
      if (!session) return;
      if (state === "playing") {
        if (session.playingSince === null) session.playingSince = Date.now();
      } else {
        settle();
      }
    },
  );

  // 退出前刷出最后一首
  window.addEventListener("beforeunload", finalize);
};
