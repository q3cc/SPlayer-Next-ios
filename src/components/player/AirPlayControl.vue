<script setup lang="ts">
import { colord } from "colord";
import { isIOS } from "@/utils/config";

withDefaults(defineProps<{ cover?: boolean }>(), { cover: false });
const { t } = useI18n();
const id = isIOS ? crypto.randomUUID() : "";
const anchor = ref<HTMLElement | null>(null);
const error = ref("");
const ready = ref(false);
let frame = 0;
let disposed = false;
let active = true;
let sending = false;
let pending: Record<string, unknown> | undefined;
let lastLayout = "";

// 同一入口串行发送，只保留最新布局；卸载请求必须排在尚未完成的挂载之后。
const syncNative = async (layout: Record<string, unknown>): Promise<void> => {
  const key = JSON.stringify(layout);
  if (key === lastLayout) return;
  lastLayout = key;
  pending = { id, ...layout };
  if (sending) return;
  sending = true;
  try {
    const { invoke } = await import("@tauri-apps/api/core");
    while (pending) {
      const request = pending;
      pending = undefined;
      try {
        const result = await invoke<{ visible: boolean }>("plugin:native-audio|airplay", request);
        if (!disposed && !pending) ready.value = result.visible;
      } catch (cause) {
        console.warn("[airplay]", cause);
        if (!disposed) error.value = t("player.airPlayError");
      }
    }
  } catch (cause) {
    console.warn("[airplay]", cause);
    if (!disposed) error.value = t("player.airPlayError");
  } finally {
    sending = false;
  }
};

const syncLayout = (): void => {
  const element = anchor.value;
  const rect = element?.getBoundingClientRect();
  let shown = !!element && !!rect?.width && !!rect.height && !document.hidden && active;
  if (shown && element && rect) {
    // 原生视图不参与 DOM 层叠，必须主动避开弹层、隐藏祖先和被裁切的入口。
    for (let parent: HTMLElement | null = element; parent; parent = parent.parentElement) {
      const style = getComputedStyle(parent);
      if (
        style.display === "none" ||
        style.visibility === "hidden" ||
        style.opacity === "0" ||
        parent.inert ||
        parent.getAttribute("aria-hidden") === "true"
      ) {
        shown = false;
        break;
      }
    }
    shown &&= [
      [rect.left + 1, rect.top + 1],
      [rect.right - 1, rect.top + 1],
      [rect.left + 1, rect.bottom - 1],
      [rect.right - 1, rect.bottom - 1],
      [rect.x + rect.width / 2, rect.y + rect.height / 2],
    ].every(([x, y]) => element.contains(document.elementFromPoint(x, y)));
  }
  if (!shown || !element || !rect) {
    void syncNative({ show: false });
    return;
  }
  const color = colord(getComputedStyle(element).color).toRgb();
  void syncNative({
    show: true,
    x: rect.x,
    y: rect.y,
    width: rect.width,
    height: rect.height,
    viewportWidth: innerWidth,
    viewportHeight: innerHeight,
    label: t("player.airPlay"),
    tint: [color.r / 255, color.g / 255, color.b / 255, color.a],
  });
};

// 跟随全屏动画和旋转，但静止时不发送 IPC，后台不保留动画循环。
const tick = (): void => {
  frame = 0;
  if (disposed || !active || document.hidden || error.value) return;
  syncLayout();
  frame = requestAnimationFrame(tick);
};
const refresh = (): void => {
  cancelAnimationFrame(frame);
  frame = 0;
  if (!isIOS || disposed) return;
  if (document.hidden || !active) void syncNative({ show: false });
  else tick();
};
const retry = (): void => {
  error.value = "";
  lastLayout = "";
  refresh();
};
onMounted(() => {
  if (!isIOS) return;
  document.addEventListener("visibilitychange", refresh);
  refresh();
});
onActivated(() => {
  active = true;
  refresh();
});
onDeactivated(() => {
  active = false;
  refresh();
});
onBeforeUnmount(() => {
  disposed = true;
  cancelAnimationFrame(frame);
  document.removeEventListener("visibilitychange", refresh);
  if (isIOS) void syncNative({ show: false, remove: true });
});
</script>

<template>
  <span
    v-if="isIOS"
    ref="anchor"
    :data-airplay-anchor="id"
    class="relative inline-flex size-10 shrink-0 items-center justify-center"
    :class="cover ? 'text-cover/50' : 'text-on-surface-variant'"
  >
    <SButton
      v-if="error"
      :type="cover ? 'cover' : 'default'"
      variant="ghost"
      circle
      size="large"
      :aria-label="t('player.airPlay')"
      @click="retry"
    >
      <template #icon><IconLucideAirplay /></template>
    </SButton>
    <IconLucideAirplay v-else-if="!ready" aria-hidden="true" class="size-5" />
    <span
      v-if="error"
      role="alert"
      class="absolute bottom-full right-0 w-48 rounded bg-surface p-2 text-xs text-on-surface"
    >
      {{ error }}
    </span>
  </span>
</template>
