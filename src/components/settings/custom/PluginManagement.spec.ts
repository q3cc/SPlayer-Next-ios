import { flushPromises, mount } from "@vue/test-utils";
import { createPinia, setActivePinia } from "pinia";
import { createI18n } from "vue-i18n";
import { beforeEach, expect, it, vi } from "vitest";
import { usePluginsStore } from "@/stores/plugins";
import type { PluginInfo } from "@shared/types/plugin";
import zhCN from "@/i18n/locales/zh-CN.json";
import PluginList from "./PluginList.vue";
import PluginCard from "./PluginCard.vue";

const mocks = vi.hoisted(() => ({ open: vi.fn() }));
vi.mock("@/utils/url", () => ({
  isExternalUrl: (url?: string) => /^https?:\/\//.test(url ?? ""),
  openExternal: mocks.open,
}));

const info = (
  state: "unloaded" | "loading" | "ready" | "error" = "ready",
  updateUrl?: string,
): PluginInfo => ({
  manifest: {
    id: "test",
    name: "测试音源",
    version: "1",
    grant: ["network"],
    apiLevel: 1,
    hash: "test",
    installedAt: 0,
    fileName: "test.js",
    updateUrl,
  },
  enabled: true,
  status:
    state === "ready"
      ? { state, sources: {} }
      : state === "error"
        ? { state, error: { code: "PLUGIN_SCRIPT_ERROR", message: "初始化失败" } }
        : { state },
  updateInfo: { log: "新版说明", updateUrl: "https://example.com/download", updatedAt: 1 },
});
const i18n = () => createI18n({ legacy: false, locale: "zh-CN", messages: { "zh-CN": zhCN } });
const button = { template: "<button><slot /></button>" };
const iconStubs = Object.fromEntries(
  [
    "ArrowUpCircle",
    "RefreshCw",
    "ArrowRight",
    "BookOpen",
    "CircleCheck",
    "ExternalLink",
    "MoreHorizontal",
    "Power",
    "Puzzle",
    "Upload",
  ].map((name) => [`IconLucide${name}`, true]),
);

beforeEach(() => {
  setActivePinia(createPinia());
  mocks.open.mockClear();
});

it.each([
  [undefined, true],
  ["https://example.com/plugin.js", true],
  ["https://example.com/plugin.js", false],
] as const)("更新地址=%s，LX 手动通知=%s", async (updateUrl, manual) => {
  const store = usePluginsStore();
  store.list = [info("ready", updateUrl)];
  store.list[0].updateInfo!.manual = manual;
  store.loaded = true;
  const wrapper = mount(PluginList, {
    global: {
      plugins: [i18n()],
      stubs: {
        ...iconStubs,
        PluginCard: {
          props: ["info"],
          template: "<button @click=\"$emit('viewUpdate', info.manifest.id)\">显示更新</button>",
        },
        SDialog: {
          props: ["open"],
          template: '<div v-if="open"><slot /><slot name="footer" :close="() => {}" /></div>',
        },
        SButton: button,
        STabs: true,
        STag: { template: "<span><slot /></span>" },
        SEmpty: true,
        PluginMarket: true,
        PluginDetailDialog: true,
        PluginSettingsForm: true,
      },
    },
  });
  await wrapper
    .findAll("button")
    .find((item) => item.text() === "显示更新")!
    .trigger("click");
  await flushPromises();
  const buttons = wrapper.findAll("button");
  expect(buttons.some((item) => item.text() === zhCN.settings.plugins.update)).toBe(
    Boolean(updateUrl) && !manual,
  );
  expect(wrapper.text().includes(zhCN.settings.plugins.manualUpdateHint)).toBe(
    !updateUrl || manual,
  );
  await buttons
    .find((item) => item.text() === zhCN.settings.plugins.openUpdateUrl)!
    .trigger("click");
  expect(mocks.open).toHaveBeenCalledWith("https://example.com/download");
  wrapper.unmount();
});

it.each(["unloaded", "loading", "ready", "error"] as const)("音源卡片区分 %s 状态", (state) => {
  const wrapper = mount(PluginCard, {
    props: { info: info(state) },
    global: {
      plugins: [i18n()],
      stubs: {
        ...iconStubs,
        SDropdownMenu: true,
        PluginCardBase: { template: '<div><slot name="title-end" /><slot name="extra" /></div>' },
        STag: { template: "<span><slot /></span>" },
        SButton: button,
      },
    },
  });
  expect(wrapper.text()).toContain(zhCN.settings.plugins.status[state]);
  wrapper.unmount();
});
