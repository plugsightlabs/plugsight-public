// Zero-config discovery of the daemon's socket and token.
//
// The daemon writes both into its state directory (docs/spec/02):
//   ~/Library/Application Support/Plugsight/plugsightd.sock   (mode 0600)
//   ~/Library/Application Support/Plugsight/api-token         (mode 0600)
// The base directory is injectable so tests can point at a mock's dir.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { PlugsightError } from "./errors.ts";

export const SOCKET_FILENAME = "plugsightd.sock";
export const TOKEN_FILENAME = "api-token";

/** The default state directory the app and daemon share. */
export function defaultBaseDir(): string {
  return path.join(os.homedir(), "Library", "Application Support", "Plugsight");
}

export interface SocketConfig {
  socketPath: string;
  token: string;
}

/**
 * Resolve the socket path and token from a base directory. A missing token file
 * means the daemon has never set up its state directory — reported as
 * daemon_unreachable, not an opaque filesystem error.
 */
export function resolveSocketConfig(baseDir: string = defaultBaseDir()): SocketConfig {
  const socketPath = path.join(baseDir, SOCKET_FILENAME);
  const tokenPath = path.join(baseDir, TOKEN_FILENAME);
  let token: string;
  try {
    token = fs.readFileSync(tokenPath, "utf8").trim();
  } catch {
    throw PlugsightError.daemonUnreachable(
      `No Plugsight API token at ${tokenPath} — the daemon has not created its state directory.`,
    );
  }
  if (!token) {
    throw PlugsightError.daemonUnreachable(`The Plugsight API token at ${tokenPath} is empty.`);
  }
  return { socketPath, token };
}
