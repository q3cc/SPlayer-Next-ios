import { beforeEach, expect, it, vi } from "vitest";
import * as playback from "@/services/playback";
import { hasReachedSeekTarget, isSeeking, markSeek, resetSeek, seek } from "./seek";

const mocks = vi.hoisted(() => ({
  status: { position: 1000, duration: 200000, trackLoading: false },
  seek: vi.fn(),
  getStatus: vi.fn(),
}));
vi.mock("@/stores/status", () => ({ useStatusStore: () => mocks.status }));

beforeEach(() => {
  resetSeek();
  playback.reset();
  playback.setDuration(200000);
  playback.setCurrentTime(1000, { force: true });
  Object.assign(mocks.status, { position: 1000, duration: 200000, trackLoading: false });
  mocks.seek.mockReset().mockResolvedValue({ success: true });
  mocks.getStatus.mockReset().mockResolvedValue({ success: true, data: { position: 1000 } });
  Object.defineProperty(window, "api", {
    configurable: true,
    value: { player: { seek: mocks.seek, getStatus: mocks.getStatus } },
  });
});

it("连续跳转都失败时恢复引擎实际位置，不保留上一次乐观位置", async () => {
  vi.spyOn(console, "warn").mockImplementation(() => {});
  let fail!: (value: { success: boolean }) => void;
  mocks.seek.mockImplementationOnce(() => new Promise((resolve) => (fail = resolve)));
  const first = seek(30000);
  mocks.seek.mockResolvedValue({ success: false });
  await seek(65000);
  fail({ success: false });
  await first;
  expect(mocks.status.position).toBe(1000);
  expect(isSeeking()).toBe(false);
});

it("失败后的状态查询晚返回，也不能覆盖新跳转", async () => {
  let finish!: (value: { success: boolean; data: { position: number } }) => void;
  mocks.getStatus.mockImplementationOnce(() => new Promise((resolve) => (finish = resolve)));
  mocks.seek.mockResolvedValueOnce({ success: false });
  const failed = seek(30000);
  await vi.waitFor(() => expect(mocks.getStatus).toHaveBeenCalled());
  await seek(65000);
  finish({ success: true, data: { position: 1000 } });
  await failed;
  expect(mocks.status.position).toBe(65000);
  expect(isSeeking()).toBe(true);
});

it("引擎状态也读取失败时，仍解除等待并保留跳转前进度", async () => {
  vi.spyOn(console, "warn").mockImplementation(() => {});
  mocks.seek.mockResolvedValue({ success: false });
  mocks.getStatus.mockRejectedValue(new Error("连接已断开"));
  await seek(65000);
  expect(mocks.status.position).toBe(1000);
  expect(isSeeking()).toBe(false);
});

it.each([false, true])("跳转失败后解除等待并恢复正常进度，异常抛出：%s", async (throws) => {
  vi.spyOn(console, "warn").mockImplementation(() => {});
  if (throws) mocks.seek.mockRejectedValue(new Error("加载未完成"));
  else mocks.seek.mockResolvedValue({ success: false, error: "加载未完成" });
  await seek(65000);
  expect(isSeeking()).toBe(false);
  expect(mocks.status.position).toBe(1000);
  expect(playback.getCurrentTime()).toBe(1000);
  expect(hasReachedSeekTarget(1200)).toBe(true);
});

it("成功跳转继续过滤旧位置，收到目标附近的位置后解除等待", async () => {
  await seek(65000);
  expect(isSeeking()).toBe(true);
  expect(hasReachedSeekTarget(1000)).toBe(false);
  expect(hasReachedSeekTarget(65200)).toBe(true);
  expect(isSeeking()).toBe(false);
});

it("试听音源的恢复位置按实际时长截断，不等待永远到不了的旧位置", async () => {
  mocks.status.duration = 30000;
  await seek(65000);
  expect(mocks.seek).toHaveBeenCalledWith(30000);
  expect(mocks.status.position).toBe(30000);
  expect(hasReachedSeekTarget(29900)).toBe(true);
});

it("较早的跳转失败不能回滚较新的跳转", async () => {
  let fail!: (value: { success: boolean }) => void;
  mocks.seek.mockImplementationOnce(() => new Promise((resolve) => (fail = resolve)));
  const first = seek(30000);
  await seek(65000);
  fail({ success: false });
  await first;
  expect(mocks.status.position).toBe(65000);
  expect(isSeeking()).toBe(true);
  expect(hasReachedSeekTarget(65000)).toBe(true);
});

it("切歌清除等待后，旧跳转失败不能覆盖新歌的位置", async () => {
  let fail!: (value: { success: boolean }) => void;
  mocks.seek.mockImplementationOnce(() => new Promise((resolve) => (fail = resolve)));
  const pending = seek(30000);
  resetSeek();
  mocks.status.position = 0;
  playback.setCurrentTime(0, { force: true });
  fail({ success: false });
  await pending;
  expect(mocks.status.position).toBe(0);
  expect(isSeeking()).toBe(false);
});

it("加载期间忽略拖动和外部跳转通知", async () => {
  mocks.status.trackLoading = true;
  await seek(30000);
  markSeek(40000);
  expect(mocks.seek).not.toHaveBeenCalled();
  expect(isSeeking()).toBe(false);
  expect(mocks.status.position).toBe(1000);
});
