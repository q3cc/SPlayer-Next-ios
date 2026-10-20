import { flushPromises, shallowMount } from "@vue/test-utils";
import { createPinia, setActivePinia } from "pinia";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import Library from "./Library.vue";
import { useLibraryStore } from "@/stores/library";

const mocks = vi.hoisted(() => ({ error: vi.fn(), warning: vi.fn() }));
vi.mock("@/composables/useToast", () => ({ toast: mocks }));
vi.mock("@/core/player", () => ({ playFrom: vi.fn() }));
vi.mock("@/components/list/SongList.vue", () => ({ default: { template: "<div />" } }));
vi.mock("vue-i18n", () => ({ useI18n: () => ({ t: (key: string) => key }) }));

let wrapper: ReturnType<typeof shallowMount>;
let store: ReturnType<typeof useLibraryStore>;

beforeEach(() => {
  setActivePinia(createPinia());
  store = useLibraryStore();
  store.initialized = true;
  vi.spyOn(store, "subscribeScanProgress").mockImplementation(() => {});
  vi.spyOn(store, "unsubscribeScanProgress").mockImplementation(() => {});
  vi.spyOn(store, "startScan").mockResolvedValue();
  wrapper = shallowMount(Library, {
    global: {
      stubs: {
        SButton: { name: "SButton", props: ["loading"], template: "<button><slot /></button>" },
        SLoading: true,
        SDropdownMenu: true,
        SInput: true,
        SDialog: true,
        FolderManager: true,
        IconLucideMusic: true,
        IconLucideHardDrive: true,
        IconLucidePlay: true,
        IconLucideRefreshCw: true,
        IconLucideEllipsis: true,
        IconLucideSearch: true,
        IconLucideFolderPlus: true,
      },
    },
  });
});
afterEach(() => wrapper.unmount());

const addButton = () => wrapper.findAllComponents({ name: "SButton" }).at(-1)!;

describe("音乐库添加文件夹", () => {
  it("选择未完成时显示等待状态且不重复打开选择器，完成后扫描", async () => {
    let finish!: (result: { success: boolean }) => void;
    const add = vi.spyOn(store, "addScanDir").mockImplementation(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    await addButton().trigger("click");
    await addButton().trigger("click");
    expect(add).toHaveBeenCalledOnce();
    expect(addButton().props("loading")).toBe(true);
    finish({ success: true });
    await flushPromises();
    expect(store.startScan).toHaveBeenCalledExactlyOnceWith(false);
    expect(addButton().props("loading")).toBe(false);
  });

  it("选择或导入失败时显示错误并允许重试", async () => {
    vi.spyOn(store, "addScanDir").mockResolvedValue({ success: false, error: "无法读取文件夹" });
    await addButton().trigger("click");
    await flushPromises();
    expect(mocks.error).toHaveBeenCalledWith("无法读取文件夹");
    expect(store.startScan).not.toHaveBeenCalled();
    expect(addButton().props("loading")).toBe(false);
  });

  it.each(["canceled", "SCAN_DIR_NOT_SELECTED"])("取消选择不报错也不扫描：%s", async (error) => {
    vi.spyOn(store, "addScanDir").mockResolvedValue({ success: false, error });
    await addButton().trigger("click");
    await flushPromises();
    expect(mocks.error).not.toHaveBeenCalled();
    expect(store.startScan).not.toHaveBeenCalled();
    expect(addButton().props("loading")).toBe(false);
  });

  it("异常抛出时显示错误，重试成功后恢复扫描", async () => {
    const add = vi
      .spyOn(store, "addScanDir")
      .mockRejectedValueOnce(new Error("目录导入失败"))
      .mockResolvedValueOnce({ success: true });
    await addButton().trigger("click");
    await flushPromises();
    expect(mocks.error).toHaveBeenCalledWith("目录导入失败");
    expect(addButton().props("loading")).toBe(false);
    await addButton().trigger("click");
    await flushPromises();
    expect(add).toHaveBeenCalledTimes(2);
    expect(store.startScan).toHaveBeenCalledExactlyOnceWith(false);
  });

  it("目录嵌套时显示已有提示", async () => {
    vi.spyOn(store, "addScanDir").mockResolvedValue({ success: false, error: "nested" });
    await addButton().trigger("click");
    await flushPromises();
    expect(mocks.warning).toHaveBeenCalledWith("library.nestedHint");
    expect(store.startScan).not.toHaveBeenCalled();
  });
});
