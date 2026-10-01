import { invoke } from "@tauri-apps/api/core";
import type { AiModelApi, AiModelConfig, AiModelSaveInput, AiModelState } from "@shared/types/ai";

type Saved = Omit<AiModelConfig, "hasApiKey"> & { apiKey: string };
interface SavedState {
  models: Saved[];
  activeModelId: string | null;
}
let serial: Promise<unknown> = Promise.resolve();
const transaction = <T>(run: () => Promise<T>): Promise<T> => {
  const next = serial
    .catch(() => {})
    .then(run)
    .catch((error: unknown) => {
      if (error instanceof Error) throw error;
      const message =
        typeof error === "string"
          ? error
          : error &&
              typeof error === "object" &&
              "message" in error &&
              typeof error.message === "string"
            ? error.message
            : "无法访问模型的安全存储，请检查应用签名与钥匙串权限";
      throw new Error(message);
    });
  serial = next.then(
    () => undefined,
    () => undefined,
  );
  return next;
};
const read = async (): Promise<SavedState> => {
  const { value } = await invoke<{ value: string | null }>(
    "plugin:native-audio|lastfm_credentials",
    { action: "get", namespace: "aiModels" },
  );
  if (!value) return { models: [], activeModelId: null };
  const state = JSON.parse(value) as SavedState;
  if (!Array.isArray(state.models) || state.models.length > 20)
    throw new Error("模型配置损坏，请重新配置");
  return state;
};
const publicState = (state: SavedState): AiModelState => ({
  activeModelId: state.activeModelId,
  models: state.models.map(({ apiKey, ...model }) => ({ ...model, hasApiKey: Boolean(apiKey) })),
});
const write = async (state: SavedState): Promise<AiModelState> => {
  await invoke("plugin:native-audio|lastfm_credentials", {
    action: "set",
    namespace: "aiModels",
    value: JSON.stringify(state),
  });
  return publicState(state);
};

export const mobileAiModel: AiModelApi = {
  list: () => transaction(async () => publicState(await read())),
  save: (input: AiModelSaveInput) =>
    transaction(async () => {
      const state = await read();
      const previous = input.id ? state.models.find((model) => model.id === input.id) : undefined;
      if (input.id && !previous) throw new Error("模型配置不存在");
      if (!previous && state.models.length >= 20) throw new Error("最多保存 20 个模型");
      const name = input.name.trim(),
        model = input.model.trim();
      const url = new URL(input.baseUrl.trim());
      if (
        !name ||
        !model ||
        name.length > 100 ||
        model.length > 200 ||
        !["openai-compatible", "anthropic"].includes(input.protocol)
      )
        throw new Error("请填写有效的模型配置");
      if (
        url.username ||
        url.password ||
        url.search ||
        url.hash ||
        !(
          url.protocol === "https:" ||
          (url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname))
        )
      )
        throw new Error("API 地址须使用 HTTPS，本机服务可使用 HTTP");
      const apiKey = input.apiKey?.trim() || previous?.apiKey || "";
      if (!apiKey || apiKey.length > 8192) throw new Error("请填写有效的 API Key");
      const saved: Saved = {
        id: previous?.id ?? crypto.randomUUID(),
        name,
        model,
        protocol: input.protocol,
        baseUrl: url.href.replace(/\/+$/, ""),
        apiKey,
      };
      if (previous) state.models[state.models.indexOf(previous)] = saved;
      else state.models.push(saved);
      state.activeModelId ??= saved.id;
      return write(state);
    }),
  remove: (id) =>
    transaction(async () => {
      const state = await read();
      state.models = state.models.filter((model) => model.id !== id);
      if (state.activeModelId === id) state.activeModelId = null;
      return write(state);
    }),
  setActive: (id) =>
    transaction(async () => {
      const state = await read();
      if (id !== null && !state.models.some((model) => model.id === id))
        throw new Error("模型配置不存在");
      state.activeModelId = id;
      return write(state);
    }),
};
