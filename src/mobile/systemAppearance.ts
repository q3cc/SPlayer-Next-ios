import { addPluginListener, invoke, isTauri } from "@tauri-apps/api/core";

/** 原生通知补足 WebKit 主题事件，恢复前台时重新读取；只更新系统偏好，不修改用户选择。 */
export const observeSystemAppearance = async (
  update: (dark: boolean) => void,
): Promise<() => void> => {
  if (!isTauri()) return () => {};
  let disposed = false;
  let revision = 0;
  const listener = await addPluginListener<{ dark: boolean }>(
    "lyric-pip",
    "appearance",
    (value) => {
      revision++;
      if (!disposed) update(value.dark);
    },
  );
  const refresh = async (): Promise<void> => {
    if (document.hidden || disposed) return;
    const token = ++revision;
    try {
      const value = await invoke<{ dark: boolean }>("plugin:lyric-pip|appearance");
      if (!disposed && token === revision) update(value.dark);
    } catch (error) {
      console.warn("[theme] 系统外观同步失败", error);
    }
  };
  document.addEventListener("visibilitychange", refresh);
  window.addEventListener("pageshow", refresh);
  window.addEventListener("focus", refresh);
  await refresh();
  return () => {
    disposed = true;
    document.removeEventListener("visibilitychange", refresh);
    window.removeEventListener("pageshow", refresh);
    window.removeEventListener("focus", refresh);
    void listener.unregister();
  };
};
