// Build step: write the tool contract to mcp/contract/tools.json.
//
// Invoked by `npm run gen:contract` (which `build` runs after tsc). Emits the
// deterministic fixture and prints where it landed and how many tools it holds.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildContract, serializeContract } from "./contract.ts";

function main(): void {
  const contract = buildContract();
  const json = serializeContract(contract);
  const outPath = fileURLToPath(new URL("../contract/tools.json", import.meta.url));
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, json);
  process.stdout.write(`Wrote ${contract.toolCount} tools to ${outPath}\n`);
}

main();
