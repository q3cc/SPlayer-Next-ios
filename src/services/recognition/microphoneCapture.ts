import { MICROPHONE_WORKLET_SOURCE } from "./microphoneCapture.worklet";

const TARGET_RATE = 8000;
const LEVEL_BLOCK = TARGET_RATE / 10;

export interface MicrophoneCaptureHandle {
  stop: () => Promise<Float32Array>;
  close: () => void;
}

/** 采集 8 kHz 单声道；授权失败、取消和初始化异常都会释放麦克风。 */
export const captureMicrophone = async (
  onLevel?: (level: number) => void,
  signal?: AbortSignal,
): Promise<MicrophoneCaptureHandle> => {
  signal?.throwIfAborted();
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
  });
  let ctx: AudioContext | undefined;
  let node: AudioWorkletNode | undefined;
  let source: MediaStreamAudioSourceNode | undefined;
  let output: GainNode | undefined;
  let closed = false;
  let flush: (() => void) | undefined;
  const chunks: Float32Array[] = [];
  let total = 0;
  const release = (): void => {
    if (closed) return;
    closed = true;
    signal?.removeEventListener("abort", release);
    flush?.();
    source?.disconnect();
    node?.disconnect();
    output?.disconnect();
    if (ctx) void ctx.close();
    stream.getTracks().forEach((track) => track.stop());
    chunks.length = 0;
  };
  signal?.addEventListener("abort", release, { once: true });
  try {
    signal?.throwIfAborted();
    ctx = new AudioContext();
    const url = URL.createObjectURL(
      new Blob([MICROPHONE_WORKLET_SOURCE], { type: "application/javascript" }),
    );
    try {
      await ctx.audioWorklet.addModule(url);
    } finally {
      URL.revokeObjectURL(url);
    }
    signal?.throwIfAborted();
    node = new AudioWorkletNode(ctx, "microphone-capture");
    source = ctx.createMediaStreamSource(stream);
    output = ctx.createGain();
    output.gain.value = 0;
    source.connect(node);
    node.connect(output);
    output.connect(ctx.destination);
    let blockEnergy = 0;
    let blockCount = 0;
    node.port.onmessage = (event: MessageEvent<{ type: string; pcm?: Float32Array }>) => {
      if (closed) return;
      const pcm = event.data?.pcm;
      if (pcm && total + pcm.length <= TARGET_RATE * 30) {
        chunks.push(pcm);
        total += pcm.length;
        for (const sample of pcm) {
          blockEnergy += sample * sample;
          blockCount++;
        }
        if (blockCount >= LEVEL_BLOCK) {
          onLevel?.(Math.sqrt(blockEnergy / blockCount));
          blockEnergy = 0;
          blockCount = 0;
        }
      }
      if (event.data.type === "flushed") flush?.();
    };
    await ctx.resume();
    signal?.throwIfAborted();
    return {
      stop: async () => {
        if (closed || signal?.aborted) return new Float32Array(0);
        await new Promise<void>((resolve) => {
          const timer = setTimeout(resolve, 1000);
          flush = () => {
            clearTimeout(timer);
            resolve();
          };
          node!.port.postMessage({ type: "flush" });
        });
        flush = undefined;
        const pcm = new Float32Array(total);
        let offset = 0;
        for (const chunk of chunks) {
          pcm.set(chunk, offset);
          offset += chunk.length;
        }
        chunks.length = 0;
        return signal?.aborted ? new Float32Array(0) : pcm;
      },
      close: release,
    };
  } catch (error) {
    release();
    throw error;
  }
};

/** 取消时立即结束等待，不遗留定时器和事件监听器。 */
export const waitCapture = (durationMs: number, signal: AbortSignal): Promise<void> =>
  new Promise((resolve) => {
    if (signal.aborted) {
      resolve();
      return;
    }
    const finish = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", finish);
      resolve();
    };
    const timer = setTimeout(finish, durationMs);
    signal.addEventListener("abort", finish, { once: true });
  });
