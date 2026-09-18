import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CloudUploadProgress } from "@shared/types/cloudUpload";
import { mobileCloud, cloudUploadURL } from "./cloud";

const mocks = vi.hoisted(() => ({
  invoke: vi.fn(),
  call: vi.fn(),
  fetch: vi.fn(),
  listen: vi.fn(),
  unregister: vi.fn(),
}));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke, addPluginListener: mocks.listen }));
vi.mock("./providers", () => ({ mobileProviders: { call: mocks.call } }));
vi.mock("./shims/proxy", () => ({ fetchWithProxy: mocks.fetch }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: vi.fn() }));
vi.mock("@tauri-apps/plugin-fs", () => ({ stat: vi.fn() }));

beforeEach(() => {
  mocks.invoke.mockReset().mockImplementation(async (command: string) => {
    if (command.endsWith("prepare_cloud_upload")) return { md5: "a".repeat(32), size: 100 };
    if (command.endsWith("read_metadata")) return { title: "歌曲", artist: "歌手", album: "专辑" };
    return { success: true };
  });
  mocks.call.mockReset().mockImplementation(async (_platform, name) => {
    const responses: Record<string, object> = {
      cloud_upload_check: { needUpload: true, songId: 1 },
      cloud_upload_check_v2: { data: [{ songId: 9, upload: 0 }] },
      cloud_nos_token: { result: { token: "token", objectKey: "folder/audio", resourceId: 7 } },
      cloud_upload_info: { songId: 5 },
    };
    return { ok: true, body: { code: 200, ...responses[name] } };
  });
  mocks.fetch
    .mockReset()
    .mockResolvedValue(new Response(JSON.stringify({ upload: ["http://nosup-hz1.127.net"] })));
  mocks.unregister.mockReset().mockResolvedValue(undefined);
  mocks.listen.mockReset().mockResolvedValue({ unregister: mocks.unregister });
});

