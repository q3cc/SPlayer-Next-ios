import { beforeEach, describe, expect, it, vi } from "vitest";
import { mobileLibrary, resolveMobileAudioSource } from "./library";

const { open, stat } = vi.hoisted(() => ({ open: vi.fn(), stat: vi.fn() }));
vi.mock("@tauri-apps/plugin-fs", () => ({ stat }));
beforeEach(() => {
  open.mockReset();
  stat.mockReset().mockResolvedValue({ isDirectory: true });
});
vi.mock("@tauri-apps/plugin-dialog", () => ({ open }));
vi.mock("@tauri-apps/api/core", () => ({ convertFileSrc: (path: string) => `asset:${path}` }));

describe("移动端系统目录选择", () => {
  it("复用目录选择接口并导入持久副本", async () => {
    open.mockResolvedValueOnce("file:///Documents/Imported%20Music/test/music");
    const result = await mobileLibrary.addScanDir();
    expect(result.success).toBe(true);
    expect(open).toHaveBeenCalledWith({
      directory: true,
      multiple: false,
      recursive: true,
      fileAccessMode: "copy",
    });
    expect((await mobileLibrary.getScanDirs()).data).toContain(result.data);
  });

  it("取消选择时不添加目录", async () => {
    open.mockResolvedValueOnce(null);
    expect(await mobileLibrary.addScanDir()).toEqual({ success: false, error: "canceled" });
  });

  it("将原生错误交给共用界面显示，不让点击悄悄失效", async () => {
    open.mockRejectedValueOnce("native picker failed");
    expect(await mobileLibrary.addScanDir()).toEqual({
      success: false,
      error: "native picker failed",
    });
  });

  it("跨入口重复请求不会覆盖待返回的选择结果，取消后可以重试", async () => {
    let finish!: (value: string | null) => void;
    open.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    const first = mobileLibrary.addScanDir();
    expect(await mobileLibrary.addScanDir()).toEqual({
      success: false,
      error: "文件夹选择或导入正在进行中",
    });
    expect(open).toHaveBeenCalledOnce();
    finish(null);
    await first;
    open.mockResolvedValueOnce("file:///Documents/Imported%20Music/retry");
    expect((await mobileLibrary.addScanDir()).success).toBe(true);
    expect(open).toHaveBeenCalledTimes(2);
  });

  it("返回普通文件时提示重新选择目录，不写入扫描列表", async () => {
    const path = "file:///Documents/song.mp3";
    open.mockResolvedValueOnce(path);
    stat.mockResolvedValueOnce({ isDirectory: false });
    expect(await mobileLibrary.addScanDir()).toEqual({
      success: false,
      error: "请选择文件夹，而不是音频文件",
    });
    expect((await mobileLibrary.getScanDirs()).data).not.toContain(path);
  });

  it("目录不可读时返回错误并释放选择锁", async () => {
    open.mockResolvedValue("file:///Documents/unreadable");
    stat.mockRejectedValueOnce(new Error("permission denied"));
    expect(await mobileLibrary.addScanDir()).toEqual({
      success: false,
      error: "permission denied",
    });
    expect((await mobileLibrary.addScanDir()).success).toBe(true);
  });

  it("通过应用资源协议播放系统目录返回的本地文件", () => {
    expect(resolveMobileAudioSource("file:///Documents/Imported%20Music/test/a.mp3")).toBe(
      "asset:/Documents/Imported Music/test/a.mp3",
    );
    expect(resolveMobileAudioSource("https://example.com/a.mp3")).toBe("https://example.com/a.mp3");
  });
});
