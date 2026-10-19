// PostToolUse hook: after an edit under frontend/, runs the same validation as the
// GitHub Pages deploy so a syntax error is fixed before it reaches master.
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const input = JSON.parse(readFileSync(0, "utf8"));
const path = String(input.tool_input?.file_path ?? "").replace(/\\/g, "/");

if (!/\/frontend\/.+\.(js|html)$/.test(path)) process.exit(0);

try {
  execFileSync("node", ["scripts/validate-repository.mjs"], {
    cwd: process.env.CLAUDE_PROJECT_DIR ?? input.cwd,
    encoding: "utf8",
    stdio: "pipe",
  });
} catch (error) {
  console.error(`scripts/validate-repository.mjs failed after this edit:\n${error.stderr || error.stdout}`);
  process.exit(2);
}
