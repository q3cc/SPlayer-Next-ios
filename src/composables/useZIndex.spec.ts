import { expect, it } from "vitest";
import { usePopupZIndex, DEFAULT_Z_INDEX } from "./useZIndex";

it("后打开的浮层位于前一个上方，全部关闭后恢复基准", () => {
  const dialog = usePopupZIndex();
  const menu = usePopupZIndex();
  dialog.onOpenChange(true);
  menu.onOpenChange(true);
  expect(menu.zIndex.value).toBeGreaterThan(dialog.zIndex.value);
  menu.onOpenChange(false);
  dialog.onOpenChange(false);
  dialog.onOpenChange(true);
  expect(dialog.zIndex.value).toBe(DEFAULT_Z_INDEX + 1);
  dialog.release();
});
it("明确指定层级的更新弹窗不被自动层级覆盖", () => {
  const update = usePopupZIndex(10000);
  update.onOpenChange(true);
  expect(update.zIndex.value).toBe(10000);
  update.release();
});
