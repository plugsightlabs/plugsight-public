// The socket client: the MCP server's only stateful possession.
//
// It speaks the daemon's local API (docs/spec/02): a Unix domain socket,
// newline-framed JSON-RPC 2.0, `auth.hello` as the mandatory first message. It
// connects lazily and reconnects on demand, so a call made while the daemon is
// down returns a structured daemon_unreachable rather than hanging. It also
// fans `event.appended` notifications out to registered listeners (tail_events).

import net from "node:net";
import { resolveSocketConfig } from "./config.ts";
import { PlugsightError } from "./errors.ts";

/** apiVersions this build understands. The daemon's `auth.hello` is checked
 * against this set; anything else is refused (docs/spec/02). */
export const KNOWN_API_VERSIONS: readonly number[] = [1];

export interface Capabilities {
  inputMonitoring: boolean;
  endpointSecurity: boolean;
  clamav: boolean;
}

export interface HelloResult {
  apiVersion: number;
  daemonVersion: string;
  capabilities: Capabilities;
}

export interface ClientInfo {
  name: string;
  kind: string;
}

export interface ClientOptions {
  /** Daemon state directory; defaults to the well-known location. */
  baseDir?: string;
  /** Reported to the daemon so mutations are attributed (e.g. "mcp:claude-code"). */
  clientInfo?: ClientInfo;
}

type EventHandler = (params: Record<string, unknown>) => void;
type Pending = { resolve: (v: unknown) => void; reject: (e: unknown) => void };

export class PlugsightClient {
  private readonly baseDir?: string;
  private readonly clientInfo: ClientInfo;
  private sock: net.Socket | null = null;
  private hello: HelloResult | null = null;
  private connecting: Promise<HelloResult> | null = null;
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private buffer = "";
  private readonly eventHandlers = new Set<EventHandler>();

  constructor(opts: ClientOptions = {}) {
    this.baseDir = opts.baseDir;
    this.clientInfo = opts.clientInfo ?? { name: "plugsight-mcp", kind: "mcp" };
  }

  /** Set the connecting agent's name so mutations are attributed to it in the
   * timeline (e.g. "mcp:claude-code"). Only takes effect before the first
   * connect, since the name is sent in auth.hello. */
  setClientName(name: string): void {
    if (!this.hello && name) this.clientInfo.name = name;
  }

  /** Ensure the socket is open and authenticated; returns the version picture.
   * Idempotent and safe to call before every request. */
  connect(): Promise<HelloResult> {
    if (this.hello) return Promise.resolve(this.hello);
    if (this.connecting) return this.connecting;
    this.connecting = this.doConnect().finally(() => {
      this.connecting = null;
    });
    return this.connecting;
  }

  /** Call an API method, connecting first if needed. Rejects with a
   * PlugsightError carrying the daemon's `kind` and human message. */
  async call<T = unknown>(method: string, params: unknown = {}): Promise<T> {
    await this.connect();
    return (await this.send(method, params)) as T;
  }

  /** Register a listener for `event.appended` notifications. Returns an
   * unsubscribe function. */
  onEvent(handler: EventHandler): () => void {
    this.eventHandlers.add(handler);
    return () => this.eventHandlers.delete(handler);
  }

  /** The negotiated version picture, or null before the first connect. */
  get helloResult(): HelloResult | null {
    return this.hello;
  }

  /** Close the connection and reject anything in flight. */
  close(): void {
    this.teardown(PlugsightError.daemonUnreachable("The Plugsight connection was closed."));
  }

  // MARK: - internals

  private doConnect(): Promise<HelloResult> {
    const cfg = resolveSocketConfig(this.baseDir); // throws daemon_unreachable if unset up
    return new Promise<HelloResult>((resolve, reject) => {
      const sock = net.createConnection(cfg.socketPath);
      sock.setEncoding("utf8");
      const onConnectError = () =>
        reject(
          PlugsightError.daemonUnreachable(
            `Could not connect to the Plugsight daemon socket at ${cfg.socketPath}.`,
          ),
        );
      sock.once("error", onConnectError);
      sock.once("connect", () => {
        sock.removeListener("error", onConnectError);
        // Later socket errors surface as a 'close' that rejects pending calls.
        sock.on("error", () => {});
        sock.on("data", (c: string) => this.onData(c));
        sock.on("close", () => this.onClose());
        this.sock = sock;
        this.send("auth.hello", { token: cfg.token, clientInfo: this.clientInfo })
          .then((res) => {
            const hello = res as HelloResult;
            if (!KNOWN_API_VERSIONS.includes(hello.apiVersion)) {
              this.teardown(PlugsightError.unsupportedApiVersion(hello.apiVersion, KNOWN_API_VERSIONS));
              reject(PlugsightError.unsupportedApiVersion(hello.apiVersion, KNOWN_API_VERSIONS));
              return;
            }
            this.hello = hello;
            resolve(hello);
          })
          .catch(reject);
      });
    });
  }

  private send(method: string, params: unknown): Promise<unknown> {
    return new Promise((resolve, reject) => {
      if (!this.sock || this.sock.destroyed) {
        reject(PlugsightError.daemonUnreachable("The Plugsight daemon connection is not open."));
        return;
      }
      const id = this.nextId++;
      this.pending.set(id, { resolve, reject });
      this.sock.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  }

  private onData(chunk: string): void {
    this.buffer += chunk;
    let nl: number;
    while ((nl = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, nl);
      this.buffer = this.buffer.slice(nl + 1);
      if (!line.trim()) continue;
      let msg: { id?: unknown; result?: unknown; error?: { message?: string; data?: unknown }; method?: string; params?: unknown };
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (msg.method === "event.appended" && msg.id === undefined) {
        const params = (msg.params ?? {}) as Record<string, unknown>;
        for (const h of [...this.eventHandlers]) h(params);
        continue;
      }
      const id = msg.id;
      if (typeof id === "number" && this.pending.has(id)) {
        const p = this.pending.get(id)!;
        this.pending.delete(id);
        if (msg.error) p.reject(PlugsightError.fromRpcError(msg.error));
        else p.resolve(msg.result);
      }
    }
  }

  private onClose(): void {
    // Unexpected drop: fail everything in flight and reset so the next call
    // reconnects from scratch.
    const err = PlugsightError.daemonUnreachable("The Plugsight daemon connection dropped.");
    for (const [, p] of this.pending) p.reject(err);
    this.pending.clear();
    this.sock = null;
    this.hello = null;
    this.buffer = "";
  }

  private teardown(err: PlugsightError): void {
    for (const [, p] of this.pending) p.reject(err);
    this.pending.clear();
    if (this.sock) {
      this.sock.destroy();
      this.sock = null;
    }
    this.hello = null;
    this.buffer = "";
  }
}
