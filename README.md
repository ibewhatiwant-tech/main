# MetaTrader 5 MCP Server

An MCP (Model Context Protocol) server that lets Claude (or any MCP client)
talk to a running MetaTrader 5 terminal: read account info, market data,
positions and history, and place/manage trades.

Vendored from [Qoyyuum/mcp-metatrader5-server](https://github.com/Qoyyuum/mcp-metatrader5-server)
(MIT licensed — see `LICENSE` and `NOTICE.md`).

## Requirements

- **Windows** — the `MetaTrader5` Python package only talks to a local MT5
  terminal via its Windows API, so this must run on the same Windows machine
  as your MT5 installation (not in a VM/container without MT5).
- **MetaTrader 5 terminal** installed, with a demo or real account.
- **Python 3.12+**
- **[uv](https://docs.astral.sh/uv/)** (recommended) or pip.

## Setup

1. Clone this repo onto the Windows machine that runs MT5, and install
   dependencies:

   ```powershell
   git clone <this-repo-url>
   cd main
   uv sync
   ```

2. Copy `.env.example` to `.env` and fill in your MT5 details:

   ```powershell
   copy .env.example .env
   ```

   ```env
   MT5_MCP_TRANSPORT=stdio
   MT5_PATH="C:\Program Files\MetaTrader 5\terminal64.exe"
   MT5_LOGIN=123456
   MT5_PASSWORD="your_password"
   MT5_SERVER="YourBroker-Demo"
   ```

   `MT5_PATH`/`MT5_LOGIN`/`MT5_PASSWORD`/`MT5_SERVER` are optional — you can
   instead pass them explicitly when calling the `initialize()`/`login()`
   tools from the AI assistant.

3. Sanity-check the server runs:

   ```powershell
   uv run mt5mcp
   ```

   It should sit waiting on stdio (Ctrl+C to stop). If `MetaTrader5` fails to
   import, make sure you're on Windows with the terminal installed.

## Connecting to Claude Desktop / Claude Code

Add this to your `claude_desktop_config.json` (Claude Desktop) or `.mcp.json`
(Claude Code), pointing `--directory` at where you cloned this repo:

```json
{
  "mcpServers": {
    "mcp-metatrader5-server": {
      "command": "uv",
      "args": [
        "--directory",
        "C:\\path\\to\\main",
        "run",
        "mt5mcp"
      ]
    }
  }
}
```

Restart Claude Desktop (or reload MCP servers in Claude Code) and the MT5
tools should show up.

## Basic workflow

1. `initialize()` — connect to the MT5 terminal.
2. `login(account, password, server)` — log in to your trading account.
3. `get_symbols()`, `copy_rates_from_pos(...)`, `get_symbol_info_tick(...)` —
   read market data.
4. `order_send(request)` — place a trade.
5. `positions_get()`, `history_orders_get()`, `history_deals_get()` — manage
   positions and review history.
6. `shutdown()` — close the connection when done.

See `docs/getting_started.md`, `docs/trading_guide.md`, and
`docs/market_data_guide.md` for detailed walkthroughs, and
`docs/api_reference.md` for the full tool list.

## Development

```powershell
uv sync --group dev
uv run pytest
```

Tests marked `integration` require a live MT5 connection; `unit` tests do not.

## Disclaimer

This software is provided as-is. Neither this repo nor the upstream project
is liable for any financial losses resulting from its use. Use a demo account
for testing.
