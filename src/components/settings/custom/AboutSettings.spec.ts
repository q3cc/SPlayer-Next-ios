import { flushPromises, mount } from "@vue/test-utils";
import { createI18n } from "vue-i18n";
import { afterEach, expect, it, vi } from "vitest";
import type { Contributor } from "@/apis/github";
import AboutSettings from "./AboutSettings.vue";
import zhCN from "@/i18n/locales/zh-CN.json";

const mocks = vi.hoisted(() => ({
  isIOS: true,
  copy: vi.fn(),
  check: vi.fn(),
  contributors: vi.fn(async (_repo?: string, _options?: { since?: string }) => [] as Contributor[]),
}));
vi.mock("@/apis/github", () => ({
  getContributors: mocks.contributors,
  IOS_REPO_SLUG: "q3cc/SPlayer-Next-ios",
  ORIGINAL_REPO_SLUG: "SPlayer-Dev/SPlayer-Next",
}));
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
  REPO_NAME: "SPlayer-Next-ios",
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

it("iOS 贡献者不重复展示原版继承历史，并将两个版本作者标为 Author", async () => {
  mocks.contributors.mockImplementation(async (_repo?: string, options?: { since?: string }) =>
    options?.since
      ? [
          { login: "q3cc", htmlUrl: "https://github.com/q3cc", avatar: "" },
          { login: "imsyy", htmlUrl: "https://github.com/imsyy", avatar: "" },
          { login: "ios-contributor", htmlUrl: "https://github.com/ios-contributor", avatar: "" },
        ]
      : [
          { login: "imsyy", htmlUrl: "https://github.com/imsyy", avatar: "" },
          { login: "upstream-user", htmlUrl: "https://github.com/upstream-user", avatar: "" },
        ],
  );
  vi.stubGlobal("api", {
    system: { osInfo: { type: "iOS", arch: "arm64", release: "" } },
  });
  vi.stubGlobal("electron", undefined);
  const wrapper = mount(AboutSettings, {
    global: {
      plugins: [createI18n({ legacy: false, locale: "zh-CN", messages: { "zh-CN": zhCN } })],
      stubs: {
        SCard: { template: "<div><slot /></div>" },
        SButton: { template: "<button><slot /></button>" },
        STag: { template: "<span><slot /></span>" },
        SLogo: true,
        SImg: true,
        IconLucideCopy: true,
      },
    },
  });
  await flushPromises();
  const text = wrapper.text();
  expect(text).toContain("q3cc");
  expect(text).toContain("ios-contributor");
  expect(text).not.toContain("upstream-user");
  expect(text).toMatch(/q3cc\s+Author/);
  expect(text).toMatch(/imsyy\s+Author/);
  wrapper.unmount();
});
