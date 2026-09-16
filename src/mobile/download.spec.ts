import { beforeEach, describe, expect, it, vi } from "vitest";
import type { DownloadRequest, DownloadTask } from "@shared/types/download";

const mocks = vi.hoisted(() => ({
  files: new Map<string, number[]>(),
  settings: {
    enabled: true,
    folderScheme: "none",
    fileTemplate: "{artist} - {title}",
    overwritePolicy: "rename",
  },
  saved: [] as DownloadTask[],
  fetch: vi.fn(),
  resolve: vi.fn(),
  write: vi.fn(),
  failRemove: false,
}));
vi.mock("@tauri-apps/api/path", () => ({
  documentDir: async () => "/Documents",
  join: async (...parts: string[]) => parts.join("/"),
}));
vi.mock("localforage", () => ({
  default: {
    createInstance: () => ({
      getItem: async () => structuredClone(mocks.saved),
      setItem: async (_key: string, value: DownloadTask[]) => {
        mocks.saved = value;
      },
    }),
  },
}));
vi.mock("./shims/store", () => ({
  store: {
    get: (key: string) => (key === "download.enabled" ? mocks.settings.enabled : mocks.settings),
  },
}));
vi.mock("./shims/proxy", () => ({ fetchWithProxy: mocks.fetch }));
vi.mock("@/services/download/resolver", () => ({ resolveDownloadPayload: mocks.resolve }));
vi.mock("@tauri-apps/plugin-fs", () => ({
  mkdir: async () => undefined,
  exists: async (path: string) => mocks.files.has(path),
  open: async (path: string) => {
    mocks.files.set(path, []);
    return {
      write: async (chunk: Uint8Array) => {
        mocks.write(chunk);
        const amount = Math.min(2, chunk.length);
        mocks.files.get(path)!.push(...chunk.slice(0, amount));
        return amount;
      },
      close: async () => undefined,
    };
  },
  rename: async (from: string, to: string) => {
    mocks.files.set(to, mocks.files.get(from)!);
    mocks.files.delete(from);
  },
  remove: async (path: string) => {
    if (mocks.failRemove) throw new Error("permission denied");
    mocks.files.delete(path);
  },
}));

const request = (taskId = "one"): DownloadRequest => ({
  taskId,
  track: {
    id: taskId,
    source: "netease",
    title: "Song",
    artists: [{ name: "Artist" }],
    duration: 1000,
  },
  qualityLevel: "hq",
  tagOptions: {
    embedCover: false,
    embedMeta: false,
    embedLyric: false,
    writeLrc: false,
    saveTtml: false,
  },
  usePlaybackForDownload: false,
  lyricFileFormat: "lrc",
});
const audio = () =>
  new Response(new Uint8Array([1, 2, 3, 4, 5]), {
    headers: { "content-length": "5", "content-type": "audio/flac" },
  });

beforeEach(() => {
  vi.resetModules();
  mocks.files.clear();
  mocks.saved = [];
  mocks.failRemove = false;
  Object.assign(mocks.settings, {
    enabled: true,
    folderScheme: "none",
    fileTemplate: "{artist} - {title}",
    overwritePolicy: "rename",
  });
  mocks.fetch.mockReset().mockImplementation(async () => audio());
  mocks.resolve.mockReset().mockResolvedValue({ url: "https://music.test/audio" });
  mocks.write.mockClear();
});

