import { reportBootStage, showBootError } from "./boot";

const boot = async (): Promise<void> => {
  // 桌面共享模块会在求值时同步读取 window.api，移动桥接必须先完成安装。
  if (import.meta.env.MODE === "mobile") {
    reportBootStage("mobile-bootstrap-start");
    await import("./mobile/bootstrap");
    reportBootStage("mobile-bootstrap-ready");
  }
  reportBootStage("application-import-start");
  const { bootstrap } = await import("./bootstrap");
  await bootstrap();
  reportBootStage("application-import-ready");
};

void boot().catch(showBootError);
