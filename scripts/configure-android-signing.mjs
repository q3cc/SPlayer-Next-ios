import { readFileSync, writeFileSync } from "node:fs";

const buildFile = "src-tauri/gen/android/app/build.gradle.kts";
const marker = "// SPlayer Android release signing";
const source = readFileSync(buildFile, "utf8");

if (source.includes(marker)) {
  console.log("Android release signing is already configured");
  process.exit(0);
}

const buildTypes = /^([ \t]*)buildTypes\s*\{/m;
const release = /^([ \t]*)getByName\("release"\)\s*\{/m;
if (!buildTypes.test(source) || !release.test(source)) {
  throw new Error("The generated Android Gradle file has an unexpected signing layout");
}

const withSigning = source.replace(
  buildTypes,
  (_, indent) => `${indent}${marker}
${indent}signingConfigs {
${indent}    create("release") {
${indent}        val properties = Properties()
${indent}        rootProject.file("keystore.properties").inputStream().use { properties.load(it) }
${indent}        keyAlias = properties.getProperty("keyAlias")
${indent}        keyPassword = properties.getProperty("password")
${indent}        storeFile = file(properties.getProperty("storeFile"))
${indent}        storePassword = properties.getProperty("password")
${indent}    }
${indent}}

${indent}buildTypes {`,
);
const signed = withSigning.replace(
  release,
  (_, indent) => `${indent}getByName("release") {
${indent}    signingConfig = signingConfigs.getByName("release")`,
);
writeFileSync(buildFile, signed);
console.log("Configured Android release signing");
