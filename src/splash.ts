/** 等待 Next 笔画完成，不等待无限循环的 Logo 动画。 */
export const dismissSplash = async (): Promise<void> => {
  const root = document.getElementById("app-loading");
  if (!root) return;
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const letters = [...root.querySelectorAll<SVGElement>(".splash-next .letter")];
  const animations = letters.flatMap((letter) => letter.getAnimations?.() ?? []);
  if (!reducedMotion) {
    const fallback = animations.length
      ? 2500
      : Math.max(0, 2050 - (performance.now() - (window.__splashStart ?? 0)));
    let timeout: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<void>((resolve) => {
      timeout = setTimeout(resolve, fallback);
    });
    // WebView 在后台可能暂停动画，必须有退出上限。
    await (animations.length
      ? Promise.race([
          Promise.all(animations.map((animation) => animation.finished.catch(() => undefined))),
          deadline,
        ])
      : deadline);
    clearTimeout(timeout);
  }
  if (root.classList.contains("boot-failed")) return;
  root.classList.add("hidden");
  await new Promise<void>((resolve) => {
    const finish = (): void => {
      clearTimeout(timeout);
      root.removeEventListener("transitionend", onEnd);
      root.remove();
      resolve();
    };
    const onEnd = (event: TransitionEvent): void => {
      if (event.target === root && event.propertyName === "opacity") finish();
    };
    const timeout = setTimeout(finish, reducedMotion ? 0 : 350);
    root.addEventListener("transitionend", onEnd);
  });
};
