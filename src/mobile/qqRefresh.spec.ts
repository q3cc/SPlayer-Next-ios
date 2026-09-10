import { beforeEach, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ fetch: vi.fn(), save: vi.fn() }));
vi.mock("@main/utils/proxy", () => ({ fetchWithProxy: mocks.fetch }));
vi.mock("@main/database/sessions", () => ({
  getSessionCookies: () => ({ uin: "123", qm_keyst: "old" }),
  saveSessionCookies: mocks.save,
  clearSessionCookies: vi.fn(),
}));
vi.mock("@main/utils/logger", () => ({ coreLog: { info: vi.fn(), warn: vi.fn() } }));
vi.mock("@main/apis/qqmusic/core/config", () => ({
  QM_API_URL: "https://example.com",
  QM_HEADERS: {},
  SESSION_TTL: 1000,
  getCommonParams: () => ({}),
}));
const response = (code: number, data = {}) =>
  new Response(JSON.stringify({ code: 0, request: { code, data } }));
beforeEach(() => {
  vi.resetModules();
  mocks.fetch.mockReset();
  mocks.save.mockClear();
});

it("并发鉴权失败只刷新一次，两个请求都能用新凭据继续", async () => {
  let complete!: (value: Response) => void;
  let refreshes = 0;
  mocks.fetch.mockImplementation(async (_url, options) => {
    const body = JSON.parse(options.body);
    if (body.request.method === "Login") {
      refreshes++;
      return new Promise<Response>((resolve) => {
        complete = resolve;
      });
    }
    return body.comm.authst === "old" ? response(1000) : response(0, { ok: true });
  });
  const { qmRequest } = await import("@main/apis/qqmusic/core/request");
  const first = qmRequest("test", "query", {}, { session: false });
  const second = qmRequest("test", "query", {}, { session: false });
  await vi.waitFor(() => expect(refreshes).toBe(1));
  complete(response(0, { musickey: "new" }));
  expect(await Promise.all([first, second])).toEqual([{ ok: true }, { ok: true }]);
  expect(mocks.save).toHaveBeenCalledOnce();
});
it("刷新期间退出登录，不允许旧凭据写回", async () => {
  let complete!: (value: Response) => void;
  mocks.fetch.mockImplementation(
    () =>
      new Promise<Response>((resolve) => {
        complete = resolve;
      }),
  );
  const api = await import("@main/apis/qqmusic/core/request");
  const pending = api.refreshQMCredential();
  api.clearQQMusicCookies();
  complete(response(0, { musickey: "old-account-new-key" }));
  expect(await pending).toBe(false);
  expect(mocks.save).not.toHaveBeenCalled();
});
it("公开接口关闭鉴权时不携带账号 cookie 和密钥", async () => {
  mocks.fetch.mockResolvedValue(response(0, {}));
  const { qmRequest } = await import("@main/apis/qqmusic/core/request");
  await qmRequest("test", "query", {}, { auth: false, session: false });
  const options = mocks.fetch.mock.calls[0][1];
  expect(options.headers.Cookie).toBe("tmeLoginType=-1;");
  expect(JSON.parse(options.body).comm.authst).toBeUndefined();
});
