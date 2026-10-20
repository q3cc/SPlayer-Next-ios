import { shallowMount } from "@vue/test-utils";
import { nextTick } from "vue";
import { createI18n } from "vue-i18n";
import { expect, it, vi } from "vitest";
import zhCN from "@/i18n/locales/zh-CN.json";
import enUS from "@/i18n/locales/en-US.json";
import MobileNav from "./MobileNav.vue";

const mocks = vi.hoisted(() => ({ push: vi.fn(), showSettings: vi.fn() }));
vi.mock("vue-router", () => ({
  useRoute: () => ({ path: "/" }),
  useRouter: () => ({ push: mocks.push }),
}));
vi.mock("@/settings/useSettingsDialog", () => ({
  useSettingsDialog: () => ({ show: mocks.showSettings }),
}));

it("底部导航显示完整中文，搜索标签随语言切换并保留搜索入口", async () => {
  const i18n = createI18n({
    legacy: false,
    locale: "zh-CN",
    fallbackLocale: "en-US",
    messages: { "zh-CN": zhCN, "en-US": enUS },
  });
  const wrapper = shallowMount(MobileNav, { global: { plugins: [i18n] } });
  const labels = () => wrapper.findAll(".mobile-nav-item span").map((item) => item.text());
  expect(labels()).toEqual(["首页", "搜索", "音乐库", "我喜欢的音乐", "全局设置"]);
  await wrapper.findAll("button")[1].trigger("click");
  expect(mocks.push).toHaveBeenCalledWith("/search");
  i18n.global.locale.value = "en-US";
  await nextTick();
  expect(labels()[1]).toBe("Search");
  i18n.global.locale.value = "zh-CN";
  await nextTick();
  expect(labels()[1]).toBe("搜索");
  wrapper.unmount();
});
