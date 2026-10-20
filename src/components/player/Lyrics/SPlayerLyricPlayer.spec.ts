import { expect, it, vi } from "vitest";
import { SPlayerLyricPlayer } from "./SPlayerLyricPlayer";

class ScrollTestPlayer extends SPlayerLyricPlayer {
  get scrollPosition(): number {
    return this.scrollState.scrollOffset;
  }

  get browsingLyrics(): boolean {
    return this.scrollState.isScrolled;
  }
}

const createScrollPlayer = (): ScrollTestPlayer => {
  const player = new ScrollTestPlayer();
  document.body.appendChild(player.getElement());
  player.size[0] = 400;
  player.size[1] = 500;
  const log = vi.spyOn(console, "log").mockImplementation(() => {});
  try {
    player.setLyricLines(
      Array.from({ length: 8 }, (_, index) => ({
        startTime: index * 5000,
        endTime: index * 5000 + 4000,
        words: [
          {
            startTime: index * 5000,
            endTime: index * 5000 + 4000,
            word: `第 ${index + 1} 句`,
          },
        ],
        translatedLyric: "",
        romanLyric: "",
        isBG: false,
        isDuet: false,
      })),
      1000,
    );
  } finally {
    log.mockRestore();
  }
  for (const group of player.currentLyricGroups) player.lyricGroupSize.set(group, [400, 80]);
  player.setCurrentTime(1000, true);
  void player.calcLayout(true, true);
  return player;
};

it("滚轮停止后保持浏览位置五秒，播放推进时不带动视图", () => {
  const player = createScrollPlayer();
  vi.useFakeTimers();
  try {
    const element = player.getElement();
    element.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true, cancelable: true }));
    const browsingTop = player.currentLyricGroups[0].top;
    expect(player.scrollPosition).toBeGreaterThan(0);

    vi.advanceTimersByTime(3000);
    player.setCurrentTime(6000);
    expect(player.currentLyricGroups[0].top).toBe(browsingTop);
    element.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true, cancelable: true }));
    const lastScrollTop = player.currentLyricGroups[0].top;

    vi.advanceTimersByTime(4999);
    expect(player.browsingLyrics).toBe(true);
    expect(player.currentLyricGroups[0].top).toBe(lastScrollTop);
    vi.advanceTimersByTime(1);
    expect(player.browsingLyrics).toBe(false);
    expect(player.scrollPosition).toBe(0);
    expect(player.currentLyricGroups[0].top).not.toBe(lastScrollTop);
  } finally {
    player.dispose();
    vi.useRealTimers();
  }
});

it("触摸持续期间不回位，手势结束后才开始等待", () => {
  const player = createScrollPlayer();
  vi.useFakeTimers();
  const frames: FrameRequestCallback[] = [];
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
    frames.push(callback);
    return frames.length;
  });
  const touch = (type: string, screenY: number) => {
    const event = new Event(type, { bubbles: true, cancelable: true });
    Object.defineProperty(event, "touches", { value: [{ screenX: 20, screenY }] });
    Object.defineProperty(event, "changedTouches", {
      value: [{ screenX: 20, screenY, clientX: 20, clientY: screenY }],
    });
    player.getElement().dispatchEvent(event);
  };
  try {
    touch("touchstart", 100);
    vi.advanceTimersByTime(1000);
    touch("touchmove", 80);
    const browsingTop = player.currentLyricGroups[0].top;
    vi.advanceTimersByTime(6000);
    expect(player.browsingLyrics).toBe(true);
    expect(player.currentLyricGroups[0].top).toBe(browsingTop);

    frames.length = 0;
    touch("touchend", 80);
    expect(frames.length).toBeGreaterThan(0);
    vi.advanceTimersByTime(16);
    frames.shift()!(performance.now());
    vi.advanceTimersByTime(4999);
    expect(player.browsingLyrics).toBe(true);
    vi.advanceTimersByTime(1);
    expect(player.browsingLyrics).toBe(false);
    expect(player.currentLyricGroups[0].top).not.toBe(browsingTop);
  } finally {
    player.dispose();
    vi.unstubAllGlobals();
    vi.useRealTimers();
  }
});

