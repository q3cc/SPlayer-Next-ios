import { documentDir, join } from "@tauri-apps/api/path";
import { exists, mkdir, open, remove, rename } from "@tauri-apps/plugin-fs";
import localforage from "localforage";
import type { DownloadApi, DownloadRequest, DownloadTask } from "@shared/types/download";
import { resolveDownloadPayload } from "@/services/download/resolver";
import { fetchWithProxy } from "./shims/proxy";
import { store } from "./shims/store";

const MAX_TASKS = 200;
const storage = localforage.createInstance({ name: "splayer", storeName: "downloads" });
const states = new Set<Parameters<DownloadApi["onState"]>[0]>();
const progress = new Set<Parameters<DownloadApi["onProgress"]>[0]>();
const tasks: DownloadTask[] = [];
const pending = new Map<string, DownloadRequest>();
let running: { task: DownloadTask; controller: AbortController; finalizing?: boolean } | undefined;
let initialization: Promise<void> | undefined;
let persistence = Promise.resolve();

/** 文件名片段不允许改变下载目录，限制长度以兼容文件系统。 */
export const downloadName = (value: string): string =>
  Array.from(value, (character) =>
    character.charCodeAt(0) < 32 || character.charCodeAt(0) === 92 || '/:*?"<>|'.includes(character)
      ? "_"
      : character,
  )
    .join("")
    .replace(/^\.+|[. ]+$/g, "")
    .trim()
    .slice(0, 70) || "Unknown";

const getDir = async (): Promise<string> => join(await documentDir(), "Downloads");
const active = (task: DownloadTask): boolean =>
  task.status === "queued" || task.status === "downloading";

/** 仅保存轻量任务记录，不持久化带鉴权的下载链接及歌词。 */
const persist = (): void => {
  persistence = persistence
    .then(async () => {
      const root = await getDir();
      const snapshot = tasks.map((task) => ({
        ...task,
        filePath: task.filePath?.startsWith(root + "/")
          ? task.filePath.slice(root.length + 1)
          : undefined,
      }));
      await storage.setItem("tasks", JSON.parse(JSON.stringify(snapshot)));
    })
    .catch((error) => console.warn("[download] 下载记录保存失败", error));
};

const announce = (task: DownloadTask): void => {
  states.forEach((listener) => listener({ ...task }));
  persist();
};

const initialize = (): Promise<void> => {
  initialization ??= (async () => {
    const root = await getDir();
    await mkdir(root, { recursive: true });
    const saved = await storage.getItem<DownloadTask[]>("tasks").catch(() => null);
    const restored = (saved ?? []).slice(0, MAX_TASKS);
    for (const task of restored) {
      // iOS 重装更新后的沙盒路径会变化，记录只保存 Downloads 内的相对路径。
      task.filePath =
        task.filePath && !task.filePath.split("/").includes("..") && !task.filePath.startsWith("/")
          ? await join(root, task.filePath)
          : undefined;
      if (active(task)) {
        task.status = "interrupted";
        task.finishedAt = Date.now();
        const part = await join(root, downloadName(task.taskId) + ".part");
        if (await exists(part)) await remove(part);
      }
    }
    tasks.push(...restored);
  })().catch((error) => {
    initialization = undefined;
    throw error;
  });
  return initialization;
};

