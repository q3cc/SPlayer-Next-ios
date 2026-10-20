import { afterEach, describe, expect, it, vi } from "vitest";
import { store } from "./shims/store";
import { startFolderTrace } from "./folderTrace";

afterEach(() => {
  store.set("system.diagnosticLogging", false);
});

describe("文件夹诊断", () => {
  it("关闭时不生成原生诊断标识或输出日志", () => {
    store.set("system.diagnosticLogging", false);
    const output = vi.spyOn(console, "info").mockImplementation(() => {});
    const trace = startFolderTrace();
    trace.log("open-call");
    expect(trace.id).toBeUndefined();
    expect(output).not.toHaveBeenCalled();
  });

  it("同一操作复用标识，不同操作隔离，关闭开关后停止网页输出", () => {
    store.set("system.diagnosticLogging", true);
    const output = vi.spyOn(console, "info").mockImplementation(() => {});
    const trace = startFolderTrace();
    expect(trace.id).toMatch(/^[a-f0-9-]{36}$/);
    expect(startFolderTrace().id).not.toBe(trace.id);
    trace.log("open-call");
    trace.log("open-return");
    expect(output.mock.calls.map((call) => call[1].id)).toEqual([trace.id, trace.id]);
    store.set("system.diagnosticLogging", false);
    trace.log("add-finished");
    expect(output).toHaveBeenCalledTimes(2);
  });
});