describe("iOS 下载", () => {
  it("解析后流式落盘，处理短写并上报进度，不保存临时链接", async () => {
    const { mobileDownload } = await import("./download");
    const progress = vi.fn();
    mobileDownload.onProgress(progress);
    expect(await mobileDownload.start(request())).toEqual({ ok: true });
    await vi.waitFor(async () => expect((await mobileDownload.list())[0].status).toBe("done"));
    expect(mocks.resolve).toHaveBeenCalledOnce();
    expect(mocks.files.get("/Documents/Downloads/Artist - Song.flac")).toEqual([1, 2, 3, 4, 5]);
    expect(mocks.write).toHaveBeenCalledTimes(3);
    expect(progress).toHaveBeenCalled();
    await vi.waitFor(() => expect(mocks.saved[0].filePath).toBe("Artist - Song.flac"));
    expect(JSON.stringify(mocks.saved)).not.toContain("https://music.test");
  });

  it("关闭时不入队，不发起网络请求", async () => {
    mocks.settings.enabled = false;
    const { mobileDownload } = await import("./download");
    await expect(mobileDownload.start(request())).rejects.toThrow("disabled");
    expect(mocks.resolve).not.toHaveBeenCalled();
    expect(await mobileDownload.list()).toEqual([]);
  });

  it("串行解析，取消后的旧结果不能覆盖同 ID 的重试", async () => {
    let finish!: (value: { url: string }) => void;
    mocks.resolve.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    const { mobileDownload } = await import("./download");
    await mobileDownload.start(request());
    await mobileDownload.cancel("one");
    expect(await mobileDownload.retry(request())).toEqual({ ok: true });
    expect(mocks.resolve).toHaveBeenCalledTimes(1);
    finish({ url: "https://music.test/stale" });
    await vi.waitFor(async () => expect((await mobileDownload.list())[0].status).toBe("done"));
    expect(await mobileDownload.list()).toHaveLength(1);
    expect(mocks.fetch).toHaveBeenCalledTimes(1);
    expect(String(mocks.fetch.mock.calls[0][0])).toBe("https://music.test/audio");
  });

  it("取消下载中任务会中止请求、清除半成品并继续队列", async () => {
    let stream!: ReadableStreamDefaultController<Uint8Array>;
    mocks.fetch.mockImplementationOnce(async (_url, options) => {
      const body = new ReadableStream<Uint8Array>({
        start(controller) {
          stream = controller;
        },
      });
      options.signal.addEventListener("abort", () => stream.error(new Error("aborted")));
      return new Response(body);
    });
    const { mobileDownload } = await import("./download");
    await mobileDownload.startMany([request(), request("two")]);
    await vi.waitFor(async () =>
      expect((await mobileDownload.list())[0].status).toBe("downloading"),
    );
    await mobileDownload.cancel("one");
    await vi.waitFor(async () => expect((await mobileDownload.list())[1].status).toBe("done"));
    expect(mocks.fetch.mock.calls[0][1].signal.aborted).toBe(true);
    expect(mocks.files.has("/Documents/Downloads/one.part")).toBe(false);
    expect((await mobileDownload.list())[0].status).toBe("canceled");
  });

  it("失败可重试，重复完成文件不再次下载", async () => {
    mocks.fetch.mockRejectedValueOnce(new Error("offline"));
    const { mobileDownload } = await import("./download");
    await mobileDownload.start(request());
    await vi.waitFor(async () => expect((await mobileDownload.list())[0].status).toBe("failed"));
    await mobileDownload.retry(request());
    await vi.waitFor(async () => expect((await mobileDownload.list())[0].status).toBe("done"));
    expect(await mobileDownload.start({ ...request(), taskId: "duplicate" })).toEqual({
      ok: false,
      reason: "downloaded",
    });
  });

  it("重名自动编号，清空记录不删除音频", async () => {
    mocks.files.set("/Documents/Downloads/Artist - Song.flac", [9]);
    const { mobileDownload } = await import("./download");
    await mobileDownload.start(request());
    await vi.waitFor(async () => expect((await mobileDownload.list())[0].status).toBe("done"));
    expect(mocks.files.has("/Documents/Downloads/Artist - Song (1).flac")).toBe(true);
    await mobileDownload.clearFinished();
    expect(await mobileDownload.list()).toEqual([]);
    expect(mocks.files.size).toBe(2);
  });

  it("删除完成任务会删除文件，删除失败保留记录", async () => {
    const { mobileDownload } = await import("./download");
    await mobileDownload.start(request());
    await vi.waitFor(async () => expect((await mobileDownload.list())[0].status).toBe("done"));
    mocks.failRemove = true;
    await expect(mobileDownload.remove("one")).rejects.toThrow();
    expect(await mobileDownload.list()).toHaveLength(1);
    mocks.failRemove = false;
    await mobileDownload.remove("one");
    expect(mocks.files.size).toBe(0);
    expect(await mobileDownload.list()).toEqual([]);
  });

  it("拒绝空响应、网页响应和截断音频", async () => {
    const { mobileDownload } = await import("./download");
    for (const response of [
      new Response(new Uint8Array()),
      new Response("error", { headers: { "content-type": "text/html" } }),
      new Response(new Uint8Array([1]), { headers: { "content-length": "10" } }),
    ]) {
      mocks.fetch.mockResolvedValueOnce(response);
      const req = request(crypto.randomUUID());
      await mobileDownload.start(req);
      await vi.waitFor(async () =>
        expect(
          (await mobileDownload.list()).find((task) => task.taskId === req.taskId)?.status,
        ).toBe("failed"),
      );
    }
    await vi.waitFor(() => expect(mocks.files.size).toBe(0));
  });

  it("重启将未完成任务标记中断并清理半成品", async () => {
    mocks.saved = [{ ...request(), status: "downloading", received: 1, total: 5, createdAt: 1 }];
    mocks.files.set("/Documents/Downloads/one.part", [1]);
    const { mobileDownload } = await import("./download");
    expect((await mobileDownload.list())[0].status).toBe("interrupted");
    expect(mocks.files.size).toBe(0);
    expect(mocks.fetch).not.toHaveBeenCalled();
  });

  it("不同流媒体服务器的相同歌曲编号不会误判重复", async () => {
    const { mobileDownload } = await import("./download");
    const first = request();
    first.track = { ...first.track, source: "streaming", serverId: "server-a" };
    const second = { ...first, taskId: "two", track: { ...first.track, serverId: "server-b" } };
    expect(await mobileDownload.startMany([first, second])).toEqual([{ ok: true }, { ok: true }]);
    await vi.waitFor(async () =>
      expect((await mobileDownload.list()).every((task) => task.status === "done")).toBe(true),
    );
  });

  it("历史上限阻止新增，但允许替换失败任务后重试", async () => {
    mocks.saved = Array.from({ length: 200 }, (_, index) => ({
      taskId: String(index),
      track: request(String(index)).track,
      qualityLevel: "hq",
      status: "failed",
      received: 0,
      total: 0,
      createdAt: index,
    }));
    const { mobileDownload } = await import("./download");
    await expect(mobileDownload.start(request("extra"))).rejects.toThrow("full");
    expect(await mobileDownload.retry(request("0"))).toEqual({ ok: true });
    await vi.waitFor(async () =>
      expect((await mobileDownload.list()).find((task) => task.taskId === "0")?.status).toBe(
        "done",
      ),
    );
    expect(await mobileDownload.list()).toHaveLength(200);
  });

  it("文件名不可越过 Downloads 目录", async () => {
    const { downloadName } = await import("./download");
    expect(downloadName("../../secret")).not.toContain("/");
    expect(downloadName(".. ")).toBe("Unknown");
    expect(downloadName("a" + String.fromCharCode(92, 0) + "b")).toBe("a__b");
    expect(downloadName("x".repeat(300))).toHaveLength(70);
  });
});