/** 队列串行解析和流式写入，避免整首音频进入 JS 内存。 */
const pump = async (): Promise<void> => {
  if (running || !store.get("download.enabled")) return;
  const task = tasks.find((item) => item.status === "queued" && pending.has(item.taskId));
  if (!task) return;
  const request = pending.get(task.taskId)!;
  const controller = new AbortController();
  running = { task, controller };
  let temporary: string | undefined;
  let file: Awaited<ReturnType<typeof open>> | undefined;
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  const checkCanceled = (): void => {
    if (controller.signal.aborted) throw new Error("canceled");
  };
  try {
    const resolved = request.url
      ? request
      : { ...request, ...(await resolveDownloadPayload(request)) };
    checkCanceled();
    const url = new URL(resolved.url!);
    if (!["http:", "https:"].includes(url.protocol)) throw new Error("unsupported download URL");
    const response = await fetchWithProxy(url, { signal: controller.signal });
    reader = response.body?.getReader();
    if (!response.ok || !reader) throw new Error("HTTP " + response.status);
    checkCanceled();
    const config = store.get("download");
    const artist = downloadName(task.track.artists.map((item) => item.name).join(", "));
    const title = downloadName(task.track.title);
    const album = downloadName(task.track.album?.name ?? "Unknown Album");
    const root = await getDir();
    const dir =
      config.folderScheme === "artist-album"
        ? await join(root, artist, album)
        : config.folderScheme === "artist"
          ? await join(root, artist)
          : root;
    await mkdir(dir, { recursive: true });
    const supported = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "ape", "aiff", "alac"];
    const format = resolved.declaredFormat?.toLowerCase();
    const urlFormat = url.pathname.split(".").pop()?.toLowerCase();
    const mime = response.headers.get("content-type")?.split(";")[0];
    const mimeFormat = (
      {
        "audio/flac": "flac",
        "audio/x-flac": "flac",
        "audio/mp4": "m4a",
        "audio/ogg": "ogg",
        "audio/wav": "wav",
      } as Record<string, string>
    )[mime ?? ""];
    if (mime?.includes("text/") || mime?.includes("json"))
      throw new Error("invalid audio response");
    const extension =
      format && supported.includes(format)
        ? format
        : urlFormat && supported.includes(urlFormat)
          ? urlFormat
          : (mimeFormat ?? "mp3");
    const name = downloadName(
      config.fileTemplate.replaceAll("{artist}", artist).replaceAll("{title}", title),
    );
    let target = await join(dir, name + "." + extension);
    if (config.overwritePolicy === "skip" && (await exists(target))) {
      checkCanceled();
      task.filePath = target;
      task.status = "done";
      task.finishedAt = Date.now();
      announce(task);
      return;
    }
    if (config.overwritePolicy === "rename") {
      let suffix = 1;
      while (await exists(target)) {
        checkCanceled();
        target = await join(dir, name + " (" + suffix++ + ")." + extension);
      }
    }
    temporary = await join(root, downloadName(task.taskId) + ".part");
    file = await open(temporary, { write: true, create: true, truncate: true });
    task.status = "downloading";
    task.total = Number(response.headers.get("content-length")) || resolved.declaredSize || 0;
    announce(task);
    let lastProgress = 0;
    while (true) {
      checkCanceled();
      const chunk = await reader.read();
      checkCanceled();
      if (chunk.done) break;
      let offset = 0;
      while (offset < chunk.value.length) {
        checkCanceled();
        const written = await file.write(chunk.value.subarray(offset));
        if (written <= 0) throw new Error("file write failed");
        offset += written;
      }
      task.received += chunk.value.length;
      if (document.visibilityState !== "hidden" && Date.now() - lastProgress >= 200) {
        lastProgress = Date.now();
        progress.forEach((listener) =>
          listener({ taskId: task.taskId, received: task.received, total: task.total }),
        );
      }
    }
    if (!task.received) throw new Error("empty audio response");
    const expected = Number(response.headers.get("content-length"));
    if (expected > 0 && !response.headers.get("content-encoding") && task.received !== expected)
      throw new Error("incomplete audio response");
    await file.close();
    file = undefined;
    checkCanceled();
    running.finalizing = true;
    await rename(temporary, target);
    temporary = undefined;
    task.filePath = target;
    task.total = task.received;
    task.status = "done";
    task.finishedAt = Date.now();
    announce(task);
  } catch (error) {
    if (!controller.signal.aborted) {
      task.status = "failed";
      task.errorCode = error instanceof Error ? error.message : String(error);
      task.finishedAt = Date.now();
      announce(task);
    }
  } finally {
    await reader?.cancel().catch(() => undefined);
    await file?.close().catch(() => undefined);
    if (temporary) await remove(temporary).catch(() => undefined);
    if (pending.get(task.taskId) === request) pending.delete(task.taskId);
    running = undefined;
    void pump();
  }
};

