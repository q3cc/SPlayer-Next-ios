import { beforeEach, describe, expect, it, vi } from "vitest";
import { AUDIO_EXTENSIONS } from "@shared/types/cloudUpload";
import { pickCloudSongs } from "./cloud";

const mocks = vi.hoisted(() => ({ open: vi.fn(), stat: vi.fn() }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: mocks.open }));
vi.mock("@tauri-apps/plugin-fs", () => ({ stat: mocks.stat }));

beforeEach(() => {
  mocks.open.mockReset();
  mocks.stat.mockReset().mockResolvedValue({ isFile: true, size: 1234 });
});

describe("iOS 云盘文件选择", () => {
  it("实际打开支持多选的音频文件选择器", async () => {
    mocks.open.mockResolvedValue(["/Documents/song.FLAC", "/Documents/music.mp3"]);
    expect(await pickCloudSongs()).toEqual([
      { path: "/Documents/song.FLAC", name: "song.FLAC", size: 1234 },
      { path: "/Documents/music.mp3", name: "music.mp3", size: 1234 },
    ]);
    expect(mocks.open).toHaveBeenCalledWith({
      multiple: true,
      directory: false,
      filters: [{ name: "Audio", extensions: AUDIO_EXTENSIONS }],
    });
  });

  it.each([null, []])("取消或空选不读取文件：%j", async (selected) => {
    mocks.open.mockResolvedValue(selected);
    expect(await pickCloudSongs()).toEqual([]);
    expect(mocks.stat).not.toHaveBeenCalled();
  });

  it("保留文件 URL，正确显示编码文件名", async () => {
    const path = "file:///Documents/%E6%AD%8C%E6%9B%B2%20A.flac";
    mocks.open.mockResolvedValue(path);
    expect(await pickCloudSongs()).toEqual([{ path, name: "歌曲 A.flac", size: 1234 }]);
    expect(mocks.stat).toHaveBeenCalledWith(path);
  });

  it("过滤非音频、目录并对重复选取路径去重", async () => {
    mocks.open.mockResolvedValue(["/a.mp3", "/a.mp3", "/dir.flac", "/notes.txt"]);
    mocks.stat.mockImplementation(async (path: string) => ({
      isFile: path !== "/dir.flac",
      size: 10,
    }));
    expect(await pickCloudSongs()).toEqual([{ path: "/a.mp3", name: "a.mp3", size: 10 }]);
    expect(mocks.stat).toHaveBeenCalledTimes(2);
  });

  it("选取与读取错误向上传递，不伪装成用户取消", async () => {
    mocks.open.mockRejectedValueOnce(new Error("picker failed"));
    await expect(pickCloudSongs()).rejects.toThrow("picker failed");
    mocks.open.mockResolvedValue(["/a.mp3"]);
    mocks.stat.mockRejectedValueOnce(new Error("unavailable"));
    await expect(pickCloudSongs()).rejects.toThrow("unavailable");
  });
});
