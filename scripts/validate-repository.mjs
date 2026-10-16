import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import vm from "node:vm";

const root = new URL("../", import.meta.url).pathname.replace(/^\/(.:)/, "$1");
const frontend = join(root, "frontend");
const files = [];

function walk(directory) {
  for (const name of readdirSync(directory)) {
    const path = join(directory, name);
    if (statSync(path).isDirectory()) walk(path);
    else files.push(path);
  }
}

walk(frontend);
const failures = [];

for (const file of files.filter((path) => path.endsWith(".js"))) {
  try {
    new vm.Script(readFileSync(file, "utf8"), { filename: relative(root, file) });
  } catch (error) {
    failures.push(`${relative(root, file)}: ${error.message}`);
  }
}

for (const file of files.filter((path) => path.endsWith(".html"))) {
  const source = readFileSync(file, "utf8");
  if (source.includes("@supabase/supabase-js@2\"")) {
    failures.push(`${relative(root, file)}: Supabase JS must use an exact version.`);
  }
}

if (failures.length) {
  console.error(failures.join("\n"));
  process.exit(1);
}

console.log(`Validated ${files.filter((path) => path.endsWith(".js")).length} JavaScript files and ${files.filter((path) => path.endsWith(".html")).length} HTML files.`);
