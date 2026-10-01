import { expect, it, vi } from "vitest";
vi.mock("@/utils/config", () => ({ isMobile: true, isIOS: true }));
vi.mock("@/stores/settings", () => ({ useSettingsStore: vi.fn() }));
vi.mock("@/composables/useToast", () => ({ toast: {} }));
vi.mock("@/i18n", () => ({ default: {} }));
vi.mock("@/components/settings/custom/DeviceSelector.vue", () => ({ default: {} }));
vi.mock("@/components/settings/custom/ExternalApiStatusCard.vue", () => ({ default: {} }));
vi.mock("@/components/settings/custom/LastfmPanel.vue", () => ({ default: {} }));
import player from "./player";
import services from "./services";

it("移动端显示淡入淡出、标准化及独立频谱设置区", () => {
  const controls = player.sections!.find((section) => section.id === "playControl")!;
  expect(controls.items.map((item) => item.key)).toEqual(
    expect.arrayContaining(["fadeEnabled", "loudnessNormalization"]),
  );
  expect(controls.items.every((item) => Boolean(item.key) && !("id" in item))).toBe(true);
  expect(player.sections!.find((section) => section.id === "musicSpectrum")?.items[0].key).toBe(
    "enableSpectrum",
  );
  expect(player.sections!.some((section) => section.id === "device")).toBe(false);
});
it("移动端显示 Last.fm 但不开放仍不支持的桌面服务", () => {
  const ids = services.sections!.map((section) => section.id);
  expect(ids).toContain("lastfm");
  expect(ids).not.toContain("discord");
  expect(ids).not.toContain("externalApi");
});
