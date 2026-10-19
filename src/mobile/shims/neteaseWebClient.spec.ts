import { beforeEach, expect, it, vi } from "vitest";
import { requestWithWebClient, resetWebClientSession } from "./neteaseWebClient";
const request = vi.hoisted(() => vi.fn());
vi.mock("@main/apis/netease/core/request", () => ({ createRequest: request }));
beforeEach(() => request.mockReset().mockResolvedValue({ status: 200, body: {}, cookie: [] }));
it("移动客户端保留原生歌单协议与收藏接口", async () => {
  await requestWithWebClient("/api/playlist/create", { name: "测试" }, { crypto: "weapi" });
  expect(request).toHaveBeenLastCalledWith(
    "/api/playlist/create",
    { name: "测试" },
    expect.objectContaining({ crypto: "eapi", client: undefined }),
  );
  await requestWithWebClient(
    "/api/song/like",
    { trackId: "one", like: "true" },
    { crypto: "weapi" },
  );
  expect(request).toHaveBeenLastCalledWith(
    "/api/radio/like",
    { alg: "itembased", trackId: "one", like: true, time: "3" },
    expect.objectContaining({ crypto: "weapi" }),
  );
});
it("换账号后拒绝旧会话迟到结果", async () => {
  let finish!: (value: unknown) => void;
  request.mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  );
  const pending = requestWithWebClient("/api/album/sub", { id: "one" }, { crypto: "weapi" });
  resetWebClientSession();
  finish({ status: 200, body: {}, cookie: [] });
  await expect(pending).rejects.toThrow("会话已变更");
});
