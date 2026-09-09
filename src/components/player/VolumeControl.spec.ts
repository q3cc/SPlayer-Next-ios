import { mount, flushPromises } from "@vue/test-utils";
import { beforeEach, expect, it, vi } from "vitest";
import VolumeControl from "./VolumeControl.vue";

const mocks = vi.hoisted(() => ({
  invoke: vi.fn().mockResolvedValue({ volume: 0.5 }),
  status: { volume: 0.5, isPlayerExpanded: true },
}));
vi.mock("@/stores/status", () => ({ useStatusStore: () => mocks.status }));
vi.mock("@/core/player", () => ({ setVolume: vi.fn() }));
vi.mock("@/utils/config", () => ({ isIOS: true }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
const create = (cover: boolean) =>
  mount(VolumeControl, {
    props: { cover },
    global: {
      stubs: {
        SPopover: { template: '<div><slot name="trigger" /><slot /></div>' },
        SButton: { template: '<button><slot name="icon" /></button>' },
        SSlider: true,
        IconLucideVolume2: true,
      },
    },
  });
beforeEach(() => {
  Object.defineProperty(document, "hidden", { configurable: true, value: false });
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockReturnValue(
    new DOMRect(50, 500, 40, 40),
  );
  mocks.status.isPlayerExpanded = true;
  mocks.invoke.mockClear();
});
it("播放器第一次点击就请求原生音量条，不切换静音", async () => {
  const wrapper = create(true);
  await wrapper.get("button").trigger("click");
  await flushPromises();
  expect(mocks.invoke).toHaveBeenCalledWith(
    "plugin:native-audio|system_volume",
    expect.objectContaining({ show: true, x: 70, y: 500 }),
  );
  wrapper.unmount();
});
it("实体按键只唤出当前播放器的滑条，不让隐藏工具栏抢位置", async () => {
  const bar = create(false),
    full = create(true);
  window.dispatchEvent(new CustomEvent("splayer:system-volume", { detail: 0.7 }));
  await flushPromises();
  expect(mocks.status.volume).toBe(0.7);
  expect(mocks.invoke.mock.calls.filter(([, args]) => args.show === true)).toHaveLength(1);
  bar.unmount();
  full.unmount();
});
