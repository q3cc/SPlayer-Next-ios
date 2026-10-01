import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { mount, flushPromises } from "@vue/test-utils";
import { ref, nextTick } from "vue";
import {
  DialogRoot,
  DialogTrigger,
  DialogPortal,
  DialogOverlay,
  DialogContent,
  DialogTitle,
  DialogDescription,
  DialogClose,
} from "reka-ui";
import SDialog from "@/components/ui/SDialog.vue";
import SettingsDialog from "./SettingsDialog.vue";

const platform = vi.hoisted(() => ({ isIOS: true }));
vi.mock("@/utils/config", () => platform);
const open = ref(false);
vi.mock("@/settings/useSettingsDialog", () => ({
  useSettingsDialog: () => ({ open, show: vi.fn() }),
}));
let wrapper: ReturnType<typeof mount> | undefined;
beforeEach(() => {
  open.value = false;
  platform.isIOS = true;
  Object.defineProperty(window, "api", {
    configurable: true,
    value: { system: { onOpenSettings: () => () => {} } },
  });
});
afterEach(() => {
  wrapper?.unmount();
  document.body.innerHTML = "";
});

const show = async () => {
  wrapper = mount(SettingsDialog, {
    attachTo: document.body,
    global: {
      components: {
        SDialog,
        DialogRoot,
        DialogTrigger,
        DialogPortal,
        DialogOverlay,
        DialogContent,
        DialogTitle,
        DialogDescription,
        DialogClose,
      },
      stubs: {
        SettingsContent: {
          template:
            '<div><input aria-label="搜索设置" /><div class="settings-scroll">设置内容</div></div>',
        },
        SButton: { template: "<button><slot /></button>" },
      },
    },
  });
  open.value = true;
  await nextTick();
  await flushPromises();
};

it("iOS 首次打开设置聚焦弹窗而非搜索框，仍允许主动聚焦搜索", async () => {
  await show();
  expect(document.activeElement).toBe(document.querySelector('[role="dialog"]'));
  const input = document.querySelector("input")!;
  input.focus();
  expect(document.activeElement).toBe(input);
});

it("桌面端仍按默认行为聚焦搜索框", async () => {
  platform.isIOS = false;
  await show();
  expect(document.activeElement).toBe(document.querySelector("input"));
});
