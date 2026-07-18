## Provenance

The MCP server in `src/mcp_mt5/` is vendored from
[Qoyyuum/mcp-metatrader5-server](https://github.com/Qoyyuum/mcp-metatrader5-server)
(commit `a192732`, 2026-07-18), by Abdul Qoyyuum, and is distributed here under
the MIT License (see `LICENSE`) per that project's stated license (its
`README.md` and `pyproject.toml` both declare MIT, though the upstream repo
does not carry a standalone `LICENSE` file).

Local changes from upstream:
- Trimmed `pyproject.toml` (dropped docs/build tooling extras not used here).
- Removed generated files (`.coverage`, `uv.lock`) — regenerate locally with `uv sync`.
