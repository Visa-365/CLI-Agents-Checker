# CLI Agents Checker

PowerShell script that checks installed CLI AI agents on Windows: PATH presence, versions, timeouts, npm package inventory, and Ollama API metadata.

## Requirements

- Windows
- PowerShell 5.1+ (`#requires -Version 5.1`)

## Quick start

```powershell
.\Test-CliAgents.ps1
```

Reports are written to a folder named `cli-audit-YYYYMMDD-HHmmss/` (`report.csv`, `report.json`, and related files).

## Parameters

| Parameter | Description | Default |
|---|---|---|
| `-TimeoutSeconds` | CLI check timeout (3–120 sec) | `20` |
| `-OutputDirectory` | Report output directory | `cli-audit-<timestamp>` |
| `-AgentCommands` | Commands to check | `claude`, `codex`, `gemini`, `copilot`, `aider`, `opencode`, `agent`, `cursor-agent`, `ollama` |
| `-ProjectDirectory` | Project directory for npm inventory | empty |
| `-OllamaBaseUrl` | Ollama API URL | `http://localhost:11434` |
| `-OllamaApiTimeoutSeconds` | Ollama API timeout (1–60 sec) | `5` |

### Examples

```powershell
.\Test-CliAgents.ps1 -TimeoutSeconds 30
.\Test-CliAgents.ps1 -ProjectDirectory "C:\Projects\my-app"
.\Test-CliAgents.ps1 -AgentCommands claude,codex,ollama
.\Test-CliAgents.ps1 -OllamaBaseUrl "http://127.0.0.1:11434"
```

## What it checks

- CLI agents: claude, codex, gemini, copilot, aider, opencode, agent, cursor-agent, ollama
- npm packages (if `npm` is available)
- Ollama API and model list (if the server is reachable)

The script does **not** run model inference tests — only discovery/version checks and metadata.

## Output files

The report directory may contain:

- `report.csv` / `report.json` — CLI summary
- `npm-packages.csv` / `npm-inventory.json` — npm inventory
- `ollama-api.json` / `ollama-models.csv` — Ollama data

Local `cli-audit-*` folders and `*.pdf` files are ignored by git (see `.gitignore`).

## License

[MIT](LICENSE)
