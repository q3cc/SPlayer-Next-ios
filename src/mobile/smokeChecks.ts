import { invoke, isTauri } from "@tauri-apps/api/core";
import type { SystemMediaMetadata } from "@shared/types/player";

/** 原生同步和 seek 都是异步的，等待真实系统结果，不检查浏览器占位状态。 */
export const waitForMediaMetadata = async (expected: SystemMediaMetadata): Promise<void> => {
  let actual: SystemMediaMetadata = { title: "", artist: "" };
  for (let attempt = 0; attempt < 50; attempt++) {
    actual = isTauri()
      ? (await invoke<{ nowPlaying: SystemMediaMetadata }>("plugin:native-audio|status")).nowPlaying
      : {
          title: navigator.mediaSession?.metadata?.title ?? "",
          artist: navigator.mediaSession?.metadata?.artist ?? "",
        };
    if (actual?.title === expected.title && actual.artist === expected.artist) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(
    `system media metadata mismatch: expected=${JSON.stringify(expected)}, actual=${JSON.stringify(actual)}`,
  );
};

/** 一项失败仍执行后续检查，保留具体原因而不是让整条测试链提前退出。 */
export const runSmokeChecks = async (
  checks: { name: string; run: () => Promise<void> }[],
  report: (stage: string) => void,
): Promise<boolean> => {
  let passed = true;
  for (const check of checks) {
    try {
      await check.run();
      report(`smoke-${check.name}-ready`);
    } catch (error) {
      passed = false;
      const message = error instanceof Error ? error.message : String(error);
      report(`smoke-${check.name}-failed:${message.replace(/[\r\n]/g, " ").slice(0, 500)}`);
    }
  }
  return passed;
};
