#!/usr/bin/env node
// ops/install-hooks.mjs — point git at the repo-tracked .githooks/ directory so the
// pre-push gate (.githooks/pre-push -> ops/gate.sh) is active. Idempotent; safe to
// re-run. Because core.hooksPath lives in the shared .git/config, one run covers the
// main checkout and every worktree.
//
// plugsight has no root package.json, so run it directly, once per clone:
//   node ops/install-hooks.mjs

import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const git = (...a) => execFileSync('git', a, { cwd: REPO, encoding: 'utf8' }).trim();

const hook = path.join(REPO, '.githooks', 'pre-push');
if (!existsSync(hook)) {
  console.error('✗ .githooks/pre-push not found — nothing to install.');
  process.exit(1);
}
try { chmodSync(hook, 0o755); } catch { /* best-effort on filesystems without exec bit */ }

const current = (() => { try { return git('config', '--local', 'core.hooksPath'); } catch { return ''; } })();
if (current === '.githooks') {
  console.log('✓ core.hooksPath already set to .githooks — pre-push gate active.');
} else {
  git('config', 'core.hooksPath', '.githooks');
  console.log(`✓ core.hooksPath set to .githooks (was: ${current || 'unset'}) — pre-push gate active.`);
}
console.log('  Guards pushes to develop/staging/main by running ops/gate.sh.');
console.log('  Bypass a non-code push with: git push --no-verify');
