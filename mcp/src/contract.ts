// The contract generator (docs/spec/03 "Contract tests").
//
// It introspects the registered tools and produces a deterministic JSON fixture
// — names, the API method each maps to, the mutating flag, the input JSON schema
// (from the zod schema), and the declared output shape. The build writes it to
// mcp/contract/tools.json; the drift gate (08) renders the public capability
// table from it, and a test fails the build if a tool is added or removed
// without regenerating.

import { zodToJsonSchema } from "zod-to-json-schema";
import { TOOLS } from "./tools.ts";
import { KNOWN_API_VERSIONS } from "./client.ts";

export interface ContractTool {
  name: string;
  method: string;
  mutating: boolean;
  description: string;
  inputSchema: unknown;
  output: unknown;
}

export interface Contract {
  generator: string;
  apiVersions: number[];
  toolCount: number;
  tools: ContractTool[];
}

/** ASCII-stable name comparison (locale-independent for reproducible output). */
function byName(a: { name: string }, b: { name: string }): number {
  return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
}

/** Introspect the registered tools into the contract object. */
export function buildContract(): Contract {
  const tools: ContractTool[] = [...TOOLS].sort(byName).map((t) => ({
    name: t.name,
    method: t.method,
    mutating: t.mutating,
    description: t.description,
    inputSchema: zodToJsonSchema(t.input, { $refStrategy: "none" }),
    output: zodToJsonSchema(t.outputSchema, { $refStrategy: "none" }),
  }));
  return {
    generator: "@plugsight/mcp gen:contract",
    apiVersions: [...KNOWN_API_VERSIONS],
    toolCount: tools.length,
    tools,
  };
}

/** Recursively sort object keys so serialization is byte-stable regardless of
 * insertion order. Arrays keep their (already deterministic) order. */
function stableSort(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stableSort);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      out[key] = stableSort((value as Record<string, unknown>)[key]);
    }
    return out;
  }
  return value;
}

/** Deterministic, diff-friendly serialization (sorted keys, 2-space indent,
 * trailing newline). */
export function serializeContract(contract: Contract): string {
  return JSON.stringify(stableSort(contract), null, 2) + "\n";
}
