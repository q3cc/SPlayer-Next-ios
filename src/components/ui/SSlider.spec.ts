import { mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";
import SSlider from "./SSlider.vue";

const createSlider = () => {
  const wrapper = mount(SSlider, {
    props: { modelValue: 20, min: 0, max: 100, showPopover: false },
  });
  const track = wrapper.get(".s-slider-hitbox-horizontal");
  Object.defineProperty(track.element, "setPointerCapture", { value: vi.fn() });
  vi.spyOn(track.element, "getBoundingClientRect").mockReturnValue({
    left: 0,
    top: 0,
    width: 100,
    height: 14,
  } as DOMRect);
  return { wrapper, track };
};

describe("滑块触屏操作", () => {
  it("只跟随按下的手指，并以松手位置提交", async () => {
    const { wrapper, track } = createSlider();
    const touch = { pointerId: 1, pointerType: "touch", isPrimary: true, button: 0, clientY: 7 };
    await track.trigger("pointerdown", { ...touch, clientX: 30 });
    await track.trigger("pointermove", { ...touch, pointerId: 2, clientX: 90 });
    await track.trigger("pointerup", { ...touch, pointerId: 2, clientX: 90 });
    expect(wrapper.emitted("change")).toEqual([[30]]);
    expect(wrapper.emitted("dragEnd")).toBeUndefined();

    await track.trigger("pointermove", { ...touch, clientX: 70 });
    await track.trigger("pointerup", { ...touch, clientX: 75 });
    expect(wrapper.emitted("dragEnd")).toEqual([[75]]);
    expect(wrapper.emitted("update:modelValue")).toEqual([[75]]);
    wrapper.unmount();
  });

  it("系统取消触摸或丢失指针捕获时不跳转进度", async () => {
    const { wrapper, track } = createSlider();
    const touch = { pointerId: 1, pointerType: "touch", isPrimary: true, button: 0, clientY: 7 };
    await track.trigger("pointerdown", { ...touch, clientX: 30 });
    await track.trigger("pointermove", { ...touch, clientX: 70 });
    await track.trigger("pointercancel", touch);
    expect(wrapper.emitted("dragEnd")).toBeUndefined();
    expect(wrapper.emitted("update:modelValue")).toBeUndefined();
    expect(wrapper.get(".s-slider").attributes("style")).toContain("20%");

    await track.trigger("pointerdown", { ...touch, clientX: 40 });
    await track.trigger("lostpointercapture", touch);
    await track.trigger("pointerup", { ...touch, clientX: 80 });
    expect(wrapper.emitted("dragEnd")).toBeUndefined();
    wrapper.unmount();
  });
});
