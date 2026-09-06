<script setup lang="ts">
import { useSettingsStore } from "@/stores/settings";
import { mobileSiri } from "@/mobile/siri";
import type { SiriSettings, SiriStatus } from "@shared/types/siri";

const settings = useSettingsStore();
const status = ref<SiriStatus>();
const busy = ref(false);
const error = ref("");
const authorization = computed(
  () =>
    ({
      notDetermined: "尚未授权",
      restricted: "系统限制",
      denied: "已拒绝",
      authorized: "已授权",
      missingEntitlement: "当前签名不支持 Siri",
    })[status.value?.authorization ?? "notDetermined"],
);
const refresh = async (): Promise<void> => {
  try {
    status.value = await mobileSiri.status();
  } catch (reason) {
    error.value = String(reason);
  }
};
const change = async <K extends keyof SiriSettings>(
  key: K,
  value: SiriSettings[K],
): Promise<void> => {
  busy.value = true;
  error.value = "";
  try {
    if (key === "enabled" && value === true) {
      const granted = await mobileSiri.authorize();
      if (granted.authorization === "missingEntitlement")
        throw new Error("当前签名缺少 Siri 能力，请使用支持 Siri 的证书和描述文件重新签名。");
      if (granted.authorization !== "authorized")
        throw new Error("请在系统设置中允许 SPlayer 使用 Siri。");
    }
    await settings.setSystem(`siri.${key}`, value);
    await mobileSiri.configure();
    await refresh();
  } catch (reason) {
    error.value = reason instanceof Error ? reason.message : String(reason);
  } finally {
    busy.value = false;
  }
};
onMounted(refresh);
</script>

<template>
  <div class="flex flex-col gap-5">
    <div class="flex items-center justify-between gap-4">
      <div>
        <div>Siri 语音控制</div>
        <p class="text-sm text-on-surface-variant">
          {{ authorization }}。开启后可通过 Siri 搜索和播放音乐。
        </p>
      </div>
      <SSwitch
        :model-value="settings.system.siri.enabled"
        :disabled="busy"
        @update:model-value="change('enabled', $event)"
      />
    </div>
    <label class="flex items-center justify-between gap-4">
      默认音乐来源
      <SSelect
        :model-value="settings.system.siri.source"
        :options="[
          { value: 'current', label: '跟随当前来源' },
          { value: 'netease', label: '网易云音乐' },
          { value: 'qqmusic', label: 'QQ 音乐' },
          { value: 'kugou', label: '酷狗音乐' },
        ]"
        @update:model-value="change('source', $event as SiriSettings['source'])"
      />
    </label>
    <label class="flex items-center justify-between gap-4">
      搜索范围
      <SSelect
        :model-value="settings.system.siri.searchScope"
        :options="[
          { value: 'localFirst', label: '优先本地' },
          { value: 'online', label: '在线音乐' },
          { value: 'local', label: '仅本地曲库' },
        ]"
        @update:model-value="change('searchScope', $event as SiriSettings['searchScope'])"
      />
    </label>
    <div class="flex items-center justify-between gap-4">
      有多个匹配结果时询问
      <SSwitch
        :model-value="settings.system.siri.askBeforePlaying"
        @update:model-value="change('askBeforePlaying', $event)"
      />
    </div>
    <p class="text-sm text-on-surface-variant">
      试着说“用 SPlayer 播放晴天”或“用 SPlayer 播放周杰伦的歌”。也可在快捷指令中搜索
      SPlayer，添加播放、暂停和切歌操作。试听遵循播放器设置。
    </p>
    <p class="text-sm text-on-surface-variant">
      重签时需保留 Siri 能力；锁屏是否需要解锁由系统决定。
    </p>
    <div class="flex gap-3">
      <SButton @click="mobileSiri.openSettings()">打开系统设置</SButton>
      <SButton @click="refresh">刷新状态</SButton>
    </div>
    <p v-if="status?.lastResult" class="text-sm">{{ status.lastResult }}</p>
    <p v-if="error" role="alert" class="text-sm text-red-500">{{ error }}</p>
  </div>
</template>
