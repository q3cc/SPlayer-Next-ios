import type { UpdateEvent, UpdateMeta, UpdatePhase } from "@shared/types/update";
import { toast } from "@/composables/useToast";
import i18n from "@/i18n";
import { isIOS, isAndroid } from "@/utils/config";

const { t } = i18n.global;

export const useUpdateStore = defineStore("update", () => {
  /** 当前阶段 */
  const phase = ref<UpdatePhase>("idle");
  /** 更新信息（版本 / 日志 / 日期 / 大小） */
  const meta = ref<UpdateMeta | null>(null);
  /** 下载进度 0–100 */
  const percent = ref(0);
  const bytesPerSecond = ref(0);
  const downloadedBytes = ref(0);
  const totalBytes = ref(0);
  /** 当前平台是否支持应用内安装 */
  const canInstall = ref(true);
  /** 更新弹窗开关 */
  const dialogOpen = ref(false);

  /** 是否有可用更新（驱动顶栏图标） */
  const hasUpdate = computed(() =>
    ["available", "downloading", "downloaded"].includes(phase.value),
  );

  const handleEvent = (event: UpdateEvent): void => {
    switch (event.type) {
      case "checking":
        phase.value = "checking";
        break;
      case "available":
        phase.value = "available";
        meta.value = event.meta;
        canInstall.value = event.canInstall;
        percent.value = 0;
        dialogOpen.value = true;
        break;
      case "notAvailable":
        phase.value = "upToDate";
        if (event.manual) toast.success(t("update.upToDate"));
        break;
      case "progress":
        phase.value = "downloading";
        percent.value = event.percent;
        bytesPerSecond.value = event.bytesPerSecond ?? 0;
        downloadedBytes.value = event.downloadedBytes ?? 0;
        totalBytes.value = event.totalBytes ?? 0;
        break;
      case "downloaded":
        phase.value = "downloaded";
        meta.value = event.meta;
        toast.success(
          t(
            isIOS
              ? "update.iosReadyToast"
              : isAndroid
                ? "update.androidReadyToast"
                : "update.readyToast",
          ),
        );
        break;
      case "error":
        if (event.stage !== "share" && event.stage !== "install") phase.value = "error";
        if (event.manual)
          toast.error(
            isIOS || isAndroid || event.stage === "install"
              ? `${t("update.failed")}：${event.message}`
              : t("update.failed"),
          );
        break;
    }
  };

  // 订阅主进程推送的更新事件
  const unsubscribe = window.api.update.onEvent(handleEvent);
  onScopeDispose(unsubscribe);
  // 触发启动检查
  void window.api.update.check(false);

  /** 手动检查更新 */
  const checkManually = (): void => {
    if (phase.value === "downloading") {
      dialogOpen.value = true;
      return;
    }
    phase.value = "checking";
    void window.api.update.check(true);
  };

  /** 下载更新 */
  const download = (): void => {
    phase.value = "downloading";
    percent.value = 0;
    bytesPerSecond.value = 0;
    downloadedBytes.value = 0;
    totalBytes.value = meta.value?.size ?? 0;
    void window.api.update.download();
  };

  /** 退出并安装 */
  const install = (): void => void window.api.update.install();

  /** 打开 Releases 下载页（mac） */
  const openDownloadPage = (): void => void window.api.update.openDownloadPage();

  /** 打开更新弹窗 */
  const openDialog = (): void => {
    dialogOpen.value = true;
  };

  return {
    phase,
    meta,
    percent,
    bytesPerSecond,
    downloadedBytes,
    totalBytes,
    canInstall,
    dialogOpen,
    hasUpdate,
    checkManually,
    download,
    install,
    openDownloadPage,
    openDialog,
  };
});
