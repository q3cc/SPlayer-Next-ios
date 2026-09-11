import { mount, flushPromises } from "@vue/test-utils";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import AirPlayControl from "./AirPlayControl.vue";

const mocks = vi.hoisted(() => ({ invoke: vi.fn(), isIOS: true }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("@/utils/config", () => ({
  get isIOS() {
    return mocks.isIOS;
  },
}));
vi.mock("vue-i18n", () => ({ useI18n: () => ({ t: (key: string) => key }) }));
const frames = new Map<number, FrameRequestCallback>();
let nextFrame = 0;
let bounds = new DOMRect(100, 400, 40, 40);
const wrappers: ReturnType<typeof mount>[] = [];
const create = () => {
  const wrapper = mount(AirPlayControl, {
    attachTo: document.body,
    global: {
      stubs: {
        SButton: { template: '<button><slot name="icon" /></button>' },
        IconLucideAirplay: true,
      },
    },
  });
  wrappers.push(wrapper);
  return wrapper;
};
const tick = async () => {
  const callbacks = [...frames.values()];
  frames.clear();
  callbacks.forEach((callback) => callback(0));
  await flushPromises();
};
beforeEach(() => {
  mocks.isIOS = true;
  mocks.invoke.mockReset().mockResolvedValue({ visible: true });
  frames.clear();
  bounds = new DOMRect(100, 400, 40, 40);
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
    frames.set(++nextFrame, callback);
    return nextFrame;
  });
  vi.stubGlobal("cancelAnimationFrame", (id: number) => frames.delete(id));
  Object.defineProperty(document, "hidden", { configurable: true, value: false });
  vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(() => bounds);
  vi.spyOn(document, "elementFromPoint").mockImplementation(() =>
    document.querySelector("[data-airplay-anchor]"),
  );
});
afterEach(async () => {
  wrappers.splice(0).forEach((wrapper) => wrapper.unmount());
  await flushPromises();
  document.body.innerHTML = "";
  vi.unstubAllGlobals();
});
it("挂载可直接点击的原生入口，传递完整矩形而不是模拟打开弹窗", async () => {
  const wrapper = create();
  await flushPromises();
  expect(mocks.invoke).toHaveBeenCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({
      id: wrapper.attributes("data-airplay-anchor"),
      show: true,
      x: 100,
      y: 400,
      width: 40,
      height: 40,
      label: "player.airPlay",
    }),
  );
  expect(wrapper.find("button").exists()).toBe(false);
});
it("静止时没有重复 IPC，位置和视口改变后同步布局", async () => {
  create();
  await flushPromises();
  await tick();
  await tick();
  expect(mocks.invoke).toHaveBeenCalledTimes(1);
  bounds = new DOMRect(240, 120, 44, 44);
  await tick();
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ x: 240, y: 120, width: 44, height: 44 }),
  );
  vi.stubGlobal("innerWidth", 800);
  await tick();
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ viewportWidth: 800 }),
  );
});
it("弹层遮挡入口时隐藏原生按钮，关闭弹层后恢复", async () => {
  create();
  await flushPromises();
  vi.mocked(document.elementFromPoint).mockReturnValueOnce(document.body);
  await tick();
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ show: false }),
  );
  await tick();
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ show: true }),
  );
});
it.each(["opacity", "inert", "aria-hidden"])("隐藏祖先（%s）不残留原生入口", async (kind) => {
  create();
  await flushPromises();
  if (kind === "opacity") document.body.style.opacity = "0";
  else if (kind === "inert") document.body.inert = true;
  else document.body.setAttribute("aria-hidden", "true");
  await tick();
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ show: false }),
  );
  document.body.style.opacity = "";
  document.body.inert = false;
  document.body.removeAttribute("aria-hidden");
});
it("后台停止布局循环，回到前台恢复原生入口", async () => {
  create();
  await flushPromises();
  Object.defineProperty(document, "hidden", { configurable: true, value: true });
  document.dispatchEvent(new Event("visibilitychange"));
  await flushPromises();
  expect(frames.size).toBe(0);
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ show: false }),
  );
  Object.defineProperty(document, "hidden", { configurable: true, value: false });
  document.dispatchEvent(new Event("visibilitychange"));
  await flushPromises();
  expect(frames.size).toBe(1);
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ show: true }),
  );
});
it("原生响应较慢时合并中间布局，不堆积请求", async () => {
  let finish!: (value: { visible: boolean }) => void;
  mocks.invoke.mockReturnValueOnce(
    new Promise((resolve) => {
      finish = resolve;
    }),
  );
  create();
  await flushPromises();
  bounds = new DOMRect(200, 400, 40, 40);
  await tick();
  bounds = new DOMRect(300, 400, 40, 40);
  await tick();
  expect(mocks.invoke).toHaveBeenCalledTimes(1);
  finish({ visible: true });
  await flushPromises();
  expect(mocks.invoke).toHaveBeenCalledTimes(2);
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ x: 300 }),
  );
});
it("挂载未完成就卸载时，移除请求仍最后执行且不再恢复循环", async () => {
  let finish!: (value: { visible: boolean }) => void;
  mocks.invoke.mockReturnValueOnce(
    new Promise((resolve) => {
      finish = resolve;
    }),
  );
  const wrapper = create();
  await flushPromises();
  const id = wrapper.attributes("data-airplay-anchor");
  wrapper.unmount();
  finish({ visible: true });
  await flushPromises();
  expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:native-audio|airplay", {
    id,
    show: false,
    remove: true,
  });
  expect(frames.size).toBe(0);
  const calls = mocks.invoke.mock.calls.length;
  document.dispatchEvent(new Event("visibilitychange"));
  expect(mocks.invoke).toHaveBeenCalledTimes(calls);
});
it("不同入口独立持有原生控件，卸载不会移除另一个入口", async () => {
  const first = create();
  await flushPromises();
  const second = create();
  await flushPromises();
  expect(first.attributes("data-airplay-anchor")).not.toBe(
    second.attributes("data-airplay-anchor"),
  );
  first.unmount();
  await flushPromises();
  expect(mocks.invoke).toHaveBeenLastCalledWith("plugin:native-audio|airplay", {
    id: first.attributes("data-airplay-anchor"),
    show: false,
    remove: true,
  });
  await tick();
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ id: second.attributes("data-airplay-anchor"), show: true }),
  );
});
it("原生调用失败时显示错误并允许重试", async () => {
  mocks.invoke.mockRejectedValueOnce(new Error("unavailable"));
  const wrapper = create();
  await flushPromises();
  expect(wrapper.get('[role="alert"]').text()).toBe("player.airPlayError");
  await tick();
  expect(mocks.invoke).toHaveBeenCalledTimes(1);
  expect(frames.size).toBe(0);
  await wrapper.get("button").trigger("click");
  await flushPromises();
  expect(mocks.invoke).toHaveBeenCalledTimes(2);
  expect(wrapper.find('[role="alert"]').exists()).toBe(false);
});
it("桌面端不显示 iOS 入口，也不挂载原生控件或布局循环", async () => {
  mocks.isIOS = false;
  const uuid = vi.spyOn(crypto, "randomUUID");
  const wrapper = create();
  expect(wrapper.find("button").exists()).toBe(false);
  await flushPromises();
  expect(mocks.invoke).not.toHaveBeenCalled();
  expect(frames.size).toBe(0);
  expect(uuid).not.toHaveBeenCalled();
});
it("没有有效尺寸时不创建原生控件，布局完成后再显示", async () => {
  bounds = new DOMRect(0, 0, 0, 0);
  create();
  await flushPromises();
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ show: false }),
  );
  bounds = new DOMRect(100, 400, 40, 40);
  await tick();
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ show: true }),
  );
});
it("挂载失败后仍然发送已经排队的卸载请求", async () => {
  let fail!: (reason: Error) => void;
  mocks.invoke.mockReturnValueOnce(
    new Promise((_, reject) => {
      fail = reject;
    }),
  );
  const wrapper = create();
  await flushPromises();
  wrapper.unmount();
  fail(new Error("window closed"));
  await flushPromises();
  expect(mocks.invoke).toHaveBeenLastCalledWith(
    "plugin:native-audio|airplay",
    expect.objectContaining({ show: false, remove: true }),
  );
  expect(frames.size).toBe(0);
});