describe("iOS 云盘上传编排", () => {
  it("原生读文件、申请凭证、上传后提交并发布，释放进度订阅", async () => {
    const progress = vi.fn();
    const off = mobileCloud.onUploadProgress(progress);
    const result = await mobileCloud.uploadSong("/Documents/song.flac", "task");
    off();
    expect(result).toEqual({ success: true, instant: false, songId: "5" });
    expect(mocks.invoke).toHaveBeenCalledWith(
      "plugin:native-audio|upload_cloud_file",
      expect.objectContaining({
        source: "/Documents/song.flac",
        size: 100,
        mime: "audio/flac",
        uploadId: "task",
        token: "token",
        url: "https://nosup-hz1.127.net/jd-musicrep-privatecloud-audio-public/folder%2Faudio?offset=0&complete=true&version=1.0",
      }),
    );
    expect(mocks.call.mock.calls.map((call) => call[1])).toEqual([
      "cloud_upload_check",
      "cloud_nos_token",
      "cloud_upload_info",
      "cloud_pub",
    ]);
    expect(progress.mock.calls.map((call) => call[0].stage)).toEqual([
      "checking",
      "uploading",
      "finishing",
    ]);
    expect(mocks.unregister).toHaveBeenCalledOnce();
  });

  it("秒传仅执行导入，不申请 token 或发送文件字节", async () => {
    mocks.call.mockResolvedValueOnce({ ok: true, body: { code: 200, needUpload: false } });
    expect(await mobileCloud.uploadSong("/song.mp3", "task")).toEqual({
      success: true,
      instant: true,
      songId: "9",
    });
    expect(mocks.call.mock.calls.map((call) => call[1])).toEqual([
      "cloud_upload_check",
      "cloud_upload_check_v2",
      "cloud_song_import",
    ]);
    expect(mocks.fetch).not.toHaveBeenCalled();
    expect(mocks.listen).not.toHaveBeenCalled();
    expect(mocks.invoke.mock.calls.some((call) => call[0].endsWith("upload_cloud_file"))).toBe(
      false,
    );
  });

  it("已存在云盘不重复导入，不可导入不会标记成功", async () => {
    mocks.call
      .mockResolvedValueOnce({ ok: true, body: { code: 200, needUpload: false } })
      .mockResolvedValueOnce({ ok: true, body: { code: 200, data: [{ upload: 1, songId: 8 }] } });
    expect((await mobileCloud.uploadSong("/song.mp3", "task")).success).toBe(true);
    expect(mocks.call).toHaveBeenCalledTimes(2);
    mocks.call
      .mockResolvedValueOnce({ ok: true, body: { code: 200, needUpload: false } })
      .mockResolvedValueOnce({ ok: true, body: { code: 200, data: [{ upload: 2, songId: 8 }] } });
    expect((await mobileCloud.uploadSong("/song.mp3", "retry")).success).toBe(false);
  });

  it("未登录或业务错误不继续上传，并返回平台错误码", async () => {
    mocks.call.mockResolvedValueOnce({ ok: false, body: { code: 301 } });
    expect(await mobileCloud.uploadSong("/song.mp3", "task")).toEqual({
      success: false,
      instant: false,
      errorCode: 301,
    });
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("缺失查重结果不会误走秒传", async () => {
    mocks.call.mockResolvedValueOnce({ ok: true, body: { code: 200 } });
    expect((await mobileCloud.uploadSong("/song.mp3", "task")).success).toBe(false);
    expect(mocks.call).toHaveBeenCalledTimes(1);
  });

  it("原生上传失败不发布，释放订阅后允许重试", async () => {
    mocks.invoke.mockImplementation(async (command: string) => {
      if (command.endsWith("prepare_cloud_upload")) return { md5: "a".repeat(32), size: 100 };
      if (command.endsWith("upload_cloud_file")) throw new Error("network failed");
      return {};
    });
    expect((await mobileCloud.uploadSong("/song.mp3", "task")).success).toBe(false);
    expect(mocks.call.mock.calls.map((call) => call[1])).not.toContain("cloud_pub");
    expect(mocks.unregister).toHaveBeenCalledOnce();
    await mobileCloud.uploadSong("/song.mp3", "task");
    expect(
      mocks.invoke.mock.calls.filter((call) => call[0].endsWith("prepare_cloud_upload")),
    ).toHaveLength(2);
  });

  it("发布失败不显示成功", async () => {
    mocks.call
      .mockResolvedValueOnce({ ok: true, body: { code: 200, needUpload: true } })
      .mockResolvedValueOnce({
        ok: true,
        body: { code: 200, result: { token: "t", objectKey: "x", resourceId: 1 } },
      })
      .mockResolvedValueOnce({ ok: true, body: { code: 200, songId: 6 } })
      .mockResolvedValueOnce({ ok: true, body: { code: 500 } });
    expect(await mobileCloud.uploadSong("/song.mp3", "task")).toEqual({
      success: false,
      instant: false,
      errorCode: 500,
    });
  });

  it("只转发本次上传的进度", async () => {
    mocks.listen.mockImplementation(
      async (_plugin, _event, callback: (value: CloudUploadProgress) => void) => {
        callback({ uploadId: "other", stage: "uploading", loaded: 30, total: 100 });
        callback({ uploadId: "task", stage: "uploading", loaded: 50, total: 100 });
        return { unregister: mocks.unregister };
      },
    );
    const progress = vi.fn();
    const off = mobileCloud.onUploadProgress(progress);
    await mobileCloud.uploadSong("/song.mp3", "task");
    off();
    expect(progress.mock.calls.some((call) => call[0].loaded === 50)).toBe(true);
    expect(progress.mock.calls.some((call) => call[0].uploadId === "other")).toBe(false);
  });

  it.each([
    "https://attacker.test",
    "https://127.net.attacker.test",
    "file:///tmp/a",
    "https://token@nosup-hz1.127.net",
  ])("拒绝非 NOS 上传地址 %s", (host) => {
    expect(() => cloudUploadURL(host, "object")).toThrow();
  });
});
