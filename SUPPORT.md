# Support

Thanks for using Plugsight. Here is where to get help.

## Documentation

Start with the [README](README.md) and the specification in [`docs/spec/`](docs/spec/). The spec is the source of truth for what Plugsight does and, just as importantly, what it cannot do:

- [`docs/spec/00-overview.md`](docs/spec/00-overview.md) is the vision, scope, and the Honesty Charter.
- [`docs/spec/01-threat-model.md`](docs/spec/01-threat-model.md) is what Plugsight defends against and the macOS platform limits behind every design choice.
- [`docs/spec/03-mcp-interface.md`](docs/spec/03-mcp-interface.md) is the full agent-facing tool contract.

## Questions and ideas

For usage questions, setup help, and ideas, open an issue in [plugsightlabs/plugsight](https://github.com/plugsightlabs/plugsight/issues). Describe your macOS version, your hardware, and what you expected versus what you saw.

## Bugs and feature requests

Found a bug or want a feature? Open an issue with clear reproduction steps. A device that Plugsight scored or explained in a way you did not expect is especially useful to report, with the timeline entry or the score breakdown attached.

## Security issues

Do not open a public issue for a security vulnerability. See [SECURITY.md](SECURITY.md) for how to report privately through a GitHub security advisory.

## A note on scope

Plugsight is a detector, not a blocker. If you are asking whether it can stop a rogue keyboard before it types, see a dormant malicious cable, or scan a cable's firmware, the honest answer is no, and the threat model explains why. That is a design boundary, not a bug.

## Response time

Plugsight is maintained part-time by a small team. Please allow time for a response. Clear, focused, reproducible reports are handled fastest.
