// PreToolUse hook: enforces two AGENTS.md rules before Claude acts.
// 1. Historical migrations are never edited (AGENTS.md section 5).
// 2. Claude never pushes to master, because every push there deploys (section 4).
// Exit code 2 blocks the tool call and shows the message to Claude.
import { existsSync, readFileSync } from "node:fs";
import { execSync } from "node:child_process";

const input = JSON.parse(readFileSync(0, "utf8"));
const toolInput = input.tool_input ?? {};

function block(message) {
  console.error(message);
  process.exit(2);
}

function isCommitted(path) {
  try {
    return execSync(`git log -1 --format=%H -- "${path}"`, { cwd: input.cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim() !== "";
  } catch {
    return false;
  }
}

if (input.tool_name === "Bash") {
  const command = String(toolInput.command ?? "");
  for (const push of command.match(/git\s+push\b[^;&|]*/g) ?? []) {
    if (/(^|[\s:+])master\b/.test(push.replace(/^git\s+push/, ""))) {
      block("Pushing to master deploys to production. Push a claude/<topic> branch and open a Pull Request.");
    }
    const hasRefspec = push.split(/\s+/).slice(2).filter((arg) => !arg.startsWith("-")).length > 1;
    if (!hasRefspec) {
      let branch = "";
      try {
        branch = execSync("git rev-parse --abbrev-ref HEAD", { cwd: input.cwd, encoding: "utf8" }).trim();
      } catch {}
      if (branch === "master") {
        block("The current branch is master. Create a claude/<topic> branch before pushing.");
      }
    }
  }
} else {
  const path = String(toolInput.file_path ?? "").replace(/\\/g, "/");
  // Only committed migrations are history; a new file in this task can still be corrected.
  if (/\/supabase\/migrations\/[^/]+\.sql$/.test(path) && existsSync(path) && isCommitted(path)) {
    block("This migration is already committed. Historical migrations are never edited: create a new migration file instead (see the new-migration skill).");
  }
}
