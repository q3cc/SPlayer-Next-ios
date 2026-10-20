import { afterEach, beforeEach, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({
  invoke: vi.fn(),
  open: vi.fn(),
  token: vi.fn(),
  session: vi.fn(),
  love: vi.fn(),
  now: vi.fn(),
  scrobble: vi.fn(),
  enabled: true,
}));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: mocks.open }));
vi.mock("./shims/store", () => ({
  store: {
    get: () => ({ enabled: mocks.enabled, loveSync: true, nowPlaying: true, scrobble: true }),
  },
}));
vi.mock("@main/services/lastfm/client", () => ({
  getToken: mocks.token,
  getSession: mocks.session,
  getAuthUrl: () => "https://www.last.fm/api/auth/",
  love: mocks.love,
  updateNowPlaying: mocks.now,
  scrobble: mocks.scrobble,
}));

beforeEach(() => {
  vi.resetModules();
  vi.resetAllMocks();
  vi.useFakeTimers();
  mocks.enabled = true;
  mocks.invoke.mockResolvedValue({ value: null });
  mocks.token.mockResolvedValue("token");
  mocks.session.mockResolvedValue({ name: "listener", key: "session-key" });
});
afterEach(() => vi.useRealTimers());
it("授权成功后写入系统安全存储，再报告已连接", async () => {
  const { mobileLastfm } = await import("./lastfm");
  const task = mobileLastfm.connect();
  await vi.advanceTimersByTimeAsync(3001);
  expect(await task).toEqual({ connected: true, username: "listener" });
  expect(mocks.invoke).toHaveBeenCalledWith("plugin:native-audio|lastfm_credentials", {
    action: "set",
    value: JSON.stringify({ username: "listener", sessionKey: "session-key" }),
  });
  await mobileLastfm.love("歌手", "歌曲", true);
  expect(mocks.love).toHaveBeenCalledWith("session-key", "歌曲", "歌手", true);
  await mobileLastfm.disconnect();
  expect(await mobileLastfm.getStatus()).toEqual({ connected: false, username: "" });
});
it("取消浏览器授权后不写入会话", async () => {
  const { mobileLastfm } = await import("./lastfm");
  const task = mobileLastfm.connect();
  await vi.advanceTimersByTimeAsync(1);
  await mobileLastfm.cancelConnect();
  expect(await task).toEqual({ connected: false, reason: "canceled" });
  expect(mocks.session).not.toHaveBeenCalled();
});
it("安全存储失败不能报告连接成功", async () => {
  mocks.invoke.mockImplementation(async (_command, args) => {
    if (args.action === "set") throw new Error("locked");
    return { value: null };
  });
  const { mobileLastfm } = await import("./lastfm");
  const task = mobileLastfm.connect();
  await vi.advanceTimersByTimeAsync(3001);
  expect(await task).toEqual({ connected: false, reason: "error" });
});
it("播放事件驱动上报，关闭总开关不发送", async () => {
  mocks.invoke.mockResolvedValue({
    value: JSON.stringify({ username: "listener", sessionKey: "key" }),
  });
  const { lastfmTrackLoaded, lastfmPlayerEvent } = await import("./lastfm");
  const track = {
    title: "歌曲",
    artists: [{ name: "歌手" }],
    duration: 60000,
  } as import("@shared/types/player").Track;
  await lastfmTrackLoaded(track, 60000, true);
  await vi.advanceTimersByTimeAsync(1);
  expect(mocks.now).toHaveBeenCalledOnce();
  await vi.advanceTimersByTimeAsync(31000);
  lastfmPlayerEvent({ type: "position", data: { position: 31000, duration: 60000 } });
  await vi.advanceTimersByTimeAsync(1);
  expect(mocks.scrobble).toHaveBeenCalledOnce();
  mocks.enabled = false;
  await lastfmTrackLoaded(track, 60000, true);
  expect(mocks.now).toHaveBeenCalledOnce();
});
