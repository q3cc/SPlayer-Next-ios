<script setup lang="ts">
import { useStatusStore } from "@/stores/status";
import { useMediaStore } from "@/stores/media";
import { useSettingsStore } from "@/stores/settings";
import { useOrpheusProtocol } from "@/composables/useOrpheusProtocol";
import { useExternalFileHandler } from "@/composables/useExternalFileHandler";
import { isIOS } from "@/utils/config";
import PlayerSurface from "@/components/player/PlayerSurface.vue";

const route = useRoute();
const status = useStatusStore();
const settings = useSettingsStore();
// 随实际窗口宽度切换，iPad 横屏复用桌面布局，分屏窄窗口使用移动布局。
const isCompactLayout = useMediaQuery("(max-width: 900px)");

// 接入 orpheus 协议唤起与外部音频文件播放
useOrpheusProtocol();
useExternalFileHandler();

/** 有歌曲信息时显示播放栏 */
const showPlayerBar = computed(() => !!useMediaStore().track);
const { isPlayerExpanded } = storeToRefs(status);
const { appearance } = settings;

/** 路由切换动效 */
const routeTransitionName = computed(() => {
  const transition = appearance.routeTransition;
  return transition === "none" ? "" : `route-${transition}`;
});

/** 路由 key */
const routeKey = computed(() => {
  const hasParam = route.matched.some((m) => m.path.includes(":"));
  return hasParam ? route.path : (route.matched[1]?.path ?? route.path);
});

/** 需要受控缓存的页面组件白名单 */
const cachedViews = [
  "Home",
  "Library",
  "Liked",
  "History",
  "Download",
  "Daily",
  "Favorites",
  "Cloud",
  "LocalList",
  "Folders",
  "SearchPage",
  "Stats",
  "StreamingIndex",
];

const mainContainerRef = shallowRef<HTMLElement | null>(null);
const mainScrollMap = new Map<string, number>();

// 路由离开前记录滚动位置
watch(
  () => route.fullPath,
  (_newPath, oldPath) => {
    if (oldPath && mainContainerRef.value) {
      mainScrollMap.set(oldPath, mainContainerRef.value.scrollTop);
    }
  },
);

// 路由切换完成后恢复滚动位置
const handleAfterEnter = (): void => {
  if (!mainContainerRef.value) return;
  const saved = mainScrollMap.get(route.fullPath) ?? 0;
  mainContainerRef.value.scrollTop = saved;
};

/** 侧边栏样式 */
const sidebarClass = computed(() => {
  const classes: string[] = [];
  if (appearance.layoutMode === "floating") {
    classes.push("ml-3 mt-3 mb-3 rounded-xl border border-solid border-primary/10");
  } else {
    classes.push("border-r border-r-solid border-r-primary/10");
    if (showPlayerBar.value && appearance.layoutMode === "default") classes.push("mb-20");
  }
  return classes.join(" ");
});

/** 主界面底部边距 */
const mainMarginClass = computed(() =>
  !isCompactLayout.value && showPlayerBar.value && appearance.layoutMode !== "floating"
    ? "mb-20"
    : "",
);

/** 外层播放条样式 */
const playerBarWrapperClass = computed(() => {
  const base = "fixed bottom-0 z-50 transition-[left] duration-300 pointer-events-none";
  if (isCompactLayout.value) return `${base} mobile-player-wrapper left-0 right-0`;
  const collapsed = appearance.sidebarCollapsed;
  switch (appearance.layoutMode) {
    case "sidebar-full":
      return `${base} ${collapsed ? "left-16" : "left-60"} right-0`;
    case "floating":
      return `${base} ${collapsed ? "left-[76px]" : "left-[252px]"} right-0 px-4 pb-6`;
    default:
      return `${base} left-0 right-0`;
  }
});

/** 内层播放条样式 */
const playerBarInnerClass = computed(() => {
  // 禁用底部播放栏交互
  const base = isPlayerExpanded.value ? "pointer-events-none" : "pointer-events-auto";
  if (isCompactLayout.value)
    return `${base} mobile-player-inner bg-surface-panel border-t border-t-solid border-t-primary/10`;
  switch (appearance.layoutMode) {
    case "floating":
      return `${base} mx-auto max-w-4xl glass-panel rounded-full shadow-xl border border-solid border-primary/10`;
    default:
      return `${base} ${isIOS ? "ios-player-bar" : "h-20"} bg-surface-panel border-t border-t-solid border-t-primary/10`;
  }
});
</script>

