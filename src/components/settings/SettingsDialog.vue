<script setup lang="ts">
import { useSettingsDialog } from "@/settings/useSettingsDialog";
import { isIOS } from "@/utils/config";

const SettingsContent = defineAsyncComponent(() => import("./SettingsContent.vue"));

const dialog = useSettingsDialog();
const { open } = dialog;
const { t } = useI18n();

const unsubscribe = window.api.system.onOpenSettings(({ category, highlight }) => {
  dialog.show(category, highlight);
});

onBeforeUnmount(() => unsubscribe());

/** iOS 打开设置时不进入搜索输入，避免键盘与视口调整占用首次滑动。 */
const onOpenAutoFocus = (event: Event): void => {
  if (!isIOS || !(event.target instanceof HTMLElement)) return;
  event.preventDefault();
  event.target.focus({ preventScroll: true });
};
</script>

<template>
  <SDialog
    v-model:open="open"
    width="min(1024px, calc(100vw - 40px))"
    height="75vh"
    destroy-on-close
    @open-auto-focus="onOpenAutoFocus"
  >
    <Suspense>
      <SettingsContent class="h-full" />
      <template #fallback>
        <div class="h-full flex items-center justify-center gap-2 text-on-surface-variant">
          <SLoading class="size-5 text-primary" />
          {{ t("common.loading") }}
        </div>
      </template>
    </Suspense>
  </SDialog>
</template>
