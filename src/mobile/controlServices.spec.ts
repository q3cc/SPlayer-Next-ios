import { beforeEach, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({
  invoke: vi.fn(),
  listen: vi.fn(),
  get: vi.fn(),
  set: vi.fn(),
  handler: undefined as undefined | ((event: { payload: unknown }) => void),
}));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("@tauri-apps/api/event", () => ({ listen: mocks.listen }));
vi.mock("./shims/store", () => ({ store: { get: mocks.get, set: mocks.set } }));
vi.mock("./controlTools", () => ({ runControlTool: async () => ({ ok: true }) }));
beforeEach(() => {
  vi.resetModules();
  mocks.invoke.mockReset().mockResolvedValue({ listening: true });
  mocks.listen.mockImplementation(async (_event, handler) => {
    mocks.handler = handler;
    return () => {};
  });
  mocks.get.mockImplementation((path: string) =>
    path.endsWith("accessKey") ? "a".repeat(64) : { enabled: true, port: 14559, allowLan: false },
  );
  vi.spyOn(document, "hidden", "get").mockReturnValue(false);
});
it("同时重启按顺序完成，监听只注册一次", async () => {
  const { mobileMcp } = await import("./controlServices");
  await Promise.all([mobileMcp.restart(), mobileMcp.restart()]);
  expect(mocks.invoke.mock.calls.map(([command]) => command)).toEqual([
    "control_stop",
    "control_start",
    "control_stop",
    "control_start",
  ]);
  expect(mocks.listen).toHaveBeenCalledOnce();
});
it("后台不启动服务，启动失败保留错误", async () => {
  const { mobileMcp } = await import("./controlServices");
  vi.spyOn(document, "hidden", "get").mockReturnValue(true);
  expect((await mobileMcp.restart()).listening).toBe(false);
  expect(mocks.invoke).not.toHaveBeenCalledWith("control_start", expect.anything());
  vi.spyOn(document, "hidden", "get").mockReturnValue(false);
  mocks.invoke.mockImplementation(async (command) => {
    if (command === "control_start") throw new Error("occupied");
  });
  expect((await mobileMcp.restart()).error?.message).toContain("occupied");
});
it("REST 拒绝未知路径和错误方法", async () => {
  const { initializeControlServices } = await import("./controlServices");
  await initializeControlServices();
  mocks.handler!({
    payload: { id: 1, kind: "external", method: "GET", path: "/api/pause", body: "" },
  });
  await vi.waitFor(() =>
    expect(mocks.invoke).toHaveBeenCalledWith(
      "control_reply",
      expect.objectContaining({ id: 1, reply: expect.objectContaining({ status: 405 }) }),
    ),
  );
  mocks.handler!({
    payload: { id: 2, kind: "external", method: "POST", path: "/api/arbitrary", body: "{}" },
  });
  await vi.waitFor(() =>
    expect(mocks.invoke).toHaveBeenCalledWith(
      "control_reply",
      expect.objectContaining({ id: 2, reply: expect.objectContaining({ status: 404 }) }),
    ),
  );
});
