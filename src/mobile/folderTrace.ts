import { store } from "./shims/store";

/** 开关关闭时不生成请求标识，也不向原生层启用诊断。 */
export const startFolderTrace = () => {
  const id = store.get("system.diagnosticLogging") ? crypto.randomUUID() : undefined;
  const started = performance.now();
  return {
    id,
    log(stage: string, detail: Record<string, unknown> = {}): void {
      if (!id || !store.get("system.diagnosticLogging")) return;
      console.info("[folder-trace]", {
        id,
        layer: "web",
        stage,
        elapsedMs: Math.round(performance.now() - started),
        ...detail,
      });
    },
  };
};
