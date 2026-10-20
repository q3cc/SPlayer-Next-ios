import i18n from "@/i18n";
import { useUserStore } from "@/stores/user";
import type { CloudUploadProgress, CloudUploadResult, PickedSong } from "@shared/types/cloudUpload";

/** 队列项状态 */
export type UploadStatus = "pending" | "reading" | "uploading" | "instant" | "success" | "error";

/** 队列项 */
export interface UploadItem {
  id: string;
  name: string;
  path: string;
  size: number;
  status: UploadStatus;
  /** 0 ~ 100 */
  progress: number;
  error?: string;
  songId?: string;
}

/** 队列保留项硬上限,溢出淘汰最旧的已结束项(成功/秒传/失败) */
const MAX_RETAINED = 200;

/** 进度订阅只绑一次 */
let progressBound = false;
/** 队列项 id 自增 */
let idSeq = 0;

export const useCloudUploadStore = defineStore("cloudUpload", () => {
  const items = ref<UploadItem[]>([]);
  const running = ref(false);

  /** 进行中(待传/读取/上传)的数量 */
  const activeCount = computed(
    () =>
      items.value.filter((item) => ["pending", "reading", "uploading"].includes(item.status))
        .length,
  );

  /** 绑定主进程进度推送(按 uploadId 原地更新) */
  const bindProgress = (): void => {
    if (progressBound) return;
    progressBound = true;
    window.api.cloud.onUploadProgress((progress: CloudUploadProgress) => {
      const item = items.value.find((it) => it.id === progress.uploadId);
      if (!item) return;
      if (progress.stage === "uploading") {
        item.status = "uploading";
        item.progress =
          progress.total > 0
            ? Math.min(99, Math.round((progress.loaded / progress.total) * 100))
            : 0;
      } else if (progress.stage === "finishing") {
        item.progress = 99;
      }
    });
  };

  /** 队列超上限时,从最旧开始淘汰已结束项(成功/秒传/失败) */
  const evictOldFinished = (): void => {
    if (items.value.length <= MAX_RETAINED) return;
    let removable = items.value.length - MAX_RETAINED;
    const kept: UploadItem[] = [];
    for (const item of items.value) {
      if (
        removable > 0 &&
        (item.status === "success" || item.status === "instant" || item.status === "error")
      ) {
        removable--;
        continue;
      }
      kept.push(item);
    }
    items.value = kept;
  };

  /** 顺序逐首执行(并发=1) */
  const runQueue = async (): Promise<void> => {
    if (running.value) return;
    running.value = true;
    let anySuccess = false;
    try {
      while (true) {
        const next = items.value.find((item) => item.status === "pending");
        if (!next) break;
        next.status = "reading";
        next.progress = 0;
        try {
          const res: CloudUploadResult = await window.api.cloud.uploadSong(next.path, next.id);
          if (res.success) {
            next.status = res.instant ? "instant" : "success";
            next.progress = 100;
            next.songId = res.songId;
            anySuccess = true;
          } else {
            next.status = "error";
            next.error =
              res.errorCode != null
                ? i18n.global.t("cloud.upload.errorWithCode", { code: res.errorCode })
                : i18n.global.t("cloud.upload.error");
          }
        } catch {
          next.status = "error";
          next.error = i18n.global.t("cloud.upload.error");
        }
      }
    } finally {
      running.value = false;
      evictOldFinished();
      if (anySuccess) void useUserStore().refreshCloud();
    }
  };

  /** 入队(预检容量,超出直接标错) */
  const enqueue = (songs: PickedSong[]): void => {
    bindProgress();
    const user = useUserStore();
    const remainingBytes = Math.max(0, user.cloudMaxSize - user.cloudSize);
    let queuedBytes = items.value
      .filter((item) => ["pending", "reading", "uploading"].includes(item.status))
      .reduce((sum, item) => sum + item.size, 0);
    for (const song of songs) {
      const overCapacity = user.cloudMaxSize > 0 && queuedBytes + song.size > remainingBytes;
      if (!overCapacity) queuedBytes += song.size;
      items.value.push({
        id: `up-${idSeq++}`,
        name: song.name,
        path: song.path,
        size: song.size,
        status: overCapacity ? "error" : "pending",
        progress: 0,
        error: overCapacity ? i18n.global.t("cloud.upload.capacityFull") : undefined,
      });
    }
    void runQueue();
  };

  /** 文件选择器入队 */
  const pickAndEnqueue = async (): Promise<void> => {
    const songs = await window.api.cloud.pickSongs();
    if (songs.length > 0) enqueue(songs);
  };

  /** 重试单首失败项 */
  const retry = (id: string): void => {
    const item = items.value.find((it) => it.id === id);
    if (!item || item.status !== "error") return;
    item.status = "pending";
    item.error = undefined;
    item.progress = 0;
    void runQueue();
  };

  /** 移除单项 */
  const remove = (id: string): void => {
    items.value = items.value.filter((item) => item.id !== id);
  };

  /** 清除全部已结束项 */
  const clearFinished = (): void => {
    items.value = items.value.filter(
      (item) => !["success", "instant", "error"].includes(item.status),
    );
  };

  return {
    items,
    activeCount,
    enqueue,
    pickAndEnqueue,
    retry,
    remove,
    clearFinished,
  };
});
