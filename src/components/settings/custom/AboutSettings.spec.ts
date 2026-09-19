import { flushPromises, mount } from "@vue/test-utils";
import { createI18n } from "vue-i18n";
import { afterEach, expect, it, vi } from "vitest";
import AboutSettings from "./AboutSettings.vue";
import zhCN from "@/i18n/locales/zh-CN.json";

const mocks = vi.hoisted(() => ({
  isIOS: true,
  copy: vi.fn(),
  check: vi.fn(),
  contributors: vi.fn(async () => []),
}));
vi.mock("@/apis/github", () => ({ getContributors: mocks.contributors }));
vi.mock("@/composables/useCopyText", () => ({ useCopyText: () => ({ copy: mocks.copy }) }));
vi.mock("@/stores/update", () => ({
  useUpdateStore: () => ({ phase: "idle", hasUpdate: false, checkManually: mocks.check }),
}));
vi.mock("@/utils/url", () => ({ openExternal: vi.fn() }));
vi.mock("@/utils/config", () => ({
  get isIOS() {
    return mocks.isIOS;
  },
  APP_VERSION: "2.0.0",
  REPO_URL: "https://github.com/q3cc/SPlayer-Next-ios",
  REPO_NAME: "SPlayer-Next",
  HOMEPAGE_URL: "https://github.com/q3cc/SPlayer-Next-ios",
  COPYRIGHT_HOLDER: "imsyy",
  IS_APPX: false,
  COMMIT_HASH: "1234567",
  COMMIT_DATE: "2026-09-01",
}));

afterEach(() => vi.unstubAllGlobals());

it.each([true, false])("关于页在移动端=%s 时可以渲染、复制环境和检查更新", async (mobile) => {
  mocks.isIOS = mobile;
  vi.stubGlobal("api", {
    system: { osInfo: { type: mobile ? "iOS" : "Windows", arch: "arm64", release: "" } },
  });
  vi.stubGlobal(
    "electron",
    mobile
      ? undefined
      : { process: { versions: { electron: "43", chrome: "1", node: "22", v8: "1" } } },
  );
  const wrapper = mount(AboutSettings, {
    global: {
      plugins: [createI18n({ legacy: false, locale: "zh-CN", messages: { "zh-CN": zhCN } })],
      stubs: {
        SCard: { template: "<div><slot /></div>" },
        SButton: { template: "<button><slot /></button>" },
        STag: { template: "<span><slot /></span>" },
        SLogo: true,
        IconLucideCopy: true,
      },
    },
  });
  await flushPromises();
  expect(wrapper.text()).toContain("SPlayer-Next");
  expect(wrapper.text()).toContain("v2.0.0");
  expect(wrapper.text().includes("Electron:")).toBe(!mobile);
  expect(wrapper.text().includes(zhCN.settings.about.openLogs)).toBe(!mobile);
  await wrapper
    .findAll("button")
    .find((button) => button.text() === zhCN.settings.about.checkUpdate)!
    .trigger("click");
  expect(mocks.check).toHaveBeenCalled();
  await wrapper.findAll("button").at(-1)!.trigger("click");
  expect(mocks.copy).toHaveBeenCalledWith(expect.stringContaining(mobile ? "iOS" : "Windows"));
  wrapper.unmount();
});
