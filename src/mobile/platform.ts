/** Release builds select one mobile OS before bundling platform modules. */
export const isAndroid =
  import.meta.env.VITE_MOBILE_TARGET === "android" ||
  (import.meta.env.VITE_MOBILE_TARGET !== "ios" && /Android/i.test(navigator.userAgent));
export const isIOS = !isAndroid;
