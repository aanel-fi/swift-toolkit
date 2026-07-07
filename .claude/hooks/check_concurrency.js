#!/usr/bin/env node
// PostToolUse hook: warns when an edit introduces concurrency red flags in Sources/.

const fs = require("fs");

const RED_FLAGS = ["@unchecked Sendable", "nonisolated(unsafe)", "try!", "fatalError("];

function main() {
  let data;
  try {
    data = JSON.parse(fs.readFileSync(0, "utf8"));
  } catch {
    return;
  }
  const toolInput = data.tool_input || {};
  const path = toolInput.file_path || "";
  if (!path.includes("/Sources/") || !path.endsWith(".swift")) {
    return;
  }
  // Only inspect the text added by this edit, not pre-existing code.
  const added = toolInput.new_string || toolInput.content || "";
  const found = RED_FLAGS.filter((flag) => added.includes(flag));
  if (found.length > 0) {
    const flags = found.map((f) => "`" + f + "`").join(", ");
    process.stderr.write(
      `This edit adds ${flags} to library sources. These are usually the wrong fix ` +
        "for a concurrency or error-handling problem. Consult the swift-concurrency " +
        "skill: prefer Mutex from ReadiumShared, genuine Sendable conformance, or " +
        "proper error propagation. If the usage is genuinely justified, keep it and " +
        "add a comment explaining the protecting invariant.\n"
    );
    process.exit(2);
  }
}

main();
process.exit(0);
