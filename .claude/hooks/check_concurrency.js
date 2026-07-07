#!/usr/bin/env node
// PostToolUse hook: warns when an edit introduces concurrency red flags in Sources/.
// Runtime-agnostic: handles Claude Code and GitHub Copilot (VS Code / CLI) payloads.
// Some agents ignore matchers and run every hook on every tool, so this self-filters
// on the file path and only acts when red flags appear in the *added* text.

const fs = require("fs");

const RED_FLAGS = ["@unchecked Sendable", "nonisolated(unsafe)", "try!", "fatalError("];

// Tool input lives under different keys across agents.
function toolInput(data) {
  return data.tool_input || data.toolArgs || data.tool_args || {};
}

function main() {
  let data;
  try {
    data = JSON.parse(fs.readFileSync(0, "utf8"));
  } catch {
    return;
  }
  const input = toolInput(data);
  const path = input.file_path || input.filePath || input.path || "";
  if (!path.includes("/Sources/") || !path.endsWith(".swift")) {
    return;
  }
  // Only inspect the text added by this edit, not pre-existing code. The field name
  // varies across agents and tools (Edit/Write, create_file/replace_string_in_file, …).
  const added =
    input.new_string || input.newString ||
    input.content || input.newText ||
    input.code || input.contents || "";
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
