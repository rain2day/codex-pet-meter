import { execFile as execFileCb } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const execFile = promisify(execFileCb);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.join(__dirname, "app", "CodexUsageHalo.swift");
const serverScriptPath = path.join(__dirname, "server.mjs");
const appPath = path.join(os.homedir(), "Applications", "Codex Pet Meter.app");
const contentsPath = path.join(appPath, "Contents");
const macosPath = path.join(contentsPath, "MacOS");
const executablePath = path.join(macosPath, "CodexPetMeter");
const plistPath = path.join(contentsPath, "Info.plist");

// LaunchAgent (server) — keeps the usage server running across reboots
const serverLabel = "com.rainsday.codex-pet-meter.server";
const launchAgentDir = path.join(os.homedir(), "Library", "LaunchAgents");
const launchAgentPath = path.join(launchAgentDir, `${serverLabel}.plist`);
const serverLogPath = "/tmp/codex-pet-meter-server.log";

function userServiceTarget() {
  return `gui/${process.getuid?.() ?? 501}/${serverLabel}`;
}

function userDomainTarget() {
  return `gui/${process.getuid?.() ?? 501}`;
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function launchAgentPlist() {
  // process.execPath is the absolute path of the node binary that ran this
  // installer — a reliable resolution that doesn't depend on launchd's PATH.
  const nodePath = process.execPath;
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${serverLabel}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${nodePath}</string>
    <string>${serverScriptPath}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>${serverLogPath}</string>
  <key>StandardErrorPath</key>
  <string>${serverLogPath}</string>
</dict>
</plist>
`;
}

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
  <string>0.1.0</string>
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
    <key>NSAllowsLocalNetworking</key>
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
  await installServer();
  await start();
  console.log(`Installed ${appPath}`);
}

async function start() {
  await stop();
  await startServer();
  await run("/usr/bin/open", ["-n", appPath]);
  console.log(`Started ${appPath}`);
}

async function installServer() {
  await stopServer();
  await fs.mkdir(launchAgentDir, { recursive: true });
  await fs.writeFile(launchAgentPath, launchAgentPlist(), "utf8");
  await run("/bin/launchctl", ["bootstrap", userDomainTarget(), launchAgentPath], { ignoreFailure: true });
  console.log(`Installed server LaunchAgent at ${launchAgentPath}`);
  console.log(`Server log: ${serverLogPath}`);
}

async function startServer() {
  if (!(await fileExists(launchAgentPath))) {
    await installServer();
    return;
  }
  // bootstrap is a no-op if already loaded; harmless to call every time.
  await run("/bin/launchctl", ["bootstrap", userDomainTarget(), launchAgentPath], { ignoreFailure: true });
  // kickstart -k = restart (kill + start) for a known-good state every time
  await run("/bin/launchctl", ["kickstart", "-k", userServiceTarget()], { ignoreFailure: true });
}

async function stopServer() {
  if (!(await fileExists(launchAgentPath))) return;
  await run("/bin/launchctl", ["bootout", userServiceTarget()], { ignoreFailure: true });
}

async function statusServer() {
  const result = await run("/bin/launchctl", ["print", userServiceTarget()], { ignoreFailure: true });
  const stdout = "stdout" in result ? result.stdout : "";
  if (!stdout) {
    console.log("Server: not loaded.");
    return;
  }
  const stateMatch = stdout.match(/state\s*=\s*(\S+)/);
  const pidMatch = stdout.match(/pid\s*=\s*(\d+)/);
  console.log(`Server state: ${stateMatch?.[1] ?? "unknown"}${pidMatch ? ` (pid ${pidMatch[1]})` : ""}`);
  console.log(`Server log: ${serverLogPath}`);
}

async function uninstallServer() {
  await stopServer();
  if (await fileExists(launchAgentPath)) {
    await fs.rm(launchAgentPath, { force: true });
    console.log(`Removed ${launchAgentPath}`);
  }
}

async function reset() {
  await stop();
  await run("/usr/bin/open", ["-n", appPath, "--args", "--reset-position"]);
  console.log(`Started ${appPath} with reset position`);
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
  await uninstallServer();
  await fs.rm(appPath, { recursive: true, force: true });
  console.log(`Removed ${appPath}`);
}

async function trace() {
  await stop();
  await run("/usr/bin/open", ["-n", appPath, "--args", "--trace"]);
  console.log(`Started ${appPath} with --trace`);
  console.log(`Live: tail -f /tmp/codex-usage-halo-trace.log`);
}

async function traceStop() {
  await stop();
  const tracePath = "/tmp/codex-usage-halo-trace.log";
  try {
    await fs.access(tracePath);
    const dest = `/tmp/halo-trace-${Date.now()}.txt`;
    await fs.copyFile(tracePath, dest);
    console.log(`Snapshot: ${dest}`);
  } catch {
    console.log("(no trace log to snapshot)");
  }
  await run("/usr/bin/open", ["-n", appPath]);
  console.log("Restarted in normal mode");
}

const command = process.argv[2] || "install";
if (command === "install") await install();
else if (command === "start") await start();
else if (command === "reset") await reset();
else if (command === "status") await status();
else if (command === "uninstall") await uninstall();
else if (command === "trace") await trace();
else if (command === "trace-stop") await traceStop();
else if (command === "install-server") await installServer();
else if (command === "start-server") await startServer();
else if (command === "stop-server") await stopServer();
else if (command === "status-server") await statusServer();
else if (command === "uninstall-server") await uninstallServer();
else {
  console.error([
    "Usage: node install.mjs <command>",
    "",
    "App commands:",
    "  install            build app + install server LaunchAgent + start both",
    "  start              restart app (and ensure server is running)",
    "  reset              start app with --reset-position",
    "  status             show running app process",
    "  uninstall          stop and remove app + server LaunchAgent",
    "  trace              start app with --trace (verbose log)",
    "  trace-stop         snapshot trace log + restart in normal mode",
    "",
    "Server commands (LaunchAgent — survives reboots):",
    "  install-server     write LaunchAgent plist + load it",
    "  start-server       (re)start the server via launchd",
    "  stop-server        stop the server via launchd",
    "  status-server      show server state + log path",
    "  uninstall-server   stop + remove LaunchAgent plist",
  ].join("\n"));
  process.exitCode = 1;
}
