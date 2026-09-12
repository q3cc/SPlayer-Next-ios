import { getCurrentTime, getDuration, isPlaying } from "@/services/playback";

/**
 * 高频播放时间 composable
 *
 * 通过 RAF 循环读取非响应式时间源，不触发 Vue 响应式系统。
 * 支持显式 start/stop 控制，避免不需要时白跑 RAF。
 *
 * @param onTick 每帧回调，接收当前播放位置（毫秒，整数）和总时长（毫秒，整数）
 * @returns { start, stop } 手动控制 RAF 循环
 */
export const usePlaybackTime = (
  onTick: (currentMs: number, durationMs: number, playing: boolean) => void,
): { start: () => void; stop: () => void } => {
  let rafId: number | null = null;
  let running = false;

  const schedule = (): void => {
    if (running && !document.hidden && rafId === null) rafId = requestAnimationFrame(tick);
  };

  const tick = (): void => {
    rafId = null;
    if (!running || document.hidden) return;
    onTick(Math.round(getCurrentTime()), Math.round(getDuration()), isPlaying());
    schedule();
  };

  const start = (): void => {
    running = true;
    schedule();
  };

  const stop = (): void => {
    running = false;
    if (rafId !== null) {
      cancelAnimationFrame(rafId);
      rafId = null;
    }
  };

  const onVisibility = (): void => {
    if (document.hidden && rafId !== null) {
      cancelAnimationFrame(rafId);
      rafId = null;
    } else schedule();
  };
  document.addEventListener("visibilitychange", onVisibility);
  onUnmounted(() => {
    stop();
    document.removeEventListener("visibilitychange", onVisibility);
  });

  return { start, stop };
};
