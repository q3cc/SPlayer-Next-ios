import { afterEach, beforeEach, expect, it, vi } from "vitest";
const call = vi.hoisted(() => vi.fn());
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
