import type { RecognitionApi, RecognitionEvent } from "@shared/types/recognition";
import { mobileProviders } from "./providers";
import { addPluginListener, invoke } from "@tauri-apps/api/core";
import { isIOS } from "./platform";

const listeners = new Set<(event: RecognitionEvent) => void>();
let generation = 0;
let cancelFingerprint: (() => void) | undefined;
let capturingSystem = false;
const emit = (event: RecognitionEvent) => listeners.forEach((listener) => listener(event));

export const mobileRecognition: RecognitionApi = {
  isSupported: async () => isIOS,
  start: async ({ source }) => {
    const cancelled = mobileRecognition.cancel();
    const current = generation;
    await cancelled;
    if (current !== generation) return;
    if (!isIOS || source !== "system") {
      emit({ phase: "error", error: { code: "unsupported", message: "请使用麦克风识曲" } });
      return;
    }
    capturingSystem = true;
    emit({ phase: "waiting" });
    let subscription: Awaited<ReturnType<typeof addPluginListener>> | undefined;
    let step = "register-listener";
    try {
      console.info("[recognition] broadcast-request", {
        version: __APP_VERSION__,
        commit: __COMMIT_HASH__,
      });
      subscription = await addPluginListener("native-audio", "recognitionCaptureStarted", () => {
        if (current === generation) emit({ phase: "capturing" });
      });
      if (current !== generation) return;
      step = "open-broadcast";
      console.info("[recognition] open-broadcast");
      const { pcm } = await invoke<{ pcm: number[] }>("plugin:native-audio|recognition_start");
      if (current !== generation) return;
      capturingSystem = false;
      await mobileRecognition.submitPcm(new Float32Array(pcm));
    } catch (error) {
      if (current !== generation) return;
      // Tauri 的 reject 会返回普通对象，直接 String 会丢失原生错误信息。
      const detail =
        error && typeof error === "object"
          ? (error as { message?: unknown; error?: unknown; code?: unknown })
          : undefined;
      const message =
        [
          error instanceof Error ? error.message : undefined,
          typeof error === "string" ? error : undefined,
          detail?.message,
          detail?.error,
        ].find((value): value is string => typeof value === "string" && value.trim().length > 0) ??
        "无法开启屏幕广播，请导出本次诊断日志以检查具体原因";
      console.error("[recognition] broadcast-failed", { step, error });
      emit({ phase: "error", error: { code: "capture-failed", message } });
    } finally {
      await subscription?.unregister();
      if (current === generation) capturingSystem = false;
    }
  },
  cancel: async () => {
    generation++;
    cancelFingerprint?.();
    if (capturingSystem) {
      capturingSystem = false;
      await invoke("plugin:native-audio|recognition_cancel");
    }
  },
  submitPcm: async (pcm) => {
    const cancelled = mobileRecognition.cancel();
    const current = generation;
    await cancelled;
    if (current !== generation) return;
    if (!pcm.length || pcm.length > 8000 * 30 || !pcm.every(Number.isFinite)) {
      emit({ phase: "error", error: { code: "capture-failed", message: "录音数据无效" } });
      return;
    }
    const energy = pcm.reduce((sum, sample) => sum + sample * sample, 0) / pcm.length;
    if (energy < 0.000001) {
      emit({ phase: "error", error: { code: "silent-input", message: "未检测到声音" } });
      return;
    }
    let phase: "fingerprinting" | "matching" = "fingerprinting";
    try {
      emit({ phase });
      // 每次会话结束释放 WASM 内存，取消或重新识别不会保留旧 Worker。
      const fingerprint = await new Promise<string | null>((resolve, reject) => {
        const worker = new Worker(new URL("./recognition.worker.ts", import.meta.url), {
          type: "module",
        });
        const finish = () => {
          worker.terminate();
          clearTimeout(timeout);
          cancelFingerprint = undefined;
        };
        const timeout = setTimeout(() => {
          finish();
          reject(new Error("指纹计算超时"));
        }, 30000);
        cancelFingerprint = () => {
          finish();
          resolve(null);
        };
        worker.onerror = () => {
          finish();
          reject(new Error("无法加载音频指纹库"));
        };
        worker.onmessage = (event: MessageEvent<{ fingerprint?: string; error?: string }>) => {
          finish();
          if (event.data.fingerprint) resolve(event.data.fingerprint);
          else reject(new Error(event.data.error || "音频指纹为空"));
        };
        const copy = pcm.slice();
        worker.postMessage(copy, [copy.buffer]);
      });
      if (current !== generation || !fingerprint) return;
      phase = "matching";
      emit({ phase });
      const response = await mobileProviders.call("netease", "audio_match", {
        audioFP: fingerprint,
        duration: pcm.length / 8000,
      });
      if (current !== generation) return;
      const body = response.body as {
        code?: number;
        data?: {
          result?: Array<{
            startTime?: number;
            song?: {
              id: number;
              name: string;
              artists: { name: string }[];
              album?: { name: string; picUrl?: string };
            };
          }>;
        };
      };
      if (!response.ok || body?.code !== 200) throw new Error("识曲服务请求失败");
      const candidates = (body.data?.result ?? [])
        .filter((item) => item.song)
        .slice(0, 3)
        .map(({ song, startTime }) => ({
          songId: String(song!.id),
          title: song!.name,
          artists: song!.artists.map((artist) => artist.name),
          album: song!.album?.name,
          cover: song!.album?.picUrl,
          startTime,
        }));
      emit({ phase: "done", candidates });
    } catch (error) {
      if (current === generation)
        emit({
          phase: "error",
          error: {
            code: phase === "fingerprinting" ? "afp-unavailable" : "network",
            message: String(error),
          },
        });
    }
  },
  onEvent: (listener) => {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  },
};
