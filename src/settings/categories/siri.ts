import type { SettingCategory } from "@/types/settings-schema";
import SiriSettings from "@/components/settings/custom/SiriSettings.vue";
import IconLucideMic from "~icons/lucide/mic";

const siriCategory: SettingCategory = {
  id: "siri",
  icon: IconLucideMic,
  sections: [
    {
      id: "siri",
      items: [{ key: "siriSettings", type: "custom", component: SiriSettings, fullWidth: true }],
    },
  ],
};
export default siriCategory;
