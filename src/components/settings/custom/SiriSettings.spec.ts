import { mount, flushPromises } from "@vue/test-utils";
import { beforeEach, expect, it, vi } from "vitest";
import { reactive } from "vue";
import SiriSettings from "./SiriSettings.vue";

const mocks = vi.hoisted(() => ({
  status: vi.fn(),
  authorize: vi.fn(),
  configure: vi.fn(),
  setSystem: vi.fn(),
  settings: null as any,
}));
vi.mock("@/mobile/siri", () => ({ mobileSiri: mocks }));
vi.mock("@/stores/settings", () => ({ useSettingsStore: () => mocks.settings }));

const options = {
  global: {
    stubs: {
      SSwitch: {
        props: ["modelValue", "disabled"],
        emits: ["update:modelValue"],
        template:
          '<button :disabled="disabled" @click="$emit(\'update:modelValue\', !modelValue)" />',
      },
      SSelect: true,
      SButton: { template: "<button><slot /></button>" },
    },
  },
};

beforeEach(() => {
  mocks.status.mockReset().mockResolvedValue({ authorization: "notDetermined", enabled: false });
  mocks.authorize.mockReset();
  mocks.configure.mockReset().mockResolvedValue(undefined);
  mocks.setSystem.mockReset().mockImplementation(async (_key, value) => {
    mocks.settings.system.siri.enabled = value;
  });
  mocks.settings = reactive({
    system: {
      siri: {
        enabled: false,
        source: "current",
        searchScope: "localFirst",
        askBeforePlaying: true,
      },
    },
    setSystem: mocks.setSystem,
  });
});

it.each(["missingEntitlement", "denied", "restricted"])(
  "授权为 %s 时不开启 Siri，错误后开关恢复可用",
  async (authorization) => {
    mocks.authorize.mockResolvedValue({ authorization, enabled: false });
    const wrapper = mount(SiriSettings, options);
    await flushPromises();
    const toggle = wrapper.get('[aria-label="Siri 语音控制"]');
    await toggle.trigger("click");
    await flushPromises();
    expect(mocks.setSystem).not.toHaveBeenCalled();
    expect(wrapper.get('[role="alert"]').text()).not.toBe("");
    expect(toggle.attributes("disabled")).toBeUndefined();
    wrapper.unmount();
  },
);

it("只有授权返回成功才保存开启，随后可以关闭而不重复请求授权", async () => {
  mocks.authorize.mockResolvedValue({ authorization: "authorized", enabled: false });
  const wrapper = mount(SiriSettings, options);
  await flushPromises();
  const toggle = wrapper.get('[aria-label="Siri 语音控制"]');
  await toggle.trigger("click");
  await flushPromises();
  expect(mocks.setSystem).toHaveBeenLastCalledWith("siri.enabled", true);
  expect(mocks.configure).toHaveBeenCalled();
  await toggle.trigger("click");
  await flushPromises();
  expect(mocks.setSystem).toHaveBeenLastCalledWith("siri.enabled", false);
  expect(mocks.authorize).toHaveBeenCalledTimes(1);
  wrapper.unmount();
});

it("原生授权报错后仍能再次操作，不留下永久禁用的开关", async () => {
  mocks.authorize.mockRejectedValue(new Error("授权失败"));
  const wrapper = mount(SiriSettings, options);
  await flushPromises();
  const toggle = wrapper.get('[aria-label="Siri 语音控制"]');
  await toggle.trigger("click");
  await flushPromises();
  expect(wrapper.get('[role="alert"]').text()).toBe("授权失败");
  expect(toggle.attributes("disabled")).toBeUndefined();
  expect(mocks.setSystem).not.toHaveBeenCalled();
  wrapper.unmount();
});
