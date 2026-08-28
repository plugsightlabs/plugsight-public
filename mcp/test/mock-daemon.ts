// A small, reusable mock of plugsightd's local API for the MCP tests.
//
// It speaks the exact wire protocol the real daemon does (docs/spec/02): a Unix
// domain socket, newline-framed JSON-RPC 2.0, `auth.hello` as the mandatory
// first message returning { apiVersion, daemonVersion, capabilities }, then one
// canned result per method. It can also: refuse to be reachable, advertise a
// stale apiVersion, inject a per-method error, and push an `event.appended`
// notification (for the tail_events test).

import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { CANNED, CANNED_EVENT_APPENDED } from "./canned.ts";

export interface CannedError {
  code: number;
  message: string;
  kind: string;
  data?: Record<string, unknown>;
}

export interface MockOptions {
  /** apiVersion advertised by auth.hello (default 1 — the version N9 knows). */
  apiVersion?: number;
  daemonVersion?: string;
  capabilities?: { inputMonitoring: boolean; endpointSecurity: boolean; clamav: boolean };
  /** Per-method result overrides (merged over the canned defaults). */
  results?: Record<string, unknown>;
  /** Per-method error injections; take priority over results. */
  errors?: Record<string, CannedError>;
}

export class MockDaemon {
  readonly baseDir: string;
  readonly socketPath: string;
  readonly token: string;
  /** Every post-auth request the daemon received, in order (method + params).
   * Tests assert against this, e.g. that tail_events released its subscription
   * with events.untail. */
  readonly calls: { method: string; params: unknown }[] = [];
  private server: net.Server | null = null;
  private readonly opts: Required<Pick<MockOptions, "apiVersion" | "daemonVersion" | "capabilities">> &
    Pick<MockOptions, "results" | "errors">;
  private sockets = new Set<net.Socket>();

  constructor(opts: MockOptions = {}) {
    this.baseDir = fs.mkdtempSync(path.join(os.tmpdir(), "plugsight-mock-"));
    this.socketPath = path.join(this.baseDir, "plugsightd.sock");
    this.token = "test-token-" + Math.random().toString(36).slice(2);
    fs.writeFileSync(path.join(this.baseDir, "api-token"), this.token, { mode: 0o600 });
    this.opts = {
      apiVersion: opts.apiVersion ?? 1,
      daemonVersion: opts.daemonVersion ?? "1.0.0",
      capabilities:
        opts.capabilities ?? { inputMonitoring: false, endpointSecurity: false, clamav: true },
      results: opts.results,
      errors: opts.errors,
    };
  }

  /** Start listening. Resolves once the socket is accepting connections. */
  start(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.server = net.createServer((sock) => this.onConnection(sock));
      this.server.on("error", reject);
      this.server.listen(this.socketPath, () => resolve());
    });
  }

  /** Stop listening and drop every connection. */
  stop(): Promise<void> {
    for (const s of this.sockets) s.destroy();
    this.sockets.clear();
    return new Promise((resolve) => {
      if (!this.server) return resolve();
      this.server.close(() => resolve());
      this.server = null;
    });
  }

  /** Push an `event.appended` notification to every open connection. */
  pushEvent(event: Record<string, unknown> = CANNED_EVENT_APPENDED): void {
    const line = JSON.stringify({ jsonrpc: "2.0", method: "event.appended", params: event }) + "\n";
    for (const s of this.sockets) s.write(line);
  }

  /**
   * Create a base dir that has a token but NO listening socket, so a client that
   * points here gets a connection failure (ENOENT / ECONNREFUSED) — the
   * daemon-unreachable path. Returns the base dir; nothing to stop.
   */
  static unreachableBaseDir(): string {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "plugsight-unreach-"));
    fs.writeFileSync(path.join(dir, "api-token"), "irrelevant", { mode: 0o600 });
    return dir;
  }

  private onConnection(sock: net.Socket): void {
    this.sockets.add(sock);
    sock.setEncoding("utf8");
    let authed = false;
    let buffer = "";
    sock.on("close", () => this.sockets.delete(sock));
    sock.on("error", () => this.sockets.delete(sock));
    sock.on("data", (chunk: string) => {
      buffer += chunk;
      let nl: number;
      while ((nl = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, nl);
        buffer = buffer.slice(nl + 1);
        if (!line.trim()) continue;
        let req: { id?: unknown; method?: string; params?: unknown };
        try {
          req = JSON.parse(line);
        } catch {
          continue;
        }
        const id = req.id ?? null;
        const method = req.method ?? "";

        if (!authed) {
          if (method !== "auth.hello") {
            this.sendError(sock, id, {
              code: -32001,
              message: "Unauthorized. The first message on a connection must be auth.hello.",
              kind: "unauthorized",
            });
            sock.destroy();
            return;
          }
          const token = (req.params as { token?: string } | undefined)?.token;
          if (token !== this.token) {
            this.sendError(sock, id, {
              code: -32001,
              message: "Unauthorized: the API token did not match.",
              kind: "unauthorized",
            });
            sock.destroy();
            return;
          }
          authed = true;
          this.sendResult(sock, id, {
            apiVersion: this.opts.apiVersion,
            daemonVersion: this.opts.daemonVersion,
            capabilities: this.opts.capabilities,
          });
          continue;
        }

        this.calls.push({ method, params: req.params });
        const err = this.opts.errors?.[method];
        if (err) {
          this.sendError(sock, id, err);
          continue;
        }
        const result = this.opts.results?.[method] ?? CANNED[method];
        if (result === undefined) {
          this.sendError(sock, id, {
            code: -32601,
            message: `Method '${method}' is not implemented.`,
            kind: "invalid_params",
          });
          continue;
        }
        this.sendResult(sock, id, result);
      }
    });
  }

  private sendResult(sock: net.Socket, id: unknown, result: unknown): void {
    sock.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
  }

  private sendError(sock: net.Socket, id: unknown, err: CannedError): void {
    const data: Record<string, unknown> = { ...(err.data ?? {}), kind: err.kind };
    sock.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: err.code, message: err.message, data } }) + "\n");
  }
}
