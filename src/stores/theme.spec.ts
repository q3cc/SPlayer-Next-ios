import { afterEach, expect, it, vi } from "vitest";
import { createPinia, setActivePinia } from "pinia";
import { nextTick } from "vue";
import { useThemeStore } from "./theme";

const mocks = vi.hoisted(() => ({ observe: vi.fn(), apply: vi.fn() }));
vi.mock("@/mobile/systemAppearance", () => ({ observeSystemAppearance: mocks.observe }));
vi.mock("@/utils/color", () => ({
  DEFAULT_PRIMARY: "#ff0000",
  SOLID_PALETTE_LIGHT: {},
  SOLID_PALETTE_DARK: {},
  generatePalette: () => ({}),
  applyThemeToDOM: mocks.apply,
  extractColorFromImageUrl: vi.fn().mockResolvedValue(null),
}));
afterEach(() => vi.unstubAllEnvs());

it("跟随原生系统主题，但不覆盖手动深浅色选择", async () => {
  vi.stubEnv("MODE", "mobile");
  setActivePinia(createPinia());
  let update!: (dark: boolean) => void;
  const stop = vi.fn();
  mocks.observe.mockImplementation(async (callback) => {
    update = callback;
    return stop;
  });
  const theme = useThemeStore();
  theme.init();
  await vi.waitFor(() => expect(update).toBeDefined());
  update(true);
  await nextTick();
  expect(theme.isDark).toBe(true);
  update(false);
  await nextTick();
  expect(theme.isDark).toBe(false);
  theme.mode = "dark";
  update(false);
  expect(theme.isDark).toBe(true);
  theme.mode = "light";
  update(true);
  expect(theme.isDark).toBe(false);
  theme.mode = "system";
  expect(theme.isDark).toBe(true);
  theme.$dispose();
  expect(stop).toHaveBeenCalled();
});
