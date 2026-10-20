import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { captureMicrophone, waitCapture } from "./microphoneCapture";

const stop = vi.fn();
const close = vi.fn();
const addModule = vi.fn();
const getUserMedia = vi.fn();
let port: { onmessage?: (event: { data: object }) => void; postMessage: ReturnType<typeof vi.fn> };
class Context {
  audioWorklet = { addModule };
  destination = {};
  close = close;
  resume = vi.fn().mockResolvedValue(undefined);
  createMediaStreamSource = () => ({ connect: vi.fn(), disconnect: vi.fn() });
  createGain = () => ({ gain: { value: 1 }, connect: vi.fn(), disconnect: vi.fn() });
}
class Worklet {
  port = port;
  connect = vi.fn();
  disconnect = vi.fn();
}
beforeEach(() => {
  vi.clearAllMocks();
  addModule.mockResolvedValue(undefined);
  close.mockResolvedValue(undefined);
  getUserMedia.mockResolvedValue({ getTracks: () => [{ stop }] });
  vi.stubGlobal("navigator", { mediaDevices: { getUserMedia } });
  vi.stubGlobal("AudioContext", Context);
  vi.stubGlobal("AudioWorkletNode", Worklet);
  vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:worklet");
  vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  port = { postMessage: vi.fn() };
});
afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});
it("工作线程初始化失败释放麦克风与音频上下文", async () => {
  addModule.mockRejectedValueOnce(new Error("failed"));
  await expect(captureMicrophone()).rejects.toThrow("failed");
  expect(stop).toHaveBeenCalledOnce();
  expect(close).toHaveBeenCalledOnce();
  expect(URL.revokeObjectURL).toHaveBeenCalledWith("blob:worklet");
});
it("授权期间取消，授权返回后立即释放媒体流", async () => {
  const controller = new AbortController();
  let grant!: (value: object) => void;
  getUserMedia.mockReturnValueOnce(
    new Promise((resolve) => {
      grant = resolve;
    }),
  );
  const task = captureMicrophone(undefined, controller.signal);
  controller.abort();
  grant({ getTracks: () => [{ stop }] });
  await expect(task).rejects.toThrow();
  expect(stop).toHaveBeenCalledOnce();
  expect(addModule).not.toHaveBeenCalled();
});
it("停止等待最后一个 PCM 块，释放只执行一次", async () => {
  const handle = await captureMicrophone();
  port.onmessage!({ data: { type: "chunk", pcm: new Float32Array([0.1]) } });
  const result = handle.stop();
  port.onmessage!({ data: { type: "chunk", pcm: new Float32Array([0.2]) } });
  port.onmessage!({ data: { type: "flushed" } });
  expect((await result).length).toBe(2);
  handle.close();
  handle.close();
  expect(stop).toHaveBeenCalledOnce();
});
it("取消结束等待并清理定时器", async () => {
  vi.useFakeTimers();
  const controller = new AbortController();
  const waiting = waitCapture(8000, controller.signal);
  controller.abort();
  await waiting;
  expect(vi.getTimerCount()).toBe(0);
});
