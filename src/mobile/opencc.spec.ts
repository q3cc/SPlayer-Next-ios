import { expect, it, vi } from "vitest";
const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
import { mobileOpencc } from "./opencc";

it("单句和批量转换传递完整模式，不吞掉转换失败", async () => {
  invoke.mockResolvedValue(["音樂", ""]);
  expect(await mobileOpencc.convert("音乐", "s2t")).toBe("音樂");
  expect(await mobileOpencc.convertBatch(["音乐", ""], "s2twp")).toEqual(["音樂", ""]);
  expect(invoke).toHaveBeenLastCalledWith("convert_lyrics", {
    texts: ["音乐", ""],
    config: "s2twp",
  });
  invoke.mockRejectedValue(new Error("转换失败"));
  await expect(mobileOpencc.convert("音乐", "s2t")).rejects.toThrow("转换失败");
});
it("关闭转换和空批次不加载原生字典", async () => {
  expect(await mobileOpencc.convertBatch(["音乐"], "none")).toEqual(["音乐"]);
  expect(await mobileOpencc.convertBatch([], "s2t")).toEqual([]);
  expect(invoke).not.toHaveBeenCalled();
});
