import type { UpdateApi, UpdateEvent, UpdateMeta, UpdateState } from "@shared/types/update";
import type { UpdateChannel } from "@shared/types/settings";

/** 原生下载器的事件；在此转换为跨平台完整状态快照 */
export type NativeUpdateEvent =
  | { type: "checking" }
  | { type: "available"; meta: UpdateMeta; manual: boolean; canInstall: boolean }
  | { type: "notAvailable"; manual: boolean }
  | {
      type: "progress";
      percent: number;
      bytesPerSecond?: number;
      downloadedBytes?: number;
      totalBytes?: number;
    }
  | { type: "downloaded"; meta: UpdateMeta }
  | { type: "error"; message: string; manual: boolean; stage?: "share" | "install" };

export interface NativeUpdater {
  check(manual: boolean): Promise<void>;
  download(): Promise<void>;
  install(): Promise<void>;
  openDownloadPage(): Promise<void>;
  onEvent(callback: (event: NativeUpdateEvent) => void): () => void;
}

/**
 * 将原生下载与分享流程接入公共更新状态机，重试时保留已下载的包
 * @param native - 平台下载与安装实现
 * @param channel - 当前用户选定的更新通道
 * @returns 具有单调版本号的更新 API
 */
export const createMobileUpdater = (
  native: NativeUpdater,
  channel: () => UpdateChannel,
): UpdateApi => {
  let state: UpdateState = {
    revision: 0,
    channel: channel(),
    phase: "idle",
    mode: "inApp",
    meta: null,
    percent: 0,
    error: null,
  };
  const listeners = new Set<(event: UpdateEvent) => void>();
  /** 发布快照副本，防止订阅者修改下载器持有的状态 */
  const publish = (
    patch: Partial<UpdateState>,
    notification?: UpdateEvent["notification"],
    manual?: boolean,
  ): void => {
    state = { ...state, ...patch, revision: state.revision + 1 };
    for (const listener of listeners)
      listener({ state: structuredClone(state), notification, manual });
  };
  native.onEvent((event) => {
    switch (event.type) {
      case "checking":
        publish({
          channel: channel(),
          phase: "checking",
          meta: null,
          percent: 0,
          error: null,
          bytesPerSecond: 0,
          downloadedBytes: 0,
          totalBytes: 0,
        });
        break;
      case "available":
        publish(
          {
            phase: "available",
            meta: event.meta,
            mode: event.canInstall ? "inApp" : "external",
            error: null,
            totalBytes: event.meta.size,
          },
          "available",
          event.manual,
        );
        break;
      case "notAvailable":
        publish({ phase: "upToDate", meta: null, error: null }, "upToDate", event.manual);
        break;
      case "progress": {
        const { type: _type, ...progress } = event;
        publish({ ...progress, phase: "downloading", error: null });
        break;
      }
      case "downloaded":
        publish(
          {
            phase: "downloaded",
            meta: event.meta,
            percent: 100,
            downloadedBytes: event.meta.size,
            error: null,
          },
          "downloaded",
        );
        break;
      case "error":
        publish(
          {
            phase: "error",
            error: {
              source: event.stage ? "install" : state.phase === "checking" ? "check" : "download",
              message: event.message,
            },
          },
          "error",
          event.manual,
        );
    }
  });
  return {
    getState: async () => structuredClone(state),
    check: async (manual) => {
      if (state.phase !== "downloading" && state.phase !== "installing") await native.check(manual);
      return structuredClone(state);
    },
    download: async () => {
      if (state.phase !== "available" && !(state.meta && state.error?.source === "download"))
        return structuredClone(state);
      publish({ phase: "downloading", percent: 0, error: null });
      await native.download();
      return structuredClone(state);
    },
    install: async () => {
      if (state.phase !== "downloaded" && state.error?.source !== "install")
        return structuredClone(state);
      publish({ phase: "installing", error: null });
      await native.install();
      // 系统分享或安装面板可取消，保留下载包供用户再次打开
      if (state.phase === "installing") publish({ phase: "downloaded" });
      return structuredClone(state);
    },
    openDownloadPage: () => native.openDownloadPage(),
    onEvent: (callback) => {
      listeners.add(callback);
      return () => {
        listeners.delete(callback);
      };
    },
  };
};
