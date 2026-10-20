import { mount, flushPromises } from "@vue/test-utils";
import { createI18n } from "vue-i18n";
import { ref } from "vue";
import { beforeEach, describe, expect, it, vi } from "vitest";
import SettingsItem from "./SettingsItem.vue";
import downloadCategory from "@/settings/categories/download";
import zhCN from "@/i18n/locales/zh-CN.json";

const mocks = vi.hoisted(() => ({ confirm: vi.fn(), model: undefined as unknown }));
vi.mock("@/utils/config", () => ({ isIOS: true, isMobile: true }));
vi.mock("@/settings/useSettingModel", () => ({ useSettingModel: () => mocks.model }));
vi.mock("@/composables/useDialog", () => ({ dialog: { confirm: mocks.confirm } }));

beforeEach(() => {
  mocks.model = ref(false);
  mocks.confirm.mockReset();
});

const item = downloadCategory
  .sections!.flatMap((section) => section.items)
  .find((entry) => entry.key === "downloadEnabled")!;
const createWrapper = () =>
  mount(SettingsItem, {
    props: { item },
    global: {
      plugins: [createI18n({ legacy: false, locale: "zh-CN", messages: { "zh-CN": zhCN } })],
      stubs: {
        SNumberInput: true,
        STag: true,
        SSelect: true,
        SSlider: true,
        SColor: true,
        SButton: true,
        SInput: true,
        SSwitch: {
          props: ["modelValue"],
          emits: ["update:modelValue"],
          template:
            "<button @click=\"$emit('update:modelValue', !modelValue)\">{{ modelValue }}</button>",
        },
      },
    },
  });

describe("下载版权确认", () => {
  it("iOS 设置中提供开关，取消不启用且弹窗使用指定文案", async () => {
    mocks.confirm.mockResolvedValue(false);
    const wrapper = createWrapper();
    await wrapper.get("button").trigger("click");
    await flushPromises();
    expect(wrapper.get("button").text()).toBe("false");
    expect(mocks.confirm).toHaveBeenCalledWith(
      expect.objectContaining({
        title: "开启歌曲下载",
        content:
          "开启后，你可以将支持离线缓存的音频保存到本地设备。请确保你仅下载拥有合法使用权的音乐内容，并遵守各音乐平台的服务条款与权利人许可。下载的文件仅供个人在授权范围内收听，请勿用于商业目的或进行未经许可的二次传播。",
        confirmText: "确认开启",
        cancelText: "暂不开启",
      }),
    );
    wrapper.unmount();
  });

  it("确认才开启，关闭无弹窗，再开启再次提醒", async () => {
    mocks.confirm.mockResolvedValue(true);
    const wrapper = createWrapper();
    await wrapper.get("button").trigger("click");
    await flushPromises();
    expect(wrapper.get("button").text()).toBe("true");
    await wrapper.get("button").trigger("click");
    await flushPromises();
    expect(wrapper.get("button").text()).toBe("false");
    expect(mocks.confirm).toHaveBeenCalledTimes(1);
    await wrapper.get("button").trigger("click");
    await flushPromises();
    expect(mocks.confirm).toHaveBeenCalledTimes(2);
    wrapper.unmount();
  });
});