const enqueue = async (
  request: DownloadRequest,
  previous?: DownloadTask,
): ReturnType<DownloadApi["start"]> => {
  await initialize();
  if (!store.get("download.enabled")) throw new Error("download disabled");
  const duplicate = tasks.find(
    (task) =>
      task.track.id === request.track.id &&
      task.track.source === request.track.source &&
      task.track.serverId === request.track.serverId &&
      task.qualityLevel === request.qualityLevel &&
      (active(task) || task.status === "done"),
  );
  if (duplicate && active(duplicate)) return { ok: false, reason: "queued" };
  if (duplicate?.filePath && (await exists(duplicate.filePath)))
    return { ok: false, reason: "downloaded" };
  if (tasks.length - (previous ? 1 : 0) >= MAX_TASKS) throw new Error("download history full");
  if (tasks.some((task) => task !== previous && task.taskId === request.taskId))
    return { ok: false, reason: "queued" };
  const task: DownloadTask = {
    taskId: request.taskId,
    track: request.track,
    qualityLevel: request.qualityLevel,
    status: "queued",
    received: 0,
    total: 0,
    createdAt: Date.now(),
  };
  pending.set(task.taskId, {
    ...request,
    tagOptions: {
      embedCover: false,
      embedMeta: false,
      embedLyric: false,
      writeLrc: false,
      saveTtml: false,
    },
  });
  if (previous) tasks.splice(tasks.indexOf(previous), 1);
  tasks.push(task);
  announce(task);
  void pump();
  return { ok: true };
};

const cancel: DownloadApi["cancel"] = async (id) => {
  const task = tasks.find((item) => item.taskId === id);
  if (!task || !active(task)) return;
  if (running?.task === task && running.finalizing) return;
  task.status = "canceled";
  task.finishedAt = Date.now();
  pending.delete(id);
  if (running?.task === task) running.controller.abort();
  announce(task);
};

export const mobileDownload: DownloadApi & { cancelAll: () => Promise<void> } = {
  start: enqueue,
  startMany: async (requests) => {
    const results: Awaited<ReturnType<typeof enqueue>>[] = [];
    for (const request of requests) results.push(await enqueue(request));
    return results;
  },
  retry: async (request) => {
    await initialize();
    const previous = tasks.find((task) => task.taskId === request.taskId);
    if (previous && active(previous)) return { ok: false, reason: "queued" };
    return enqueue(request, previous);
  },
  cancel,
  cancelAll: async () => {
    for (const task of tasks) await cancel(task.taskId);
  },
  remove: async (id) => {
    await initialize();
    await cancel(id);
    const index = tasks.findIndex((task) => task.taskId === id);
    if (index < 0) return;
    const task = tasks[index];
    if (active(task)) throw new Error("download is finishing");
    if (task.filePath && (await exists(task.filePath))) await remove(task.filePath);
    tasks.splice(tasks.indexOf(task), 1);
    persist();
  },
  clearFinished: async () => {
    await initialize();
    for (let index = tasks.length - 1; index >= 0; index--)
      if (!active(tasks[index])) tasks.splice(index, 1);
    persist();
  },
  list: async () => {
    await initialize();
    return tasks.map((task) => ({ ...task }));
  },
  getDir,
  pickDir: async () => ({ ok: false, dir: await getDir(), reason: "canceled" }),
  resetDir: getDir,
  submitResolution: async () => undefined,
  failResolution: async () => undefined,
  onResolve: () => () => undefined,
  onState: (callback) => {
    states.add(callback);
    return () => {
      states.delete(callback);
    };
  },
  onProgress: (callback) => {
    progress.add(callback);
    return () => {
      progress.delete(callback);
    };
  },
};
