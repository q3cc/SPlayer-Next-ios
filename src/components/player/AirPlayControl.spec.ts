import { mount, flushPromises } from "@vue/test-utils";
import { beforeEach, expect, it, vi } from "vitest";
import AirPlayControl from "./AirPlayControl.vue";

const mocks = vi.hoisted(() => ({ invoke: vi.fn(), isIOS: true }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("@/utils/config", () => ({
  get isIOS() {
    return mocks.isIOS;
  },
}));
vi.mock("vue-i18n", () => ({ useI18n: () => ({ t: (key: string) => key }) }));
const create = () =>
  mount(AirPlayControl, {
    global: {
      stubs: {
        SButton: { template: '<button><slot name="icon" /></button>' },
        IconLucideAirplay: true,
      },
    },
  });
beforeEach(() => {
  mocks.isIOS = true;
  mocks.invoke.mockReset().mockResolvedValue(undefined);
  Object.defineProperty(document, "hidden", { configurable: true, value: false });
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockReturnValue(
    new DOMRect(100, 400, 44, 44),
  );
});
it("点击隔空播放传递按钮位置并调用原生命令", async () => {
  const wrapper = create();
  await wrapper.get("button").trigger("click");
  await flushPromises();
  expect(mocks.invoke).toHaveBeenCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ x: 122, y: 422 }),
  );
  wrapper.unmount();
});
it("原生调用失败时显示错误并允许重试", async () => {
  mocks.invoke.mockRejectedValueOnce(new Error("unavailable"));
  const wrapper = create();
  await wrapper.get("button").trigger("click");
  await flushPromises();
  expect(wrapper.get('[role="alert"]').text()).toBe("player.airPlayError");
  await wrapper.get("button").trigger("click");
  await flushPromises();
  expect(mocks.invoke).toHaveBeenCalledTimes(2);
  expect(wrapper.find('[role="alert"]').exists()).toBe(false);
  wrapper.unmount();
});
it("桌面端不显示 iOS 入口", () => {
  mocks.isIOS = false;
  const wrapper = create();
  expect(wrapper.find("button").exists()).toBe(false);
  wrapper.unmount();
});
