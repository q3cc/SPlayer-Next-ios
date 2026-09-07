import { afterEach, beforeEach, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ invoke: vi.fn(), isTauri: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => mocks);
import { runSmokeChecks, waitForMediaMetadata } from "./smokeChecks";

beforeEach(() => {
  vi.useFakeTimers();
  mocks.invoke.mockReset();
  mocks.isTauri.mockReturnValue(true);
});
afterEach(() => vi.useRealTimers());

it("原生模式等待系统媒体信息，不读浏览器的旧卡片", async () => {
  const expected = { title: "测试动态歌词", artist: "smoke - Unknown Artist" };
  mocks.invoke
    .mockResolvedValueOnce({ nowPlaying: { title: "smoke", artist: "Unknown Artist" } })
    .mockResolvedValue({ nowPlaying: expected });
  const task = waitForMediaMetadata(expected);
  await vi.runAllTimersAsync();
  await task;
  expect(mocks.invoke).toHaveBeenCalledTimes(2);
  expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:native-audio|status");
});
it("系统信息确实未更新时仍失败，并报告实际和预期值", async () => {
  mocks.invoke.mockResolvedValue({ nowPlaying: { title: "old", artist: "old artist" } });
  const failed = expect(waitForMediaMetadata({ title: "new", artist: "artist" })).rejects.toThrow(
    'actual={"title":"old","artist":"old artist"}',
  );
  await vi.runAllTimersAsync();
  await failed;
});
it("本地检查失败不跳过二维码或首页准备，整体仍标为失败", async () => {
  const report = vi.fn();
  const qr = vi.fn().mockResolvedValue(undefined);
  const home = vi.fn().mockResolvedValue(undefined);
  expect(
    await runSmokeChecks(
      [
        {
          name: "local-media",
          run: async () => {
            throw new Error("metadata mismatch");
          },
        },
        { name: "qr-login", run: qr },
        { name: "prepare-home", run: home },
      ],
      report,
    ),
  ).toBe(false);
  expect(qr).toHaveBeenCalledOnce();
  expect(home).toHaveBeenCalledOnce();
  expect(report.mock.calls.map(([value]) => value)).toEqual([
    "smoke-local-media-failed:metadata mismatch",
    "smoke-qr-login-ready",
    "smoke-prepare-home-ready",
  ]);
});
it("所有检查通过才返回通过", async () => {
  expect(await runSmokeChecks([{ name: "test", run: async () => undefined }], vi.fn())).toBe(true);
});
