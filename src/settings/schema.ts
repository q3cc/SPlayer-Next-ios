import type { SettingCategory } from "@/types/settings-schema";
import generalCategory from "./categories/general";
import appearanceCategory from "./categories/appearance";
import playerCategory from "./categories/player";
import lyricCategory from "./categories/lyric";
import externalLyricCategory from "./categories/externalLyric";
import hotkeysCategory from "./categories/hotkeys";
import servicesCategory from "./categories/services";
import aiIntegrationCategory from "./categories/aiIntegration";
import mediaSourceCategory from "./categories/streaming";
import downloadCategory from "./categories/download";
import localCacheCategory from "./categories/localCache";
import pluginsCategory from "./categories/plugins";
import otherCategory from "./categories/other";
import AboutSettings from "@/components/settings/custom/AboutSettings.vue";
import { isIOS } from "@/utils/config";
import IconLucideInfo from "~icons/lucide/info";
import LyricPipPreview from "@/components/settings/custom/LyricPipPreview.vue";
import siriCategory from "./categories/siri";

const mobileExternalLyric: SettingCategory = {
  id: "desktopLyric",
  icon: externalLyricCategory.icon,
  sections: externalLyricCategory.sections
    ?.filter((section) => section.id === "desktopLyric")
    .map((section) => ({
      ...section,
      items: [
        {
          key: "lyricPipPreview",
          type: "custom" as const,
          component: LyricPipPreview,
          fullWidth: true,
        },
        {
          key: "lyricPipFrameRate",
          type: "select" as const,
          binding: { store: "settings" as const, path: "system.desktopLyric.pipFrameRate" },
          defaultValue: 20,
          options: [5, 10, 15, 20, 30, 60].map((value) => ({ value, label: `${value} FPS` })),
        },
        ...section.items
          .filter((item) =>
            [
              "desktopLyricEnabled",
              "desktopLyricDoubleLine",
              "desktopLyricShowTranslation",
              "desktopLyricFontSize",
              "desktopLyricPlayedColor",
              "desktopLyricUnplayedColor",
            ].includes(item.key),
          )
          .map((item) => ({
            ...item,
            key: item.key.replace("desktopLyric", "lyricPip"),
            ...(item.key === "desktopLyricDoubleLine" ? { defaultValue: false } : {}),
            ...(item.key === "desktopLyricFontSize"
              ? {
                  options: Array.from({ length: 25 }, (_, i) => ({
                    value: i + 16,
                    label: `${i + 16}`,
                  })),
                }
              : {}),
          })),
      ],
    })),
};

export const settingsSchema: SettingCategory[] = [
  generalCategory,
  ...(isIOS ? [siriCategory] : []),
  appearanceCategory,
  playerCategory,
  lyricCategory,
  ...(isIOS ? [mobileExternalLyric] : [externalLyricCategory, hotkeysCategory]),
  servicesCategory,
  ...(isIOS ? [] : [aiIntegrationCategory]),
  mediaSourceCategory,
  downloadCategory,
  ...(isIOS ? [] : [localCacheCategory, pluginsCategory]),
  otherCategory,
  { id: "about", icon: IconLucideInfo, component: AboutSettings },
];
