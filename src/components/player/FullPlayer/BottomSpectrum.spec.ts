import { mount } from "@vue/test-utils";
import { nextTick, reactive, ref } from "vue";
import { expect, it, vi } from "vitest";
import BottomSpectrum from "./BottomSpectrum.vue";

const visibility = ref("visible");
const status = reactive({ isPlaying: true });
const settings = reactive({ player: { spectrumBarWidth: 3, reverseSpectrum: false } });
const acquire = vi.fn(),
  release = vi.fn(),
  resume = vi.fn(),
  pause = vi.fn();
let draw: () => void;
vi.mock("@vueuse/core", () => ({
  useDocumentVisibility: () => visibility,
  useRafFn: (callback: () => void) => {
    draw = callback;
    return { resume, pause };
  },
}));
vi.mock("@/stores/status", () => ({ useStatusStore: () => status }));
vi.mock("@/stores/settings", () => ({ useSettingsStore: () => settings }));
vi.mock("@/services/fftCapture", () => ({
  acquireFft: () => acquire(),
  releaseFft: () => release(),
}));
vi.mock("@/services/playback", () => ({
  getFftFrame: () => [Array(128).fill(1), Array(128).fill(1)],
}));

it("频谱按缓存尺寸批量绘制，后台停止订阅并在卸载时释放", async () => {
  const context = {
    setTransform: vi.fn(),
    clearRect: vi.fn(),
    beginPath: vi.fn(),
    roundRect: vi.fn(),
    fill: vi.fn(),
    fillStyle: "",
  };
  vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue(
    context as unknown as CanvasRenderingContext2D,
  );
  vi.spyOn(document.body, "clientWidth", "get").mockReturnValue(600);
  const wrapper = mount(BottomSpectrum);
  try {
    const canvas = wrapper.get("canvas").element;
    const widthRead = vi.spyOn(canvas, "clientWidth", "get");
    const heightRead = vi.spyOn(canvas, "clientHeight", "get");
    draw();
    draw();
    expect(widthRead).not.toHaveBeenCalled();
    expect(heightRead).not.toHaveBeenCalled();
    expect(context.beginPath).toHaveBeenCalledTimes(2);
    expect(context.fill).toHaveBeenCalledTimes(2);
    expect(context.roundRect).toHaveBeenCalledTimes(100);
    expect(context.roundRect.mock.calls[0][0]).toBe(0);
    expect(context.roundRect.mock.calls[99][0]).toBe(594);
    expect(acquire).toHaveBeenCalledTimes(1);
    visibility.value = "hidden";
    await nextTick();
    expect(release).toHaveBeenCalledTimes(1);
    visibility.value = "visible";
    await nextTick();
    expect(acquire).toHaveBeenCalledTimes(2);
    await wrapper.setProps({ height: 100 });
    expect(canvas.style.height).toBe("100px");
  } finally {
    wrapper.unmount();
  }
  expect(release).toHaveBeenCalledTimes(2);
});
