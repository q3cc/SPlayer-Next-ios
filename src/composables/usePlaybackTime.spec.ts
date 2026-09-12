import { mount } from "@vue/test-utils";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { usePlaybackTime } from "./usePlaybackTime";

vi.mock("@/services/playback", () => ({
  getCurrentTime: () => 1234,
  getDuration: () => 9000,
  isPlaying: () => true,
}));
let hidden = false;
let nextId = 0;
const frames = new Map<number, FrameRequestCallback>();
const wrappers: ReturnType<typeof mount>[] = [];
const tick = () => {
  const callbacks = [...frames.values()];
  frames.clear();
  callbacks.forEach((callback) => callback(0));
};
beforeEach(() => {
  hidden = false;
  frames.clear();
  vi.spyOn(document, "hidden", "get").mockImplementation(() => hidden);
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
    frames.set(++nextId, callback);
    return nextId;
  });
  vi.stubGlobal("cancelAnimationFrame", (id: number) => frames.delete(id));
});
afterEach(() => {
  wrappers.splice(0).forEach((wrapper) => wrapper.unmount());
  vi.unstubAllGlobals();
});
const create = (callback: () => void) => {
  let clock!: ReturnType<typeof usePlaybackTime>;
  wrappers.push(
    mount({
      setup() {
        clock = usePlaybackTime(callback);
        return () => null;
      },
    }),
  );
  return clock;
};
it("隐藏时取消帧，恢复后只保留一个循环", () => {
  const callback = vi.fn();
  const clock = create(callback);
  clock.start();
  clock.start();
  expect(frames.size).toBe(1);
  hidden = true;
  document.dispatchEvent(new Event("visibilitychange"));
  expect(frames.size).toBe(0);
  hidden = false;
  document.dispatchEvent(new Event("visibilitychange"));
  tick();
  expect(callback).toHaveBeenCalledWith(1234, 9000, true);
  expect(frames.size).toBe(1);
});
it("回调内停止不会重新订阅帧", () => {
  const clock = create(() => clock.stop());
  clock.start();
  tick();
  expect(frames.size).toBe(0);
});
it("隐藏期间停止后不自动恢复，卸载后不保留监听", () => {
  const clock = create(vi.fn());
  hidden = true;
  clock.start();
  clock.stop();
  hidden = false;
  document.dispatchEvent(new Event("visibilitychange"));
  expect(frames.size).toBe(0);
  clock.start();
  wrappers[0].unmount();
  wrappers.length = 0;
  document.dispatchEvent(new Event("visibilitychange"));
  expect(frames.size).toBe(0);
});
