import { copyFileSync, mkdirSync, readdirSync } from "node:fs";
import { join } from "node:path";

const iconRoot = "src-tauri/icons/android";
const resourceRoot = "src-tauri/gen/android/app/src/main/res";

for (const directory of [
  "mipmap-anydpi-v26",
  "mipmap-mdpi",
  "mipmap-hdpi",
  "mipmap-xhdpi",
  "mipmap-xxhdpi",
  "mipmap-xxxhdpi",
  "values",
]) {
  const destination = join(resourceRoot, directory);
  mkdirSync(destination, { recursive: true });
  for (const file of readdirSync(join(iconRoot, directory))) {
    copyFileSync(join(iconRoot, directory, file), join(destination, file));
  }
}

console.log("Configured Android launcher icons");
