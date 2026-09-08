import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { dismissSplash } from "./splash";

beforeEach(() => {
  vi.useFakeTimers();
  document.body.innerHTML =
    '<div id="app-loading"><svg class="splash-next"><path class="letter" /></svg></div>';
  vi.spyOn(window, "matchMedia").mockReturnValue({ matches: false } as MediaQueryList);
  window.__splashStart = performance.now();
});
afterEach(() => {
  vi.useRealTimers();
  document.body.innerHTML = "";
  delete window.__splashStart;
});

const animate = (finished: Promise<unknown>): void => {
  Object.defineProperty(document.querySelector(".letter"), "getAnimations", {
    value: () => [{ finished }],
  });
};

it("快速启动不会在 150ms 截断 Next，最后一笔结束才淡出", async () => {
  let complete!: () => void;
  animate(
    new Promise<void>((resolve) => {
      complete = resolve;
    }),
  );
  const task = dismissSplash();
  await vi.advanceTimersByTimeAsync(150);
  expect(document.getElementById("app-loading")?.classList.contains("hidden")).toBe(false);
  complete();
  await vi.advanceTimersByTimeAsync(0);
  expect(document.getElementById("app-loading")?.classList.contains("hidden")).toBe(true);
  await vi.advanceTimersByTimeAsync(350);
  await task;
  expect(document.getElementById("app-loading")).toBeNull();
  expect(vi.getTimerCount()).toBe(0);
});

it("初始化较慢且动画已结束时不再额外等两秒", async () => {
  animate(Promise.resolve());
  const task = dismissSplash();
  await vi.advanceTimersByTimeAsync(0);
  expect(document.getElementById("app-loading")?.classList.contains("hidden")).toBe(true);
  await vi.advanceTimersByTimeAsync(350);
  await task;
});

it("后台暂停动画或丢失淡出事件时仍能退出", async () => {
  animate(new Promise(() => undefined));
  const task = dismissSplash();
  await vi.advanceTimersByTimeAsync(2850);
  await task;
  expect(document.getElementById("app-loading")).toBeNull();
});

it("不支持动画查询时仍保留完整笔画的展示时间", async () => {
  Object.defineProperty(document.querySelector(".letter"), "getAnimations", { value: undefined });
  const task = dismissSplash();
  await vi.advanceTimersByTimeAsync(150);
  expect(document.getElementById("app-loading")?.classList.contains("hidden")).toBe(false);
  await vi.runAllTimersAsync();
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
  animate(Promise.resolve());
  document.getElementById("app-loading")!.classList.add("boot-failed");
  await dismissSplash();
  expect(document.getElementById("app-loading")?.classList.contains("hidden")).toBe(false);
});
