<script setup lang="ts">
import { useStatusStore } from "@/stores/status";
import { useSettingsStore } from "@/stores/settings";
import { getFftFrame } from "@/services/playback";
import { acquireFft, releaseFft } from "@/services/fftCapture";

interface Props {
  /** 是否处于活跃状态 */
  show?: boolean;
  /** 高度（px），默认 80 */
  height?: number;
  /** bar 圆角（px），默认 2 */
  radius?: number;
  /** 最大画布宽度（px），默认 1920 */
  maxWidth?: number;
}

const props = withDefaults(defineProps<Props>(), {
  show: true,
  height: 80,
  radius: 2,
  maxWidth: 1920,
});

const status = useStatusStore();
const settings = useSettingsStore();

const canvasRef = ref<HTMLCanvasElement | null>(null);
const visibility = useDocumentVisibility();
let context: CanvasRenderingContext2D | null = null;
let cssWidth = 0;
let cssHeight = 0;
let barWidth = 1;
let slotWidth = 4;
let binRanges: Array<readonly [number, number]> = [];

/** 仅尺寸或柱宽变化时重建频段映射。 */
const updateBins = (): void => {
  barWidth = Math.max(1, settings.player.spectrumBarWidth);
  slotWidth = barWidth + BAR_GAP;
  const count = Math.floor(cssWidth / slotWidth);
  const length = (FFT_SIZE - SKIP_LOW) * 2;
  binRanges = Array.from({ length: count }, (_, i) => {
    const start = Math.floor((i * length) / count);
    const end = Math.floor(((i + 1) * length) / count);
    return [Math.max(0, start - 1), Math.min(length, Math.max(end, start + 1) + 1)];
  });
};

/** 后端推送数据长度 */
const FFT_SIZE = 128;
/** 极低频跳过的段数（噪声多） */
const SKIP_LOW = 8;
/** bar 之间的固定间隙（px） */
const BAR_GAP = 3;
/** 后端推送间隔（ms），用于时间插值 */
const PUSH_INTERVAL = 50;

/** 上一帧推送数据 */
const prev = [new Float32Array(FFT_SIZE), new Float32Array(FFT_SIZE)];
/** 当前帧推送数据 */
const curr = [new Float32Array(FFT_SIZE), new Float32Array(FFT_SIZE)];
/** 实际渲染显示值（经过指数平滑） */
const display = [new Float32Array(FFT_SIZE), new Float32Array(FFT_SIZE)];
/** 双声道显示值 */
const stereoDisplay = new Float32Array(FFT_SIZE * 2);
/** 上一次推送数据的引用，用于检测新帧到达 */
let lastRef: readonly [number[], number[]] = [[], []];
/** 上一次推送到达的时间戳 */
let lastUpdate = 0;

/** 调整画布大小 */
const resizeCanvas = (): void => {
  const canvas = canvasRef.value;
  if (!canvas) return;
  const dpr = window.devicePixelRatio || 1;
  cssWidth = Math.min(document.body.clientWidth, props.maxWidth);
  cssHeight = props.height;
  canvas.style.width = `${cssWidth}px`;
  canvas.style.height = `${props.height}px`;
  const width = Math.round(cssWidth * dpr);
  const height = Math.round(cssHeight * dpr);
  if (canvas.width !== width) canvas.width = width;
  if (canvas.height !== height) canvas.height = height;
  context ??= canvas.getContext("2d");
  context?.setTransform(dpr, 0, 0, dpr, 0, 0);
  updateBins();
};

