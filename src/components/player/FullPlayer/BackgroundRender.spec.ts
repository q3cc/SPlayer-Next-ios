import { mount } from "@vue/test-utils";
import { nextTick, ref } from "vue";
import { expect, it, vi } from "vitest";
import BackgroundRender from "./BackgroundRender.vue";

const renderer = vi.hoisted(() => ({
  setAlbum: vi.fn(),
  setFPS: vi.fn(),
  setRenderScale: vi.fn(),
  setHasLyric: vi.fn(),
  setStaticMode: vi.fn(),
  setFlowSpeed: vi.fn(),
  setLowFreqVolume: vi.fn(),
  pause: vi.fn(),
  resume: vi.fn(),
  dispose: vi.fn(),
  getElement: () => document.createElement("canvas"),
}));
const visibility = ref("visible");
vi.mock("@applemusic-like-lyrics/core", () => ({
  BackgroundRender: { new: () => renderer },
  MeshGradientRenderer: class {},
}));
vi.mock("@vueuse/core", () => ({
  useDocumentVisibility: () => visibility,
  useRafFn: () => ({ pause: vi.fn(), resume: vi.fn() }),
}));
vi.mock("@/services/playback", () => ({ getFftFrame: vi.fn() }));
vi.mock("@/services/fftCapture", () => ({ acquireFft: vi.fn(), releaseFft: vi.fn() }));

it("pauses hidden rendering, uses static frames when paused, and disposes on unmount", async () => {
  const wrapper = mount(BackgroundRender, { props: { playing: true } });
  expect(renderer.setStaticMode).toHaveBeenLastCalledWith(false);
  await wrapper.setProps({ playing: false });
  expect(renderer.setStaticMode).toHaveBeenLastCalledWith(true);
  expect(renderer.setFlowSpeed).toHaveBeenLastCalledWith(0);
  renderer.pause.mockClear();
  await wrapper.setProps({ active: false });
  expect(renderer.pause).toHaveBeenCalledOnce();
  await wrapper.setProps({ active: true, playing: true });
  expect(renderer.setStaticMode).toHaveBeenLastCalledWith(false);
  renderer.pause.mockClear();
  visibility.value = "hidden";
  await nextTick();
  expect(renderer.pause).toHaveBeenCalledOnce();
  wrapper.unmount();
  expect(renderer.dispose).toHaveBeenCalledOnce();
});
