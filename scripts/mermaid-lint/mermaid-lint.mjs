// Parse-validate every ```mermaid block in the .md files given as argv, using mermaid's own
// parser under jsdom (parse-only — no chromium, no rendering). A block that fails here is a
// block GitHub refuses to render ("Unable to render rich display"); docs/README.md §Conventions
// requires diagrams to render on GitHub. Exit 1 with file:line per failing block.
// Version caveat: the pinned mermaid may lag/lead GitHub's — parity is close, not exact.
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<!DOCTYPE html><html><body></body></html>', { pretendToBeVisual: true });
globalThis.window = dom.window;
globalThis.document = dom.window.document;
Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });
// parse() never sanitizes rendered output; the stub only satisfies mermaid's import-time probe
globalThis.DOMPurify = { sanitize: (x) => x, addHook: () => {} };

const mermaid = (await import('mermaid')).default;
mermaid.initialize({ startOnLoad: false });

let blocks = 0;
let failures = 0;
for (const file of process.argv.slice(2)) {
  const lines = readFileSync(file, 'utf8').split('\n');
  let block = null;
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
        await mermaid.parse(block.join('\n'));
      } catch (e) {
        failures++;
        const msg = String(e?.message ?? e).split('\n', 1)[0];
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
console.log(`mermaid-lint: ${blocks} block(s) across ${process.argv.length - 2} file(s), ${failures} failure(s)`);
process.exit(failures ? 1 : 0);
