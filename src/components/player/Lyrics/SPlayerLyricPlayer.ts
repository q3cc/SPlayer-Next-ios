import { LyricPlayer } from "@applemusic-like-lyrics/core";

const SCROLL_RESUME_DELAY_MS = 5000;

/** AMLL 滚动会重启间奏动画，暂停时也不更新圆点位置，在此保持视觉连续。 */
export class SPlayerLyricPlayer extends LyricPlayer {
  private interludeEndTime?: number;
  private scrollResumeTimer?: ReturnType<typeof setTimeout>;
  private touchScrolling = false;
  private readonly onTouchStart = () => {
    if (!this.scrollState.allowScroll) return;
    this.touchScrolling = true;
    this.clearScrollResumeTimer();
  };
  private readonly onTouchEnd = () => {
    if (!this.scrollState.allowScroll) this.touchScrolling = false;
  };
  private readonly onTouchCancel = () => {
    this.touchScrolling = false;
    this.scrollState.isUserScrolling = false;
    if (this.scrollState.isScrolled) this.scheduleScrollResume();
  };

  constructor() {
    super();
    // Core 的滚动回调是普通实例方法，但类型声明为 private；接管其计时以等待惯性结束。
    const scrollHandlers = this as unknown as {
      beginScrollHandler: () => boolean;
      endScrollHandler: () => void;
    };
    scrollHandlers.beginScrollHandler = () => {
      if (!this.scrollState.allowScroll) return false;
      this.scrollState.isScrolled = true;
      if (this.touchScrolling) this.clearScrollResumeTimer();
      else this.scheduleScrollResume();
      return true;
    };
    scrollHandlers.endScrollHandler = () => {
      this.touchScrolling = false;
      if (this.scrollState.isScrolled) this.scheduleScrollResume();
    };
    const element = this.getElement();
    element.addEventListener("touchstart", this.onTouchStart, { capture: true });
    element.addEventListener("touchend", this.onTouchEnd, { capture: true });
    element.addEventListener("touchcancel", this.onTouchCancel, { capture: true });

    const dots = this.interludeDots;
    const setInterlude = dots.setInterlude.bind(dots);
    dots.setInterlude = (interlude) => {
      if (interlude && interlude[1] === this.interludeEndTime) return;
      this.interludeEndTime = interlude?.[1];
      setInterlude(interlude);
    };
    const setTransform = dots.setTransform.bind(dots);
    dots.setTransform = (left, top) => {
      setTransform(left, top);
      if (this.getIsPlaying() || left === undefined || top === undefined) return;
      const element = dots.getElement();
      const scale = element.style.transform.match(/\bscale\([^)]*\)/)?.[0];
      element.style.transform = `translate(${left.toFixed(2)}px, ${top.toFixed(2)}px)${scale ? ` ${scale}` : ""}`;
    };
  }

  private clearScrollResumeTimer(): void {
    clearTimeout(this.scrollResumeTimer);
    this.scrollResumeTimer = undefined;
  }

  private scheduleScrollResume(): void {
    this.clearScrollResumeTimer();
    this.scrollResumeTimer = setTimeout(() => {
      this.resetScroll();
      void this.calcLayout();
    }, SCROLL_RESUME_DELAY_MS);
  }

  override resetScroll(): void {
    this.clearScrollResumeTimer();
    super.resetScroll();
  }

  override setCurrentTime(time: number, isSeek = false): void {
    const previousTop =
      !isSeek && this.scrollState.isScrolled ? this.currentLyricGroups[0]?.top : undefined;
    if (isSeek) this.interludeEndTime = undefined;
    super.setCurrentTime(time, isSeek);
    const currentTop = this.currentLyricGroups[0]?.top;
    if (previousTop !== undefined && currentTop !== undefined && currentTop !== previousTop) {
      this.scrollState.scrollOffset += currentTop - previousTop;
      void this.calcLayout();
    }
  }

  override dispose(): void {
    this.clearScrollResumeTimer();
    const element = this.getElement();
    element.removeEventListener("touchstart", this.onTouchStart, true);
    element.removeEventListener("touchend", this.onTouchEnd, true);
    element.removeEventListener("touchcancel", this.onTouchCancel, true);
    super.dispose();
  }
}
