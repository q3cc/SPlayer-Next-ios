import { beforeEach, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ invoke: vi.fn(), value: null as string | null }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
beforeEach(() => {
  vi.resetModules();
  mocks.value = null;
  mocks.invoke.mockImplementation(async (_command, args) => {
    expect(args.namespace).toBe("aiModels");
    if (args.action === "set") mocks.value = args.value;
    return { value: mocks.value };
  });
});
const input = {
  name: "测试模型",
  protocol: "openai-compatible" as const,
  baseUrl: "https://example.com/v1",
  model: "test",
  apiKey: "private-test-key",
};
it("首次打开模型配置时通过原生命令读取独立凭证，未配置则返回空列表", async () => {
  const { mobileAiModel } = await import("./aiModels");
  expect(await mobileAiModel.list()).toEqual({ models: [], activeModelId: null });
  expect(mocks.invoke).toHaveBeenCalledExactlyOnceWith("plugin:native-audio|lastfm_credentials", {
    action: "get",
    namespace: "aiModels",
  });
});
it("安全保存模型，不向界面返回密钥；编辑时保留原密钥", async () => {
  const { mobileAiModel } = await import("./aiModels");
  const saved = await mobileAiModel.save(input);
  expect(saved.models[0].hasApiKey).toBe(true);
  expect(JSON.stringify(saved)).not.toContain(input.apiKey);
  const id = saved.models[0].id;
  await mobileAiModel.save({ ...input, id, name: "新名称", apiKey: "" });
  expect(JSON.parse(mocks.value!).models[0].apiKey).toBe(input.apiKey);
  expect((await mobileAiModel.list()).activeModelId).toBe(id);
  await mobileAiModel.remove(id);
  expect(await mobileAiModel.list()).toEqual({ models: [], activeModelId: null });
});
it("拒绝远程明文地址与不存在的活动模型", async () => {
  const { mobileAiModel } = await import("./aiModels");
  await expect(mobileAiModel.save({ ...input, baseUrl: "http://example.com" })).rejects.toThrow(
    "HTTPS",
  );
  await expect(mobileAiModel.setActive("missing")).rejects.toThrow("不存在");
  expect(mocks.value).toBeNull();
});
it("原生对象错误保留可读原因，读取失败不伪装成空配置", async () => {
  const { mobileAiModel } = await import("./aiModels");
  mocks.invoke.mockRejectedValue({ message: "读取安全凭证失败：签名缺少钥匙串权限（-34018）" });
  await expect(mobileAiModel.list()).rejects.toThrow("-34018");
  await expect(mobileAiModel.save(input)).rejects.toThrow("钥匙串权限");
  expect(mocks.value).toBeNull();
  mocks.invoke.mockRejectedValue({ code: "UNKNOWN" });
  await expect(mobileAiModel.list()).rejects.toThrow("无法访问模型的安全存储");
});

it("并发保存不会覆盖其他模型", async () => {
  const { mobileAiModel } = await import("./aiModels");
  await Promise.all([mobileAiModel.save(input), mobileAiModel.save({ ...input, name: "第二个" })]);
  expect((await mobileAiModel.list()).models).toHaveLength(2);
});
