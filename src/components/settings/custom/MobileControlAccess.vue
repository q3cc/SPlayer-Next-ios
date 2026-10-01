<script setup lang="ts">
import { useCopyText } from "@/composables/useCopyText";
import { toast } from "@/composables/useToast";
const { t } = useI18n();
const { copy } = useCopyText();
const copyAccess = async (): Promise<void> => {
  const status = await window.api.externalApi.getStatus();
  const key = await window.api.config.get("externalApi.accessKey");
  if (!status.listening || !key) {
    toast.error(t("settings.externalApi.stopped"));
    return;
  }
  await copy(
    JSON.stringify(
      { url: `http://${status.host}:${status.port}/api`, headers: { "X-API-Key": key } },
      null,
      2,
    ),
  );
};
</script>
<template>
  <div class="flex flex-col gap-2">
    <p class="text-sm text-on-surface-variant">{{ t("settings.mobileControlHint") }}</p>
    <SButton @click="copyAccess">{{ t("settings.mobileControlCopy") }}</SButton>
  </div>
</template>
