// The error model shared across the MCP adapter.
//
// Tool-level errors carry the daemon's human `message` UNTOUCHED plus the stable
// `kind` from docs/spec/02 (the agent reads the same honest error the human
// does). Two kinds are client-side only: `daemon_unreachable` (the socket is not
// there) and `unsupported_api_version` (the daemon speaks a version this build
// does not know). The daemon-unreachable fix text is LITERAL and load-bearing:
// the drift gate and the docs quote it verbatim.

/** The literal recovery instruction for a missing daemon (docs/spec/03). */
export const DAEMON_UNREACHABLE_FIX =
  "Start Plugsight from /Applications, or run its Start monitoring command";

/** Stable machine-readable error kinds. The first block is the daemon's frozen
 * set (02); the next two are raised by the adapter itself; `unknown` is the
 * neutral fallback for a daemon error whose `kind` is absent or unrecognized,
 * so agents never branch on a guessed kind. */
export type ErrorKind =
  | "unauthorized"
  | "not_found"
  | "scanner_unavailable"
  | "permission_missing"
  | "es_inactive"
  | "invalid_params"
  | "conflict"
  | "daemon_unreachable"
  | "unsupported_api_version"
  | "unknown";

/** The full set of ErrorKinds, used to validate a daemon-supplied `data.kind`
 * before we trust it. Anything outside this set falls back to `unknown`. */
const KNOWN_ERROR_KINDS: ReadonlySet<string> = new Set<ErrorKind>([
  "unauthorized",
  "not_found",
  "scanner_unavailable",
  "permission_missing",
  "es_inactive",
  "invalid_params",
  "conflict",
  "daemon_unreachable",
  "unsupported_api_version",
  "unknown",
]);

/** A structured error with a stable `kind`, a human `message`, and any extra
 * `data` the daemon rode alongside `kind` (e.g. the running scanId on a
 * conflict). */
export class PlugsightError extends Error {
  readonly kind: ErrorKind;
  readonly data: Record<string, unknown>;

  constructor(kind: ErrorKind, message: string, data: Record<string, unknown> = {}) {
    super(message);
    this.name = "PlugsightError";
    this.kind = kind;
    this.data = data;
  }

  /** The daemon is not reachable on its socket. Always carries the literal fix. */
  static daemonUnreachable(detail?: string): PlugsightError {
    const msg = detail ? `${detail} ${DAEMON_UNREACHABLE_FIX}.` : `${DAEMON_UNREACHABLE_FIX}.`;
    return new PlugsightError("daemon_unreachable", msg);
  }

  /** The daemon advertised an apiVersion this build does not know. */
  static unsupportedApiVersion(version: number, known: readonly number[]): PlugsightError {
    return new PlugsightError(
      "unsupported_api_version",
      `The Plugsight daemon speaks apiVersion ${version}, which this MCP server does not know ` +
        `(it supports ${known.join(", ")}). Update @plugsight/mcp to match the app.`,
    );
  }

  /** Rebuild an error from a JSON-RPC error object the daemon sent, keeping its
   * human message and its stable `data.kind`. */
  static fromRpcError(err: { message?: string; data?: unknown }): PlugsightError {
    const data = (err.data && typeof err.data === "object" ? { ...(err.data as Record<string, unknown>) } : {}) as Record<string, unknown>;
    const rawKind = data.kind;
    // A missing or unrecognized kind must NOT become a meaningful branch like
    // `conflict` (agents act on that). Fall back to the neutral `unknown`.
    const kind: ErrorKind =
      typeof rawKind === "string" && KNOWN_ERROR_KINDS.has(rawKind) ? (rawKind as ErrorKind) : "unknown";
    delete data.kind;
    return new PlugsightError(kind, err.message ?? "The daemon returned an error.", data);
  }
}

/** The MCP tool-result shape for a structured error: a plain-text rendering
 * plus machine-readable structured content, flagged isError so agents branch on
 * it. */
export function toToolError(err: PlugsightError): {
  content: { type: "text"; text: string }[];
  structuredContent: { error: { kind: ErrorKind; message: string; data: Record<string, unknown> } };
  isError: true;
} {
  return {
    content: [{ type: "text", text: `Error [${err.kind}]: ${err.message}` }],
    structuredContent: { error: { kind: err.kind, message: err.message, data: err.data } },
    isError: true,
  };
}
