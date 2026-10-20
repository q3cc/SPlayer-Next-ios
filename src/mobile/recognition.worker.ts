import { GenerateFP } from "../../resources/afp/afp.mjs";

self.onmessage = async (event: MessageEvent<Float32Array>) => {
  try {
    const fingerprint = await GenerateFP(event.data);
    self.postMessage({ fingerprint });
  } catch {
    self.postMessage({ error: "音频指纹计算失败" });
  }
};
