import { computed, onBeforeUnmount, ref, watch, type Ref } from "vue";
import { useSettingsStore } from "@/stores/settings";
import { isIOS } from "@/utils/config";

/** 沉浸模式闲置时间（ms） */
const IMMERSIVE_IDLE_MS = 5000;

/**
 * 全屏播放器沉浸模式
 * 闲置五秒隐藏顶栏/底栏，触摸、点击或键盘操作恢复，不依赖悬停
 * @param isPlayerExpanded - 播放器是否展开
 */
export const useImmersiveMode = (isPlayerExpanded: Ref<boolean>) => {
  const settings = useSettingsStore();

  const immersive = ref(false);
  let pressing = false;
  let idleTimer: ReturnType<typeof setTimeout> | undefined;

  const enabled = computed(
    () => (isIOS || settings.player.autoImmersive) && isPlayerExpanded.value,
  );

  const armIdle = (): void => {
    clearTimeout(idleTimer);
    immersive.value = false;
    if (!enabled.value || pressing) return;
    idleTimer = setTimeout(() => {
      immersive.value = true;
    }, IMMERSIVE_IDLE_MS);
  };

  const onPointerDown = (): void => {
    pressing = true;
    armIdle();
  };

  const onPointerUp = (): void => {
    pressing = false;
    armIdle();
  };

  watch(
    enabled,
    () => {
      pressing = false;
      armIdle();
    },
    { immediate: true },
  );

  onBeforeUnmount(() => clearTimeout(idleTimer));

  return {
    immersive,
    onActivity: armIdle,
    onPointerDown,
    onPointerUp,
  };
};