<template>
  <!-- 主界面 -->
  <div
    class="app-viewport h-screen flex overflow-hidden bg-app text-on-surface transition-[transform,opacity] duration-500 ease-[cubic-bezier(0.7,0,0.3,1)] origin-center"
    :class="[
      isIOS ? 'ios-app-viewport' : '',
      isPlayerExpanded ? 'scale-95 opacity-0 pointer-events-none' : '',
    ]"
  >
    <!-- 侧边栏 -->
    <aside
      v-if="!isCompactLayout"
      class="desktop-sidebar shrink-0 bg-surface-panel overflow-y-auto z-10 transition-[width,margin] duration-300"
      :class="[appearance.sidebarCollapsed ? 'w-16' : 'w-60', sidebarClass]"
    >
      <SideBar />
    </aside>

    <!-- 右侧主区域 -->
    <div
      class="main-shell flex-1 flex flex-col min-w-0"
      :class="[
        mainMarginClass,
        isCompactLayout ? 'mobile-main-shell' : '',
        isCompactLayout && showPlayerBar ? 'has-player' : '',
      ]"
    >
      <!-- 顶部导航 -->
      <header
        class="main-header h-16 shrink-0 flex items-center px-3"
        :class="isCompactLayout ? 'mobile-header' : ''"
      >
        <NavHeader />
      </header>

      <!-- 主内容区 -->
      <main ref="mainContainerRef" class="flex-1 overflow-y-auto overflow-x-hidden">
        <RouterView v-slot="{ Component }">
          <Transition :name="routeTransitionName" mode="out-in" @after-enter="handleAfterEnter">
            <KeepAlive :max="10" :include="cachedViews">
              <component :is="Component" :key="routeKey" />
            </KeepAlive>
          </Transition>
        </RouterView>
      </main>
    </div>
  </div>

  <!-- 底部播放栏 -->
  <Transition
    enter-active-class="transition-transform duration-300 ease-out"
    leave-active-class="transition-transform duration-300 ease-in"
    enter-from-class="translate-y-full"
    leave-to-class="translate-y-full"
  >
    <div
      v-if="showPlayerBar"
      :class="playerBarWrapperClass"
      :style="
        isIOS && !isCompactLayout && appearance.layoutMode === 'floating'
          ? { bottom: 'var(--s-safe-bottom)' }
          : undefined
      "
    >
      <footer :class="playerBarInnerClass">
        <PlayerBar />
      </footer>
    </div>
  </Transition>

  <MobileNav v-if="isCompactLayout && !isPlayerExpanded" />

  <!-- Toast -->
  <SToast :max="1" />
  <!-- 性能监视器 -->
  <SPerformanceMonitor v-if="appearance.showPerformanceMonitor" />
  <!-- Dialog -->
  <SDialogProvider />
  <!-- 全屏播放器 -->
  <PlayerSurface />
  <!-- 全局设置 -->
  <SettingsDialog />
  <!-- 更新弹窗 -->
  <UpdateDialog />
  <!-- 评论弹窗 -->
  <MusicCommentsDialog />
</template>

<style scoped>
.app-viewport {
  height: 100vh;
  height: 100dvh;
}

.ios-app-viewport .desktop-sidebar {
  padding-top: var(--s-safe-top);
  padding-bottom: var(--s-safe-bottom);
  padding-left: var(--s-safe-left);
}

.ios-app-viewport .main-header {
  height: calc(4rem + var(--s-safe-top));
  padding-top: var(--s-safe-top);
}

.ios-app-viewport .mobile-header {
  height: calc(3.5rem + var(--s-safe-top));
}

.ios-app-viewport .main-shell {
  padding-right: var(--s-safe-right);
}

.ios-app-viewport .main-shell:not(.mobile-main-shell) > main {
  padding-bottom: var(--s-safe-bottom);
}

.ios-app-viewport .mobile-main-shell {
  padding-left: var(--s-safe-left);
}

.ios-app-viewport .mb-20 {
  margin-bottom: calc(5rem + var(--s-safe-bottom));
}

.ios-player-bar {
  height: calc(5rem + var(--s-safe-bottom));
  padding-right: var(--s-safe-right);
  padding-bottom: var(--s-safe-bottom);
  padding-left: var(--s-safe-left);
}

.mobile-header {
  height: calc(3.5rem + var(--s-safe-top));
  padding-top: var(--s-safe-top);
}

.mobile-main-shell {
  padding-bottom: calc(4rem + var(--s-safe-bottom));
}

.mobile-main-shell.has-player {
  padding-bottom: calc(8.5rem + var(--s-safe-bottom));
}

.mobile-player-wrapper {
  right: 0;
  bottom: calc(4rem + var(--s-safe-bottom));
  left: 0;
}

.mobile-player-inner {
  height: 4.5rem;
  padding-right: var(--s-safe-right);
  padding-left: var(--s-safe-left);
}
</style>
