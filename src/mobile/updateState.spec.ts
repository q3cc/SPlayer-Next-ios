import { describe, expect, it, vi } from "vitest";
import { createMobileUpdater, type NativeUpdateEvent, type NativeUpdater } from "./updateState";
import type { UpdateEvent } from "@shared/types/update";

/** 构造可控制原生完成时机的更新器 */
const setup = () => {
  let emit!: (event: NativeUpdateEvent) => void;
  const native: NativeUpdater = {
    check: vi.fn(async () => {}),
    download: vi.fn(async () => {}),
    install: vi.fn(async () => {}),
    openDownloadPage: vi.fn(async () => {}),
    onEvent: (callback) => {
      emit = callback;
      return () => {};
    },
  };
  const update = createMobileUpdater(native, () => "action");
  const events: UpdateEvent[] = [];
  update.onEvent((event) => events.push(event));
  const available = () =>
    emit({
      type: "available",
      canInstall: true,
      manual: true,
      meta: {
        version: "3.0.0",
        releaseNotes: "",
        releaseDate: "",
        size: 100,
        releaseUrl: "https://github.com/q3cc/SPlayer-Next-ios/releases",
      },
    });
  return { native, update, events, emit: (event: NativeUpdateEvent) => emit(event), available };
};

describe("移动更新器完整快照", () => {
  it("进度到 100% 不代表文件已完成，完成事件之后才可打开安装面板", async () => {
    const { native, update, events, emit, available } = setup();
    available();
    let finish!: () => void;
    vi.mocked(native.download).mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          finish = resolve;
        }),
    );
    const downloading = update.download();
    emit({ type: "progress", percent: 100, downloadedBytes: 100, totalBytes: 100 });
    expect((await update.getState()).phase).toBe("downloading");
    await update.install();
    expect(native.install).not.toHaveBeenCalled();
    emit({ type: "downloaded", meta: events[0].state.meta! });
    finish();
    await downloading;
    await update.install();
    expect(native.install).toHaveBeenCalledOnce();
    expect((await update.getState()).phase).toBe("downloaded");
    expect(events.map((event) => event.state.revision)).toEqual([1, 2, 3, 4, 5, 6]);
  });
  it("分享失败保留元信息和安装重试，包丢失则允许重新下载", async () => {
    const { native, update, emit, available } = setup();
    available();
    emit({ type: "downloaded", meta: (await update.getState()).meta! });
    vi.mocked(native.install).mockImplementationOnce(async () =>
      emit({ type: "error", stage: "share", message: "background", manual: true }),
    );
    expect((await update.install()).error?.source).toBe("install");
    await update.install();
    expect(native.install).toHaveBeenCalledTimes(2);
    vi.mocked(native.install).mockImplementationOnce(async () =>
      emit({ type: "error", message: "missing", manual: true }),
    );
    expect((await update.install()).error?.source).toBe("download");
    await update.download();
    expect(native.download).toHaveBeenCalledOnce();
  });
  it("检查错误和关闭自动检查均不伪造可用更新", async () => {
    const { native, update, emit } = setup();
    expect((await update.check(false)).phase).toBe("idle");
    vi.mocked(native.check).mockImplementation(async () => {
      emit({ type: "checking" });
      emit({ type: "error", message: "rate limited", manual: true });
    });
    const state = await update.check(true);
    expect(state).toMatchObject({
      channel: "action",
      phase: "error",
      meta: null,
      error: { source: "check" },
    });
    state.phase = "available";
    expect((await update.getState()).phase).toBe("error");
  });
});
