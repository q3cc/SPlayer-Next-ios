import { mount, flushPromises } from "@vue/test-utils";
import { defineComponent } from "vue";
import { afterEach, expect, it, vi } from "vitest";
import { useRecognitionSession } from "./useRecognitionSession";

const mocks = vi.hoisted(() => ({
  capture: vi.fn(),
  start: vi.fn(),
  submit: vi.fn(),
}));
vi.mock("@/utils/config", () => ({ isMobile: true, isIOS: true }));
vi.mock("@/core/player", () => ({ pause: vi.fn(), play: vi.fn() }));
vi.mock("@/stores/status", () => ({ useStatusStore: () => ({ isPlaying: false }) }));
vi.mock("@/services/recognition/microphoneCapture", () => ({
  captureMicrophone: mocks.capture,
  waitCapture: async () => {},
}));

afterEach(() => vi.unstubAllGlobals());

it("移动端支持系统采集时，麦克风仍单独请求麦克风授权", async () => {
  const pcm = new Float32Array(8000);
  const close = vi.fn();
  mocks.capture.mockResolvedValue({ stop: async () => pcm, close });
  vi.stubGlobal("api", {
    recognition: {
      isSupported: async () => true,
      start: mocks.start,
      submitPcm: mocks.submit,
      cancel: async () => {},
      onEvent: () => () => {},
    },
  });
  let session!: ReturnType<typeof useRecognitionSession>;
  const wrapper = mount(
    defineComponent({
      setup() {
        session = useRecognitionSession();
        return () => null;
      },
    }),
  );
  await flushPromises();
  await session.start("microphone");
  expect(mocks.capture).toHaveBeenCalledOnce();
  expect(mocks.start).not.toHaveBeenCalled();
  expect(mocks.submit).toHaveBeenCalledWith(pcm);
  expect(close).toHaveBeenCalledOnce();
  wrapper.unmount();
});
