/** 沿用原版最短展示时间，保留 WebView 淡出超时和启动失败入口。 */
export const dismissSplash = async (): Promise<void> => {
  const root = document.getElementById("app-loading");
  if (!root) return;
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!reducedMotion) {
    await new Promise<void>((resolve) =>
      setTimeout(resolve, Math.max(0, 1100 - performance.now())),
    );
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
