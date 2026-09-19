import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { fetchMock } = vi.hoisted(() => ({ fetchMock: vi.fn() }));
vi.mock("@main/utils/proxy", () => ({ fetchWithProxy: fetchMock }));
vi.mock("@main/utils/logger", () => ({ neteaseLog: { warn: vi.fn() } }));

beforeEach(() => {
  vi.resetModules();
  fetchMock.mockReset();
});
afterEach(() => vi.useRealTimers());

describe("移动端网易请求", () => {
  it("为需要风控校验的请求获取并附加易盾 v3 token", async () => {
    const { createRequest } = await import("@main/apis/netease/core/request");
    fetchMock
      .mockResolvedValueOnce(new Response('null([200,0,"test-anti-cheat-token"])'))
      .mockResolvedValueOnce(new Response(JSON.stringify({ code: 200 })));
    await createRequest(
      "/api/v1/radio/like",
      { trackId: "1", like: true },
      {
        crypto: "eapi",
        checkToken: "v3",
      },
    );
    expect(fetchMock.mock.calls[0][0]).toBe("https://ac.dun.163yun.com/v3/b?pn=YD00000558929251");
    expect(fetchMock.mock.calls[1][1].headers["X-antiCheatToken"]).toBe("test-anti-cheat-token");
  });

  it("使用上游 eapi 域名并复用 WebKit 合并响应头中的 NMTID", async () => {
    const { createRequest } = await import("@main/apis/netease/core/request");
    const response = new Response(JSON.stringify({ code: 200 }));
    Object.defineProperty(response, "headers", {
      value: {
        get: (name: string) =>
          name === "set-cookie"
            ? "NMTID=server-id; Expires=Wed, 09 Jun 2027 10:18:14 GMT; Path=/, MUSIC_U=test-user; Path=/"
            : null,
      },
    });
    fetchMock
      .mockResolvedValueOnce(response)
      .mockResolvedValueOnce(new Response(JSON.stringify({ code: 200 })));
    const first = await createRequest("/api/song/lyric/v1", { id: "28029104" }, { crypto: "eapi" });
    expect(first.cookie.some((cookie) => cookie.startsWith("MUSIC_U=test-user"))).toBe(true);
    expect(fetchMock.mock.calls[0][0]).toBe("https://interfacepc.music.163.com/eapi/song/lyric/v1");
    expect(fetchMock.mock.calls[0][1].headers.Cookie).not.toContain("NMTID=");
    await createRequest("/api/song/lyric/v1", { id: "28029112" }, { crypto: "eapi" });
    expect(fetchMock.mock.calls[1][1].headers.Cookie).toContain("NMTID=server-id");
  });

  it("短暂网络异常后恢复请求，重试有上限", async () => {
    vi.useFakeTimers();
    const { createRequest } = await import("@main/apis/netease/core/request");
    fetchMock
      .mockRejectedValueOnce(new TypeError("network unavailable"))
      .mockResolvedValueOnce(new Response(JSON.stringify({ code: 200 })));
    const request = createRequest("/api/song/lyric/v1", { id: "1" }, { crypto: "eapi" });
    await vi.runAllTimersAsync();
    expect((await request).status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    fetchMock.mockReset().mockRejectedValue(new TypeError("offline"));
    const failure = expect(
      createRequest("/api/song/lyric/v1", { id: "1" }, { crypto: "eapi" }),
    ).rejects.toThrow("offline");
    await vi.runAllTimersAsync();
    await failure;
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
});
