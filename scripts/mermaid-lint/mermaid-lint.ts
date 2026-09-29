// Parse-validate ```mermaid blocks with mermaid's own parser under linkedom (parse-only — no
// browser, no rendering). A block that fails here is a block GitHub refuses to render ("Unable to
// render rich display"); docs/README.md §Conventions requires diagrams to render on GitHub.
// Version caveat: the pinned mermaid may lag/lead GitHub's — parity is close, not exact.
//
// Runs with NO Deno permissions (ADR-143): no env, no fs, no net, no subprocess. The markdown
// arrives on stdin as NUL-separated `path\0content\0` pairs written by scripts/mermaid-lint.sh, so
// this process — and every dependency it imports — can read nothing it was not handed.
import { parseHTML } from "linkedom";

const dom = parseHTML("<!DOCTYPE html><html><body></body></html>");
const g = globalThis as Record<string, unknown>;
g.window = dom;
g.document = dom.document;

const mermaid = (await import("mermaid")).default;
mermaid.initialize({ startOnLoad: false });

const parts = (await new Response(Deno.stdin.readable).text()).split("\0");
let files = 0;
let blocks = 0;
let failures = 0;
for (let k = 0; k + 1 < parts.length; k += 2) {
  const file = parts[k];
  const lines = parts[k + 1].split("\n");
  files++;
  let block: string[] | null = null;
  let start = 0;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (block === null && /^\s*```mermaid\s*$/.test(l)) {
      block = [];
      start = i + 2; // first line inside the fence, 1-indexed
      continue;
    }
    if (block !== null && /^\s*```\s*$/.test(l)) {
      blocks++;
      try {
        await mermaid.parse(block.join("\n"));
      } catch (e) {
        failures++;
        const msg = String((e as Error)?.message ?? e).split("\n", 1)[0];
        console.log(`FAIL ${file}:${start} — ${msg}`);
      }
      block = null;
      continue;
    }
    if (block !== null) block.push(l);
  }
  if (block !== null) {
    failures++;
    console.log(`FAIL ${file}:${start} — unterminated \`\`\`mermaid fence`);
  }
}
console.log(`mermaid-lint: ${blocks} block(s) across ${files} file(s), ${failures} failure(s)`);
if (failures > 0) Deno.exit(1);
