import vm from "node:vm";
import { createPluginRuntime } from "./runtime";
import type { SandboxIn, SandboxOut } from "@shared/types/plugin";

const parentPort = (
  process as unknown as {
    parentPort: {
      on: (event: "message", callback: (event: { data: SandboxIn }) => void) => void;
      postMessage: (message: SandboxOut) => void;
    };
  }
).parentPort;

if (!parentPort) process.exit(1);

createPluginRuntime({
  on: (event, callback) => parentPort.on(event, callback),
  postMessage: (message) => parentPort.postMessage(message),
  evaluate: (source, globals, pluginId) => {
    const context = vm.createContext(globals, {
      name: `plugin:${pluginId}`,
      codeGeneration: { strings: true, wasm: false },
    });
    new vm.Script(source, { filename: `plugin-${pluginId}.js` }).runInContext(context, {
      timeout: 10_000,
      breakOnSigint: false,
    });
  },
});

process.on("unhandledRejection", (reason) => {
  parentPort.postMessage({
    kind: "log",
    level: "error",
    args: ["unhandledRejection:", reason instanceof Error ? reason.message : String(reason)],
  });
});
process.on("uncaughtException", (error) => {
  parentPort.postMessage({
    kind: "log",
    level: "error",
    args: ["uncaughtException:", error.message],
  });
});
