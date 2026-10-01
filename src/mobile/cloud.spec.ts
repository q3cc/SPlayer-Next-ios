import { beforeEach, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({
  pick: vi.fn(),
  stat: vi.fn(),
  read: vi.fn(),
  close: vi.fn(),
  seek: vi.fn(),
  call: vi.fn(),
  fetch: vi.fn(),
}));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: mocks.pick }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: async () => ({ title: "音乐" }) }));
vi.mock("@tauri-apps/plugin-fs", () => ({
  stat: mocks.stat,
  SeekMode: { Start: 0 },
  open: vi.fn(async () => ({ read: mocks.read, close: mocks.close, seek: mocks.seek })),
}));
vi.mock("./providers", () => ({ mobileProviders: { call: mocks.call } }));
vi.mock("./shims/proxy", () => ({ fetchWithProxy: mocks.fetch }));
import { mobileCloud } from "./cloud";

beforeEach(() => {
  vi.resetAllMocks();
  mocks.stat.mockResolvedValue({ size: 4, isFile: true });
  mocks.read.mockImplementation(async (buffer: Uint8Array) => {
    buffer.set([1, 2, 3, 4]);
    return 4;
  });
  mocks.read.mockResolvedValueOnce(4).mockResolvedValueOnce(null);
});
const response = (body: object) => ({ ok: true, status: 200, body: { code: 200, ...body } });
it("选择音频使用复制授权，取消时不加入队列", async () => {
  mocks.pick.mockResolvedValue(null);
  expect(await mobileCloud.pickSongs()).toEqual([]);
  mocks.pick.mockResolvedValue(["/song.flac", "/note.txt"]);
  expect(await mobileCloud.pickSongs()).toEqual([
    { path: "/song.flac", name: "song.flac", size: 4 },
  ]);
  expect(mocks.pick).toHaveBeenLastCalledWith(expect.objectContaining({ fileAccessMode: "copy" }));
});
it("秒传校验导入结果并关闭文件，不发送音频字节", async () => {
  mocks.call
    .mockResolvedValueOnce(response({ needUpload: false }))
    .mockResolvedValueOnce(response({ data: [{ songId: 42 }] }))
    .mockResolvedValueOnce(response({}));
  expect(await mobileCloud.uploadSong("/song.mp3", "id")).toEqual({
    success: true,
    instant: true,
    songId: "42",
  });
  expect(mocks.fetch).not.toHaveBeenCalled();
  expect(mocks.close).toHaveBeenCalledOnce();
});
it("文件名解析同时兼容 Windows 和移动端路径", async () => {
  mocks.pick.mockResolvedValue(["D:\\Music\\song.mp3", "/Music/song.flac"]);
  expect((await mobileCloud.pickSongs()).map((song) => song.name)).toEqual([
    "song.mp3",
    "song.flac",
  ]);
});
it("查重失败不能当成秒传成功", async () => {
  mocks.call.mockResolvedValue({ ok: false, status: 401, body: { code: 301 } });
  await expect(mobileCloud.uploadSong("/song.mp3", "id")).rejects.toThrow();
  expect(mocks.call).toHaveBeenCalledTimes(1);
  expect(mocks.close).toHaveBeenCalledOnce();
});
it("分块上传确认服务端偏移后才提交发布", async () => {
  mocks.read.mockResolvedValueOnce(4).mockResolvedValueOnce(null);
  mocks.call
    .mockResolvedValueOnce(response({ needUpload: true, songId: 1 }))
    .mockResolvedValueOnce(
      response({ result: { token: "test-token", objectKey: "a/b", resourceId: "r" } }),
    )
    .mockResolvedValueOnce(response({ songId: 42 }))
    .mockResolvedValueOnce(response({}));
  mocks.fetch
    .mockResolvedValueOnce({ ok: true, json: async () => ({ upload: ["https://upload.example"] }) })
    .mockResolvedValueOnce({ ok: true, json: async () => ({ offset: 4 }) });
  const event = vi.fn();
  const off = mobileCloud.onUploadProgress(event);
  expect((await mobileCloud.uploadSong("/song.flac", "id")).success).toBe(true);
  expect(String(mocks.fetch.mock.calls[1][0])).toContain("a%2Fb?offset=0&complete=true");
  expect(event).toHaveBeenLastCalledWith({
    uploadId: "id",
    stage: "finishing",
    loaded: 4,
    total: 4,
  });
  off();
});
it("上传偏移不一致时停止，不发布残缺歌曲", async () => {
  mocks.read.mockResolvedValueOnce(4);
  mocks.call
    .mockResolvedValueOnce(response({ needUpload: true, songId: 1 }))
    .mockResolvedValueOnce(
      response({ result: { token: "test-token", objectKey: "a", resourceId: "r" } }),
    );
  mocks.fetch
    .mockResolvedValueOnce({ ok: true, json: async () => ({ upload: ["https://upload.example"] }) })
    .mockResolvedValueOnce({ ok: true, json: async () => ({ offset: 2 }) });
  await expect(mobileCloud.uploadSong("/song.mp3", "id")).rejects.toThrow("上传字节数不一致");
  expect(mocks.call).toHaveBeenCalledTimes(2);
  expect(mocks.close).toHaveBeenCalledOnce();
});
