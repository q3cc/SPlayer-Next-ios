import { installMobileApi } from "./api";
import { reportBootStage } from "../boot";
import { store } from "@main/store";
import { resolveInitialRoute } from "@shared/utils/initialRoute";
import { restartControlServices } from "./controlServices";

if ("__TAURI_INTERNALS__" in window || import.meta.env.MODE === "mobile") {
  reportBootStage("mobile-bootstrap-start");
  reportBootStage("mobile-api-install-start");
  installMobileApi();
  void restartControlServices().catch((error) =>
    console.error("[control] initialization failed", error),
  );
  const initialRoute = resolveInitialRoute({
    onboardingCompleted: store.get("system.onboardingCompleted"),
    agreedAgreementVersion: store.get("system.agreedAgreementVersion"),
  });
  if (initialRoute && (!location.hash || location.hash === "#/")) {
    history.replaceState(null, "", `#${initialRoute}`);
  }
  reportBootStage("mobile-bootstrap-ready");
}
