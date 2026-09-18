import { createPinia, disposePinia, setActivePinia } from "pinia";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { useCloudUploadStore } from "./cloudUpload";

const mocks = vi.hoisted(() => ({
  pick: vi.fn(),
  upload: vi.fn(),
  error: vi.fn(),
  warning: vi.fn(),
  off: vi.fn(),
}));
vi.mock("@/i18n", () => ({ default: { global: { t: (key: string) => key } } }));
vi.mock("@/composables/useToast", () => ({
  toast: { error: mocks.error, warning: mocks.warning },
}));
vi.mock("@/stores/user", () => ({
  useUserStore: () => ({ cloudMaxSize: 10000, cloudSize: 0, refreshCloud: vi.fn() }),
}));
let pinia: ReturnType<typeof createPinia>;
beforeEach(() => {
  pinia = createPinia();
  setActivePinia(pinia);
  mocks.pick.mockReset();
  mocks.upload.mockReset().mockResolvedValue({ success: false });
  mocks.error.mockClear();
  Object.defineProperty(window, "api", {
    configurable: true,
    value: {
      cloud: { pickSongs: mocks.pick, uploadSong: mocks.upload, onUploadProgress: () => mocks.off },
    },
  });
});
afterEach(() => disposePinia(pinia));

it("重复点击只打开一次，取消后可再次选择", async () => {
  let finish!: (files: []) => void;
  mocks.pick.mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  );
  const store = useCloudUploadStore();
  const first = store.pickAndEnqueue();
  expect(store.picking).toBe(true);
  await store.pickAndEnqueue();
  expect(mocks.pick).toHaveBeenCalledTimes(1);
  finish([]);
  await first;
  expect(store.picking).toBe(false);
  expect(store.items).toEqual([]);
  mocks.pick.mockResolvedValue([]);
  await store.pickAndEnqueue();
  expect(mocks.pick).toHaveBeenCalledTimes(2);
});

it("选择失败提示错误并释放按钮", async () => {
  mocks.pick.mockRejectedValue(new Error("permission denied"));
  const store = useCloudUploadStore();
  await store.pickAndEnqueue();
  expect(store.picking).toBe(false);
  expect(mocks.error).toHaveBeenCalledWith("cloud.upload.pickFailed");
  expect(mocks.upload).not.toHaveBeenCalled();
});

it("选择成功后将文件送入上传队列", async () => {
  mocks.pick.mockResolvedValue([{ path: "/song.mp3", name: "song.mp3", size: 5 }]);
  const store = useCloudUploadStore();
  await store.pickAndEnqueue();
  expect(store.items).toHaveLength(1);
  expect(mocks.upload).toHaveBeenCalledWith("/song.mp3", expect.any(String));
  expect(store.picking).toBe(false);
});

it("待上传队列有上限，不会因多选文件无限增长", async () => {
  let finish!: (value: { success: boolean }) => void;
  mocks.upload.mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  );
  const store = useCloudUploadStore();
  store.enqueue(
    Array.from({ length: 201 }, (_, index) => ({
      path: "/song-" + index + ".mp3",
      name: "song.mp3",
      size: 1,
    })),
  );
  expect(store.items).toHaveLength(200);
  expect(mocks.warning).toHaveBeenCalledWith("cloud.upload.queueFull");
  finish({ success: false });
  await vi.waitFor(() => expect(store.activeCount).toBe(0));
});

it("销毁 store 时释放上传进度订阅", async () => {
  mocks.off.mockClear();
  const store = useCloudUploadStore();
  store.enqueue([{ path: "/song.mp3", name: "song.mp3", size: 1 }]);
  await vi.waitFor(() => expect(store.activeCount).toBe(0));
  store.$dispose();
  expect(mocks.off).toHaveBeenCalledOnce();
});
