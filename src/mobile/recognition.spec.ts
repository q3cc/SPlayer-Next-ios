import { afterEach, beforeEach, expect, it, vi } from "vitest";
const call = vi.hoisted(() => vi.fn());
const native = vi.hoisted(() => vi.fn());
const listener = vi.hoisted(() => vi.fn());
const unregister = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke: native, addPluginListener: listener }));
vi.mock("./platform", () => ({ isIOS: true }));
vi.mock("./providers", () => ({ mobileProviders: { call } }));
import { mobileRecognition } from "./recognition";
let workers: MockWorker[] = [];
class MockWorker {
  onmessage?: (event: { data: { fingerprint?: string } }) => void;
  onerror?: () => void;
  terminate = vi.fn();
  postMessage = vi.fn();
  constructor() {
    workers.push(this);
  }
}
beforeEach(() => {
  workers = [];
  listener.mockResolvedValue({ unregister });
  vi.stubGlobal("Worker", MockWorker);
});
afterEach(async () => {
  await mobileRecognition.cancel();
  vi.unstubAllGlobals();
});
it("静音不启动指纹计算", async () => {
  const event = vi.fn();
  const off = mobileRecognition.onEvent(event);
  await mobileRecognition.submitPcm(new Float32Array(8000));
  expect(event).toHaveBeenLastCalledWith(
    expect.objectContaining({ error: expect.objectContaining({ code: "silent-input" }) }),
  );
  expect(workers).toHaveLength(0);
  off();
});
it("iOS 系统音源通过广播采集，再进入指纹计算", async () => {
  native.mockResolvedValue({ pcm: new Array(64000).fill(0.1) });
  const task = mobileRecognition.start({ source: "system", durationMs: 8000 });
  await vi.waitFor(() => expect(workers).toHaveLength(1));
  expect(native).toHaveBeenCalledWith("plugin:native-audio|recognition_start");
  await mobileRecognition.cancel();
  await task;
});

it("取消广播后不处理迟到的音频", async () => {
  let resolve!: (result: { pcm: number[] }) => void;
  native.mockImplementation((command: string) =>
    command.endsWith("recognition_start")
      ? new Promise((done) => {
          resolve = done;
        })
      : Promise.resolve(),
  );
  const task = mobileRecognition.start({ source: "system", durationMs: 8000 });
  await vi.waitFor(() => expect(resolve).toBeTypeOf("function"));
  await mobileRecognition.cancel();
  resolve({ pcm: new Array(64000).fill(0.1) });
  await task;
  expect(native).toHaveBeenCalledWith("plugin:native-audio|recognition_cancel");
  expect(workers).toHaveLength(0);
  expect(unregister).toHaveBeenCalledOnce();
});

it("系统确认前保持等待，收到广播启动事件后才显示采集", async () => {
  let started!: () => void;
  let reject!: (reason: string) => void;
  listener.mockImplementation(async (_plugin, _event, callback) => {
    started = callback;
    return { unregister };
  });
  native.mockImplementation((command: string) =>
    command.endsWith("recognition_start")
      ? new Promise((_resolve, fail) => {
          reject = fail;
        })
      : Promise.resolve(),
  );
  const event = vi.fn();
  const off = mobileRecognition.onEvent(event);
  const task = mobileRecognition.start({ source: "system", durationMs: 8000 });
  await vi.waitFor(() => expect(reject).toBeTypeOf("function"));
  expect(event).toHaveBeenLastCalledWith({ phase: "waiting" });
  started();
  expect(event).toHaveBeenLastCalledWith({ phase: "capturing" });
  reject("广播共享空间不可用");
  await task;
  expect(event).toHaveBeenLastCalledWith({
    phase: "error",
    error: {
      code: "capture-failed",
      message: "广播共享空间不可用",
    },
  });
  expect(unregister).toHaveBeenCalledOnce();
  off();
});
it("识曲输出候选并释放指纹 Worker", async () => {
  call.mockResolvedValue({
    ok: true,
    body: {
      code: 200,
      data: { result: [{ song: { id: 1, name: "音乐", artists: [{ name: "歌手" }] } }] },
    },
  });
  const event = vi.fn();
  const off = mobileRecognition.onEvent(event);
  const task = mobileRecognition.submitPcm(new Float32Array(8000).fill(0.1));
  await vi.waitFor(() => expect(workers).toHaveLength(1));
  workers[0].onmessage!({ data: { fingerprint: "test-fingerprint" } });
  await task;
  expect(workers[0].terminate).toHaveBeenCalledOnce();
  expect(call).toHaveBeenCalledWith("netease", "audio_match", {
    audioFP: "test-fingerprint",
    duration: 1,
  });
  expect(event).toHaveBeenLastCalledWith({
    phase: "done",
    candidates: [expect.objectContaining({ songId: "1" })],
  });
  off();
});
it("取消结算挂起任务且不再请求匹配", async () => {
  const task = mobileRecognition.submitPcm(new Float32Array(8000).fill(0.1));
  await vi.waitFor(() => expect(workers).toHaveLength(1));
  await mobileRecognition.cancel();
  await task;
  expect(workers[0].terminate).toHaveBeenCalledOnce();
  expect(call).not.toHaveBeenCalled();
});
