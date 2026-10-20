import { Buffer } from "buffer";
import { createPluginRuntime } from "@main/plugins/runtime";
import { parsePluginScript } from "@shared/utils/pluginScript";
import { HOST_API_LEVEL } from "@shared/defaults/plugin-api";
import type { SandboxIn } from "@shared/types/plugin";

declare const __nativeSend: (message: string) => void;
const root = globalThis as typeof globalThis & {
  __receive: (input: SandboxIn) => void;
  __parsePlugin: typeof parsePluginScript;
};
root.Buffer = Buffer;
root.__parsePlugin = parsePluginScript;
createPluginRuntime(
  {
    on: (_event, callback) => {
      root.__receive = (data) => callback({ data });
    },
    postMessage: (message) =>
      __nativeSend(
        JSON.stringify(message, (_key, value) =>
          value instanceof Uint8Array ? { __nativeBytes: Array.from(value) } : value,
        ),
      ),
    evaluate: (source, globals) => {
      globals.window ??= globals;
      globals.self = globals;
      globals.globalThis = globals;
      globals.importScripts = undefined;
      globals.navigator = undefined;
      globals.document = undefined;
      new Function(...Object.keys(globals), source).call(globals, ...Object.values(globals));
    },
  },
  "mobile",
);
export { HOST_API_LEVEL };