/** 绘制频谱 */
const draw = (): void => {
  const canvas = canvasRef.value;
  if (!canvas) return;
  const ctx = context;
  if (!ctx) return;

  // 检测新帧推送
  const data = getFftFrame();
  if (data !== lastRef) {
    lastRef = data;
    prev[0].set(curr[0]);
    prev[1].set(curr[1]);
    for (let i = 0; i < FFT_SIZE; i++) {
      curr[0][i] = data[0][i] ?? 0;
      curr[1][i] = data[1][i] ?? 0;
    }
    lastUpdate = performance.now();
  }

  // 时间插值：在 prev → curr 之间按时间平滑过渡，消除 20Hz stair-step
  const t = Math.min((performance.now() - lastUpdate) / PUSH_INTERVAL, 1);
  // 上行快（响应灵敏），下行慢（视觉柔和）
  const ATTACK = 0.4;
  const DECAY = 0.88;

  // 处理双声道
  for (let c = 0; c < 2; c++) {
    for (let i = 0; i < FFT_SIZE; i++) {
      const target = prev[c][i] + (curr[c][i] - prev[c][i]) * t;
      if (target > display[c][i]) {
        display[c][i] = display[c][i] + (target - display[c][i]) * ATTACK;
      } else {
        display[c][i] = display[c][i] * DECAY + target * (1 - DECAY);
      }
    }
  }
  // 直接写入预分配缓冲区，避免 RAF 热路径产生临时数组
  const channelLength = FFT_SIZE - SKIP_LOW;
  const reverse = settings.player.reverseSpectrum;
  for (let i = 0; i < channelLength; i++) {
    if (reverse) {
      stereoDisplay[channelLength + i] = display[0][FFT_SIZE - 1 - i];
      stereoDisplay[i] = display[1][SKIP_LOW + i];
    } else {
      stereoDisplay[i] = display[0][FFT_SIZE - 1 - i];
      stereoDisplay[channelLength + i] = display[1][SKIP_LOW + i];
    }
  }

  ctx.clearRect(0, 0, cssWidth, cssHeight);
  ctx.fillStyle = getComputedStyle(canvas).color;
  ctx.beginPath();

  for (let i = 0; i < binRanges.length; i++) {
    // 每个 bar 覆盖一段 bin，再扩 1 个邻居做空间平滑，避免相邻 bin 方差导致的悬崖
    const [lo, hi] = binRanges[i];
    let sum = 0;
    for (let j = lo; j < hi; j++) sum += stereoDisplay[j];
    const v = sum / (hi - lo);

    const barHeight = v * cssHeight;
    if (barHeight <= 0.5) continue;
    const y = cssHeight - barHeight;
    const x = i * slotWidth;
    ctx.roundRect(x, y, barWidth, barHeight, props.radius);
  }
  ctx.fill();
};

const { resume, pause } = useRafFn(draw, { immediate: false });

// 本地持有标记，保证 acquire / release 严格配对
let fftAcquired = false;

const startCapture = (): void => {
  if (!fftAcquired) {
    acquireFft();
    fftAcquired = true;
  }
  resume();
};

const stopCapture = (): void => {
  pause();
  if (fftAcquired) {
    releaseFft();
    fftAcquired = false;
  }
};

// 暂停时停止 FFT 推送 + RAF 重绘
watch(
  () => status.isPlaying && visibility.value === "visible",
  (active) => {
    if (active) startCapture();
    else stopCapture();
  },
  { immediate: true },
);
watch(() => settings.player.spectrumBarWidth, updateBins);
watch(() => [props.height, props.maxWidth], resizeCanvas);

onMounted(() => {
  resizeCanvas();
  window.addEventListener("resize", resizeCanvas);
});

onBeforeUnmount(() => {
  window.removeEventListener("resize", resizeCanvas);
  stopCapture();
  context = null;
  prev[0].fill(0);
  prev[1].fill(0);
  curr[0].fill(0);
  curr[1].fill(0);
  display[0].fill(0);
  display[1].fill(0);
  lastRef = [[], []];
});
</script>

<template>
  <div
    class="absolute left-0 bottom-0 w-full flex justify-center z-0 pointer-events-none transition-opacity duration-300"
    :style="{ opacity: show ? 0.65 : 0.15 }"
  >
    <canvas ref="canvasRef" class="spectrum-canvas" />
  </div>
</template>

<style scoped>
.spectrum-canvas {
  mask: linear-gradient(
    90deg,
    hsla(0, 0%, 100%, 0) 0,
    hsla(0, 0%, 100%, 0.6) 5%,
    #fff 12%,
    #fff 88%,
    hsla(0, 0%, 100%, 0.6) 95%,
    hsla(0, 0%, 100%, 0)
  );
}
</style>
