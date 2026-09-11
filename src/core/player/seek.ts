import { useStatusStore } from "@/stores/status";
import * as playback from "@/services/playback";

let seekTarget: number | null = null;
let generation = 0;

/** 切歌、接管原生播放或跳转失败时，清除旧请求与插值等待。 */
export const resetSeek = (): void => {
  generation++;
  seekTarget = null;
  playback.setSeeking(false);
};

/** 等待引擎到达目标附近，避免旧进度让拖动后的滑块回跳。 */
export const hasReachedSeekTarget = (position: number): boolean => {
  if (seekTarget === null) return true;
  if (Math.abs(position - seekTarget) < 1000) {
    seekTarget = null;
    playback.setSeeking(false);
    return true;
  }
  return false;
};

/** 当前是否等待跳转位置确认。 */
export const isSeeking = (): boolean => seekTarget !== null;

/**
 * 跳转到指定播放位置，失败时恢复跳转前的位置。
 * @param posMs - 目标位置（毫秒）
 */
export const seek = async (posMs: number): Promise<void> => {
  const status = useStatusStore();
  if (status.trackLoading || !Number.isFinite(posMs)) return;
  const target = Math.max(0, status.duration > 0 ? Math.min(posMs, status.duration) : posMs);
  const previous = playback.getCurrentTime();
  const token = ++generation;
  playback.setSeeking(true);
  status.position = playback.setCurrentTime(target, { force: true });
  seekTarget = target;

  const result = await window.api.player.seek(target).catch((error: unknown) => ({
    success: false,
    error: String(error),
  }));
  // 切歌和后发跳转拥有自己的位置，不能被旧请求的返回值回滚。
  if (token !== generation) return;
  if (!result.success) {
    const actual = await window.api.player.getStatus().then(
      ({ data }) => data?.position,
      () => undefined,
    );
    if (token !== generation) return;
    resetSeek();
    status.position = playback.setCurrentTime(actual ?? previous, { force: true });
    console.warn("[player] 跳转失败", result.error);
  }
};

/**
 * 标记一次非渲染层发起的跳转。
 * @param posMs - 目标位置（毫秒）
 */
export const markSeek = (posMs: number): void => {
  const status = useStatusStore();
  if (status.trackLoading) return;
  generation++;
  playback.setSeeking(true);
  status.position = playback.setCurrentTime(posMs, { force: true });
  seekTarget = posMs;
};
