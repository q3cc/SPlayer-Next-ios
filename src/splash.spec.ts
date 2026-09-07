import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { dismissSplash } from "./splash";

beforeEach(() => {
  vi.useFakeTimers();
  document.body.innerHTML =
    '<div id="app-loading"><div class="splash-name">SPlayer Next</div><div class="splash-dots"><i /></div></div>';
  vi.spyOn(window, "matchMedia").mockReturnValue({ matches: false } as MediaQueryList);
  vi.spyOn(performance, "now").mockReturnValue(0);
});
afterEach(() => {
  vi.useRealTimers();
  document.body.innerHTML = "";
});

it("原版加载页至少展示 1100ms，不等待无限循环圆点", async () => {
  const task = dismissSplash();
  await vi.advanceTimersByTimeAsync(1099);
  expect(document.getElementById("app-loading")?.classList.contains("hidden")).toBe(false);
  await vi.advanceTimersByTimeAsync(1);
  expect(document.getElementById("app-loading")?.classList.contains("hidden")).toBe(true);
  await vi.advanceTimersByTimeAsync(350);
  await task;
  expect(document.getElementById("app-loading")).toBeNull();
  expect(vi.getTimerCount()).toBe(0);
});
it("慢启动不再额外等待，淡出事件缺失也会清理", async () => {
  vi.mocked(performance.now).mockReturnValue(2000);
  const task = dismissSplash();
  await vi.advanceTimersByTimeAsync(0);
  expect(document.getElementById("app-loading")?.classList.contains("hidden")).toBe(true);
  await vi.advanceTimersByTimeAsync(350);
  await task;
  expect(document.getElementById("app-loading")).toBeNull();
});
it("减少动态效果时不等待动画", async () => {
  vi.mocked(window.matchMedia).mockReturnValue({ matches: true } as MediaQueryList);
  const task = dismissSplash();
  expect(document.getElementById("app-loading")?.classList.contains("hidden")).toBe(true);
  await vi.runAllTimersAsync();
  await task;
});
it("启动失败时保留错误和重试入口", async () => {
  document.getElementById("app-loading")!.classList.add("boot-failed");
  const task = dismissSplash();
  await vi.runAllTimersAsync();
  await task;
  expect(document.getElementById("app-loading")?.classList.contains("hidden")).toBe(false);
});
