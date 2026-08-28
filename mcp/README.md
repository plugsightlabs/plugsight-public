# @plugsight/mcp

The agent-facing peer of the Plugsight menu-bar app. Plugsight is a
macOS-native, agent-first USB security monitor: it watches every device you plug
in, scores the ones that behave like an attack, scans mounted storage, and
writes it all into one plain-language timeline. It is a detector, not a blocker.

This package is a deliberately thin stdio MCP adapter. It holds no logic of its
own: every tool forwards over a local Unix-domain-socket JSON-RPC connection to
the Plugsight daemon (`plugsightd`) running on the same Mac. Every capability the
menu-bar app has is a tool here, so an agent and a person operate the exact same
surface.

## Requirements

- macOS with the **Plugsight daemon (`plugsightd`) installed and running**. The
  MCP server is a client of that daemon; with no daemon on the socket its tools
  return a connection error. See the project README for installing and running
  the daemon.
- Node.js >= 18.

## Usage

Run it over stdio (for example from an MCP client config):

```sh
npx @plugsight/mcp
```

Call `get_status` first: it reports the daemon's health, permissions, scanner
state, and counts, so you know what the rest of the tools are working against.
Read-only tools (`list_devices`, `get_timeline`, `score_device`, ...) observe;
mutating tools (`trust_device`, `scan_storage`, `set_policy`, ...) are attributed
to you in the human's timeline. The behavioral score is probabilistic and a
patient attacker can evade it; Plugsight scores and explains, it does not block,
prevent, or guarantee.

## Tools

The full, drift-gate-checked capability table (every tool, what it does, whether
it writes) lives in the project README:
<https://github.com/plugsightlabs/plugsight-public#capabilities>, and the product
homepage is <https://plugsight.com>.

## License

MIT.
