import { beforeEach, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  register: vi.fn(),
  search: vi.fn(),
  save: vi.fn(),
  token: "",
}));
vi.mock("@main/database/sessions", () => ({
  getSessionCookies: () => ({}),
  saveSessionCookies: mocks.save,
  clearSessionCookies: vi.fn(),
}));
vi.mock("@main/store", () => ({ store: { get: () => false } }));
vi.mock("@main/utils/logger", () => ({ neteaseLog: { info: vi.fn(), warn: vi.fn() } }));
vi.mock("@main/apis/netease/core/request", () => ({ createRequest: vi.fn() }));
vi.mock("@main/apis/netease/core/xeapi", () => ({ resetXeapiKey: vi.fn() }));
vi.mock("@main/apis/netease/core/device", () => ({
  getAnonymousToken: () => mocks.token,
  getDeviceId: () => "test-device",
  setAnonymousToken: (value: string) => {
    mocks.token = value;
  },
  setDeviceId: vi.fn(),
}));
vi.mock("@main/apis/netease/modules", () => ({
  modules: { register_anonimous: mocks.register, cloudsearch: mocks.search },
}));

beforeEach(() => {
  vi.resetModules();
  mocks.token = "";
  mocks.register.mockReset().mockResolvedValue({ status: 200, body: {}, cookie: [] });
  mocks.search
    .mockReset()
    .mockResolvedValue({ status: 200, body: { result: { songs: [{ id: 1 }] } }, cookie: [] });
});

it("游客注册缺少令牌时仍请求公开搜索，不伪造成功结果", async () => {
  const { callNetease } = await import("@main/apis/netease");
  expect((await callNetease("cloudsearch", { keywords: "晴天" })).body.result.songs).toEqual([
    { id: 1 },
  ]);
  await callNetease("cloudsearch", { keywords: "小半" });
  expect(mocks.search).toHaveBeenCalledTimes(2);
  expect(mocks.register).toHaveBeenCalledOnce();
});
it("真实搜索失败仍向上传递，不能让冒烟假通过", async () => {
  mocks.search.mockRejectedValue(new Error("search unavailable"));
  const { callNetease } = await import("@main/apis/netease");
  await expect(callNetease("cloudsearch", { keywords: "晴天" })).rejects.toThrow(
    "search unavailable",
  );
});
it("注册成功保存真实游客令牌", async () => {
  mocks.register.mockResolvedValue({ status: 200, body: { token: "test-token" }, cookie: [] });
  const { callNetease } = await import("@main/apis/netease");
  await callNetease("cloudsearch", { keywords: "晴天" });
  expect(mocks.save).toHaveBeenCalledWith(
    "netease",
    expect.objectContaining({ MUSIC_A: "test-token" }),
  );
});
