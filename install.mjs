import { execFile as execFileCb } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const execFile = promisify(execFileCb);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.join(__dirname, "app", "CodexUsageHalo.swift");
const appPath = path.join(os.homedir(), "Applications", "Codex Pet Meter.app");
const contentsPath = path.join(appPath, "Contents");
const macosPath = path.join(contentsPath, "MacOS");
const executablePath = path.join(macosPath, "CodexPetMeter");
const plistPath = path.join(contentsPath, "Info.plist");

function plist() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>CodexPetMeter</string>
  <key>CFBundleIdentifier</key>
  <string>com.rainsday.codex-pet-meter</string>
  <key>CFBundleName</key>
  <string>Codex Pet Meter</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.3.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
</dict>
</plist>
`;
}

async function run(command, args, options = {}) {
  try {
    return await execFile(command, args, { maxBuffer: 1024 * 1024 * 10, ...options });
  } catch (error) {
    if (options.ignoreFailure) return error;
    throw error;
  }
}

async function install() {
  await stop();
  await fs.mkdir(macosPath, { recursive: true });
  await fs.writeFile(plistPath, plist(), "utf8");
  await run("/usr/bin/swiftc", [
    sourcePath,
    "-O",
    "-framework",
    "Cocoa",
    "-o",
    executablePath,
  ]);
  await fs.chmod(executablePath, 0o755);
  await run("/usr/bin/codesign", ["--force", "--sign", "-", appPath], { ignoreFailure: true });
  await start();
  console.log(`Installed ${appPath}`);
}

async function start() {
  await stop();
  await run("/usr/bin/open", ["-n", appPath]);
  console.log(`Started ${appPath}`);
}

async function status() {
  const result = await run("/usr/bin/pgrep", ["-fl", "CodexPetMeter"], { ignoreFailure: true });
  const stdout = "stdout" in result ? result.stdout.trim() : "";
  console.log(stdout || "Codex Pet Meter is not running.");
}

async function stop() {
  await run("/usr/bin/pkill", ["-f", "CodexPetMeter"], { ignoreFailure: true });
}

async function uninstall() {
  await stop();
  await fs.rm(appPath, { recursive: true, force: true });
  console.log(`Removed ${appPath}`);
}

const command = process.argv[2] || "install";
if (command === "install") await install();
else if (command === "start") await start();
else if (command === "status") await status();
else if (command === "uninstall") await uninstall();
else {
  console.error("Usage: node install.mjs install|start|status|uninstall");
  process.exitCode = 1;
}
