<script setup lang="ts">
import { useSettingsStore } from "@/stores/settings";
import { useWindowControls } from "@/composables/useWindowControls";
import { CURRENT_AGREEMENT_VERSION } from "@shared/constants/agreement";
import { isMobile } from "@/utils/config";

const router = useRouter();
const settings = useSettingsStore();
const { quit } = useWindowControls();

const accepting = ref(false);

/** 用户重新同意协议后,写回版本号并跳回主页 */
const onAccept = async (): Promise<void> => {
  if (accepting.value) return;
  accepting.value = true;
  try {
    await settings.setSystem("system.agreedAgreementVersion", CURRENT_AGREEMENT_VERSION);
    await router.replace("/");
  } finally {
    accepting.value = false;
  }
};
</script>

<template>
  <div
    class="agreement-update-page flex flex-col h-screen w-screen bg-app text-on-surface overflow-hidden"
  >
    <div
      class="agreement-update-titlebar app-drag-region h-16 shrink-0 flex items-center justify-end px-3"
    >
      <WindowControls v-if="!isMobile" direct-quit />
    </div>

    <div class="agreement-update-content flex-1 min-h-0 flex flex-col items-center px-8 pb-10">
      <div class="w-full max-w-2xl flex-1 min-h-0 flex flex-col">
        <StepAgreement variant="update" :loading="accepting" @next="onAccept" @reject="quit" />
      </div>
    </div>
  </div>
</template>

<style>
html.mobile .agreement-update-page {
  height: 100dvh;
}

html.mobile .agreement-update-titlebar {
  display: none;
}

html.mobile .agreement-update-content {
  padding-top: calc(var(--s-safe-top) + 1rem);
  padding-right: calc(2rem + var(--s-safe-right));
  padding-bottom: calc(2.5rem + var(--s-safe-bottom));
  padding-left: calc(2rem + var(--s-safe-left));
}
</style>
