import { mount } from "@vue/test-utils";
import { defineComponent, nextTick, ref } from "vue";
import { afterEach, expect, it, vi } from "vitest";
import { useImmersiveMode } from "./useImmersiveMode";

vi.mock("@/stores/settings", () => ({
  useSettingsStore: () => ({ player: { autoImmersive: false } }),
}));
vi.mock("@/utils/config", () => ({ isIOS: true }));
afterEach(() => vi.useRealTimers());

it("展开五秒自动隐藏，操作恢复，拖动期间不隐藏，收起清理计时", async () => {
  vi.useFakeTimers();
  const expanded = ref(false);
  let controls!: ReturnType<typeof useImmersiveMode>;
  const wrapper = mount(
    defineComponent({
      setup() {
        controls = useImmersiveMode(expanded);
        return () => null;
      },
    }),
  );
  expanded.value = true;
  await nextTick();
  vi.advanceTimersByTime(4999);
  expect(controls.immersive.value).toBe(false);
  vi.advanceTimersByTime(1);
  expect(controls.immersive.value).toBe(true);
  controls.onPointerDown();
  vi.advanceTimersByTime(10000);
  expect(controls.immersive.value).toBe(false);
  controls.onPointerUp();
  vi.advanceTimersByTime(5000);
  expect(controls.immersive.value).toBe(true);
  controls.onActivity();
  expect(controls.immersive.value).toBe(false);
  expanded.value = false;
  await nextTick();
  vi.advanceTimersByTime(5000);
  expect(controls.immersive.value).toBe(false);
  wrapper.unmount();
  expect(vi.getTimerCount()).toBe(0);
});
