<script setup lang="ts">
import { useSettingsDialog } from "@/settings/useSettingsDialog";
import IconLucideHeart from "~icons/lucide/heart";
import IconLucideHome from "~icons/lucide/home";
import IconLucideLibrary from "~icons/lucide/library";
import IconLucideSearch from "~icons/lucide/search";
import IconLucideSettings from "~icons/lucide/settings";

const route = useRoute();
const router = useRouter();
const { t } = useI18n();
const { show: showSettings } = useSettingsDialog();

const items = computed(() => [
  { key: "home", path: "/", label: t("nav.home"), icon: IconLucideHome },
  { key: "search", path: "/search", label: t("common.search"), icon: IconLucideSearch },
  { key: "library", path: "/library", label: t("nav.library"), icon: IconLucideLibrary },
  { key: "liked", path: "/liked", label: t("nav.liked"), icon: IconLucideHeart },
]);

const isActive = (path: string): boolean =>
  path === "/" ? route.path === "/" : route.path === path || route.path.startsWith(`${path}/`);
</script>

<template>
  <nav class="mobile-nav" :aria-label="t('nav.menu.customizeSidebar')">
    <button
      v-for="item in items"
      :key="item.key"
      type="button"
      class="mobile-nav-item"
      :class="isActive(item.path) ? 'is-active' : ''"
      :aria-current="isActive(item.path) ? 'page' : undefined"
      @click="router.push(item.path)"
    >
      <component :is="item.icon" class="size-5" />
      <span>{{ item.label }}</span>
    </button>
    <button type="button" class="mobile-nav-item" @click="showSettings()">
      <IconLucideSettings class="size-5" />
      <span>{{ t("nav.globalSettings") }}</span>
    </button>
  </nav>
</template>

<style scoped>
.mobile-nav {
  position: fixed;
  z-index: 80;
  right: 0;
  bottom: 0;
  left: 0;
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  min-height: calc(4rem + var(--s-safe-bottom));
  padding: 0.35rem calc(0.2rem + var(--s-safe-right)) var(--s-safe-bottom)
    calc(0.2rem + var(--s-safe-left));
  border-top: 1px solid rgb(var(--s-primary) / 0.1);
  background: rgb(var(--s-surface-panel) / 0.94);
  backdrop-filter: blur(18px) saturate(1.35);
}

.mobile-nav-item {
  display: flex;
  min-width: 0;
  align-items: center;
  justify-content: center;
  flex-direction: column;
  gap: 0.2rem;
  border: 0;
  border-radius: 0.75rem;
  color: rgb(var(--s-on-surface-variant) / 0.72);
  background: transparent;
  font-size: 0.65rem;
  line-height: 1;
  touch-action: manipulation;
}

.mobile-nav-item span {
  overflow: hidden;
  max-width: 100%;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.mobile-nav-item.is-active {
  color: rgb(var(--s-primary));
  background: rgb(var(--s-primary) / 0.1);
}
</style>
