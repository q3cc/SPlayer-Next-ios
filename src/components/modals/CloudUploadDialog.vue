<script setup lang="ts">
import { useCloudUploadStore } from "@/stores/cloudUpload";
import { formatFileSize } from "@/utils/format";

defineProps<{ open: boolean }>();
const emit = defineEmits<{ "update:open": [value: boolean] }>();

const { t } = useI18n();
const store = useCloudUploadStore();
</script>

<template>
  <SDialog
    :open="open"
    :title="t('cloud.upload.title')"
    width="440px"
    @update:open="(value) => emit('update:open', value)"
  >
    <div class="flex flex-col gap-3">
      <!-- 风险提示 -->
      <SAlert>{{ t("cloud.upload.riskTip") }}</SAlert>

      <!-- 操作行 -->
      <div class="flex items-center justify-between gap-2">
        <SButton type="primary" variant="secondary" round @click="store.pickAndEnqueue()">
          <template #icon>
            <IconLucideFilePlus2 />
          </template>
          {{ t("cloud.upload.selectFile") }}
        </SButton>
        <SButton
          v-if="store.items.length > 0"
          variant="secondary"
          round
          @click="store.clearFinished()"
        >
          <template #icon>
            <IconLucideTrash2 />
          </template>
          {{ t("cloud.upload.clearFinished") }}
        </SButton>
      </div>

      <!-- 空态 -->
      <div
        v-if="store.items.length === 0"
        class="flex flex-col items-center gap-3 py-12 text-center text-sm text-on-surface-variant/50"
      >
        <IconLucideCloudUpload class="size-9 opacity-30" />
        {{ t("cloud.upload.emptyHint") }}
      </div>

      <!-- 队列列表 -->
      <div v-else class="-mx-1 flex max-h-[52vh] flex-col gap-2 overflow-y-auto px-1 py-0.5">
        <div
          v-for="item in store.items"
          :key="item.id"
          class="flex items-center gap-3 rounded-xl border-2 border-solid border-primary/12 bg-surface-panel px-3 py-2.5"
        >
          <!-- 状态图标 -->
          <div class="flex w-7 shrink-0 items-center justify-center text-on-surface-variant">
            <IconLucideLoaderCircle
              v-if="item.status === 'reading' || item.status === 'uploading'"
              class="size-4 animate-spin"
            />
            <IconLucideZap v-else-if="item.status === 'instant'" class="size-4 text-primary" />
            <IconLucideCheck v-else-if="item.status === 'success'" class="size-4 text-primary" />
            <IconLucideTriangleAlert
              v-else-if="item.status === 'error'"
              class="size-4 text-amber-500"
            />
            <IconLucideMusic v-else class="size-4 opacity-60" />
          </div>

          <!-- 信息 + 进度 -->
          <div class="min-w-0 flex-1">
            <div class="truncate text-sm font-medium text-on-surface">{{ item.name }}</div>
            <div class="mt-1.5 flex items-center gap-2">
              <div
                v-if="item.status === 'reading' || item.status === 'uploading'"
                class="h-1.5 flex-1 overflow-hidden rounded-full bg-on-surface/10"
              >
                <div
                  class="h-full rounded-full bg-primary transition-[width] duration-200"
                  :style="{ width: `${item.progress}%` }"
                />
              </div>
              <span
                class="shrink-0 truncate text-xs text-on-surface-variant/60"
                :title="item.status === 'error' ? item.error : undefined"
              >
                <template v-if="item.status === 'error'">{{ item.error }}</template>
                <template v-else-if="item.status === 'instant'">
                  {{ t("cloud.upload.instant") }}
                </template>
                <template v-else-if="item.status === 'success'">
                  {{ t("cloud.upload.done") }}
                </template>
                <template v-else-if="item.status === 'uploading'">{{ item.progress }}%</template>
                <template v-else-if="item.status === 'reading'">
                  {{ t("cloud.upload.reading") }}
                </template>
                <template v-else>{{ formatFileSize(item.size) }}</template>
              </span>
            </div>
          </div>

          <!-- 操作 -->
          <div class="flex shrink-0 items-center gap-1">
            <SButton
              v-if="item.status === 'error'"
              variant="ghost"
              circle
              size="small"
              :title="t('cloud.upload.retry')"
              @click="store.retry(item.id)"
            >
              <template #icon>
                <IconLucideRotateCcw />
              </template>
            </SButton>
            <SButton
              v-if="['success', 'instant', 'error'].includes(item.status)"
              variant="ghost"
              circle
              size="small"
              :title="t('cloud.upload.remove')"
              @click="store.remove(item.id)"
            >
              <template #icon>
                <IconLucideX />
              </template>
            </SButton>
          </div>
        </div>
      </div>
    </div>
  </SDialog>
</template>