it("点选歌词跳转立即回位，卸载后不再执行延时回位", () => {
  const player = createScrollPlayer();
  vi.useFakeTimers();
  try {
    const element = player.getElement();
    element.dispatchEvent(new WheelEvent("wheel", { deltaY: 80, bubbles: true, cancelable: true }));
    player.setCurrentTime(11000, true);
    expect(player.browsingLyrics).toBe(false);
    expect(player.scrollPosition).toBe(0);

    element.dispatchEvent(new WheelEvent("wheel", { deltaY: 80, bubbles: true, cancelable: true }));
    const layout = vi.spyOn(player, "calcLayout");
    player.dispose();
    vi.advanceTimersByTime(6000);
    expect(layout).not.toHaveBeenCalled();
  } finally {
    vi.useRealTimers();
  }
});

it("前奏圆点在播放和暂停时都跟随手动滚动，滚动不重置动画", async () => {
  const player = new SPlayerLyricPlayer();
  document.body.appendChild(player.getElement());
  const log = vi.spyOn(console, "log").mockImplementation(() => {});
  try {
    player.setLyricLines(
      [
        {
          startTime: 10000,
          endTime: 14000,
          words: [{ startTime: 10000, endTime: 14000, word: "第一句" }],
          translatedLyric: "",
          romanLyric: "",
          isBG: false,
          isDuet: false,
        },
        {
          startTime: 15000,
          endTime: 19000,
          words: [{ startTime: 15000, endTime: 19000, word: "第二句" }],
          translatedLyric: "",
          romanLyric: "",
          isBG: false,
          isDuet: false,
        },
      ],
      3000,
    );
  } finally {
    log.mockRestore();
  }
  try {
    player.setCurrentTime(3000, true);
    await player.calcLayout(true, true);
    player.resume();
    player.update(1500);
    const dots = player.getElement().querySelector<HTMLElement>("[class*='interludeDots']")!;
    expect(dots.className).toContain("enabled");
    const firstDot = dots.firstElementChild as HTMLElement;
    const visibleOpacity = Number(firstDot.style.opacity);
    expect(visibleOpacity).toBeGreaterThan(0);

    const playingTransform = dots.style.transform;
    player
      .getElement()
      .dispatchEvent(new WheelEvent("wheel", { deltaY: 10, bubbles: true, cancelable: true }));
    player.update(0);
    expect(dots.style.transform).not.toBe(playingTransform);
    expect(Number(firstDot.style.opacity)).toBeGreaterThan(0);

    player.pause();
    const pausedTransform = dots.style.transform;
    player
      .getElement()
      .dispatchEvent(new WheelEvent("wheel", { deltaY: -10, bubbles: true, cancelable: true }));
    expect(dots.style.transform).not.toBe(pausedTransform);
    expect(Number(firstDot.style.opacity)).toBeGreaterThan(0);

    const movedTransform = dots.style.transform;
    player.resume();
    expect(dots.style.transform).toBe(movedTransform);

    const touch = (type: string, screenY: number) => {
      const event = new Event(type, { bubbles: true, cancelable: true });
      Object.defineProperty(event, "touches", { value: [{ screenX: 20, screenY }] });
      player.getElement().dispatchEvent(event);
    };
    touch("touchstart", 100);
    touch("touchmove", 85);
    expect(dots.style.transform).not.toBe(movedTransform);
    expect(Number(firstDot.style.opacity)).toBeGreaterThan(0);

    player.setCurrentTime(5000, true);
    player.update(0);
    expect(Number(firstDot.style.opacity)).toBe(0);
  } finally {
    player.dispose();
  }
});
