import { createPluginRuntime } from "@main/plugins/runtime";

/** 每个插件独占 Worker；禁用、卸载或超时会终止线程并释放定时器。 */
createPluginRuntime({
  on: (_event, callback) => {
    self.onmessage = callback;
  },
  postMessage: (message) => self.postMessage(message),
  evaluate: (source, globals) => {
    globals.window ??= globals;
    globals.self = globals;
    globals.setImmediate = (callback: () => void) => setTimeout(callback, 0);
    globals.clearImmediate = clearTimeout;
    const evaluate = new Function(...Object.keys(globals), source);
    evaluate.call(globals, ...Object.values(globals));
  },
});
