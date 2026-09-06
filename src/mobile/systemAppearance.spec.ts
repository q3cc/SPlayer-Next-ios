import { afterEach, expect, it, vi } from "vitest";
import { observeSystemAppearance } from "./systemAppearance";

const mocks = vi.hoisted(() => ({ invoke: vi.fn(), listener: vi.fn(), unregister: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({
  isTauri: () => true,
  invoke: mocks.invoke,
  addPluginListener: mocks.listener,
}));
afterEach(() => vi.restoreAllMocks());

it("原生外观变化立即同步，返回前台重新读取，退出后释放监听", async () => {
  let event!: (value: { dark: boolean }) => void;
  vi.spyOn(document, "hidden", "get").mockReturnValue(false);
  mocks.listener.mockImplementation(async (_plugin, _event, callback) => {
    event = callback;
    return { unregister: mocks.unregister };
  });
  mocks.invoke.mockResolvedValue({ dark: false });
  const update = vi.fn();
  const stop = await observeSystemAppearance(update);
  expect(update).toHaveBeenLastCalledWith(false);
  event({ dark: true });
  expect(update).toHaveBeenLastCalledWith(true);
  document.dispatchEvent(new Event("visibilitychange"));
  await vi.waitFor(() => expect(update).toHaveBeenLastCalledWith(false));
  stop();
  mocks.invoke.mockClear();
  document.dispatchEvent(new Event("visibilitychange"));
  expect(mocks.invoke).not.toHaveBeenCalled();
  expect(mocks.unregister).toHaveBeenCalled();
});

it("较晚返回的查询不覆盖更新的原生主题通知", async () => {
  let event!: (value: { dark: boolean }) => void;
  let resolve!: (value: { dark: boolean }) => void;
  vi.spyOn(document, "hidden", "get").mockReturnValue(false);
  mocks.listener.mockImplementation(async (_plugin, _event, callback) => {
    event = callback;
    return { unregister: mocks.unregister };
  });
  mocks.invoke.mockImplementation(
    () =>
      new Promise((done) => {
        resolve = done;
      }),
  );
  const update = vi.fn();
  const pending = observeSystemAppearance(update);
  await vi.waitFor(() => expect(resolve).toBeDefined());
  event({ dark: true });
  resolve({ dark: false });
  const stop = await pending;
  expect(update).toHaveBeenCalledTimes(1);
  expect(update).toHaveBeenLastCalledWith(true);
  stop();
});
