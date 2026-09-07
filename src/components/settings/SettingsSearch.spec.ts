import { mount } from "@vue/test-utils";
import { createI18n } from "vue-i18n";
import { afterEach, describe, expect, it, vi } from "vitest";
import SettingsSearch from "./SettingsSearch.vue";
import zhCN from "@/i18n/locales/zh-CN.json";
import enUS from "@/i18n/locales/en-US.json";

vi.mock("@/settings/schema", () => ({
  settingsSchema: [
    { id: "test", sections: [{ items: [{ key: "volume" }] }] },
    { id: "siri", sections: [{ items: [{ key: "siriSettings" }] }] },
  ],
}));

/** 创建只包含搜索交互的设置组件。 */
const createWrapper = () =>
  mount(SettingsSearch, {
    global: {
      plugins: [
        createI18n({
          legacy: false,
          locale: "zh-CN",
          messages: {
            "zh-CN": {
              settings: {
                search: "搜索设置",
                group: { test: "播放", siri: zhCN.settings.group.siri },
                siriSettings: zhCN.settings.siriSettings,
                volume: { label: "音量", description: "调整音量" },
              },
              common: { noData: "无结果" },
            },
          },
        }),
      ],
      stubs: {
        SInput: {
          props: ["modelValue"],
          emits: ["update:modelValue", "focus", "blur"],
          template:
            '<input :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" @focus="$emit(\'focus\')" @blur="$emit(\'blur\')" />',
        },
        IconLucideSearch: true,
      },
    },
  });

afterEach(() => vi.useRealTimers());

describe("设置搜索结果显示", () => {
  it("Siri 搜索使用本地化文案并导航到对应设置项", async () => {
    const wrapper = createWrapper();
    await wrapper.get("input").setValue("Siri");
    expect(wrapper.text()).toContain("Siri 语音控制");
    expect(wrapper.text()).not.toContain("settings.siriSettings");
    expect(enUS.settings.siriSettings.label).toBe("Siri voice control");
    await wrapper.get(".cursor-pointer").trigger("mousedown");
    expect(wrapper.emitted("select")).toEqual([["siri", "siriSettings"]]);
    wrapper.unmount();
  });
  it("收起键盘或失焦后保留结果，清空内容才隐藏", async () => {
    vi.useFakeTimers();
    const wrapper = createWrapper();
    const input = wrapper.get("input");
    await input.trigger("focus");
    await input.setValue("音量");
    expect(wrapper.text()).toContain("调整音量");
    await input.trigger("blur");
    await vi.advanceTimersByTimeAsync(200);
    expect(wrapper.text()).toContain("调整音量");
    expect(wrapper.emitted("active-change")).toEqual([[true]]);
    await input.setValue("");
    expect(wrapper.text()).not.toContain("调整音量");
    expect(wrapper.emitted("active-change")).toEqual([[true], [false]]);
    wrapper.unmount();
  });

  it("无匹配时失焦仍显示空结果，选择匹配项后清空搜索", async () => {
    const wrapper = createWrapper();
    const input = wrapper.get("input");
    await input.setValue("不存在的设置");
    await input.trigger("blur");
    expect(wrapper.text()).toContain("无结果");
    await input.setValue("音量");
    await wrapper.get(".cursor-pointer").trigger("mousedown");
    expect(wrapper.emitted("select")).toEqual([["test", "volume"]]);
    expect(input.element.value).toBe("");
    expect(wrapper.text()).not.toContain("调整音量");
    wrapper.unmount();
  });
});
