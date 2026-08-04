# AURORA

AURORA is a Windows PowerShell CLI for controlling a local Ollama server and publishing it through Tailscale Serve.

Defaults:

- Model: `AURORA_MODEL` from `.env`, or `qwen3:14b` when unset
- Local Ollama API: `http://127.0.0.1:11434`
- Tailscale endpoint: configured at runtime through the `AURORA_ENDPOINT` environment variable
- Local proxy: `http://127.0.0.1:11435` forwards to Ollama at `http://127.0.0.1:11434`
- Serve mapping: `tailscale serve --https=443 http://127.0.0.1:11435` (foreground, non-persistent)

## Configuration

AURORA automatically loads a root-level `.env` file. Keep this file local; it is ignored by Git.

```env
AURORA_ENDPOINT=https://your-tailnet-hostname.ts.net/
AURORA_MODEL=qwen3:14b
AURORA_CONTEXT_LENGTH=32768
OLLAMA_MODELS=E:\Ollama\Models
OLLAMA_KEEP_ALIVE=-1
```

Set `AURORA_MODEL` to the Ollama model AURORA should pull and load. You can override it for one command with `-Model`.
`AURORA_CONTEXT_LENGTH` controls the context requested during model warm-up. The default is `32768`; you can override it with `-ContextLength`.

`OLLAMA_MODELS` controls where Ollama stores model files. `OLLAMA_KEEP_ALIVE=-1` keeps the loaded model resident until AURORA stops Ollama. The `.env` values take precedence over existing process environment variables when AURORA starts.

## Commands

```powershell
.\cmd\Aurora.ps1 start
.\cmd\Aurora.ps1 stop
.\cmd\Aurora.ps1 status
.\cmd\Aurora.ps1 run
.\cmd\Aurora.ps1 test
.\cmd\Aurora.ps1 context
```

Or use the Windows launcher:

```cmd
.\aurora.cmd start
.\aurora.cmd stop
.\aurora.cmd status
.\aurora.cmd run
.\aurora.cmd test
.\aurora.cmd context
```

Use `-Verbose` with a level from 0 to 2 when debugging startup or local Ollama traffic:

```powershell
.\aurora.cmd start -Verbose 1
```

Level 0 is silent, level 1 shows compact request and response metadata, and level 2 shows full request and response payload previews. Any level above 0 stays in the foreground until `Ctrl+C`; stopping it also shuts down AURORA services.

Verbose output is opt-in and does not include SearXNG orchestration; that will be added on the web-search branch.

To switch models, use the same model name for the lifecycle command:

```powershell
.\aurora.cmd stop -Model qwen3:14b
.\aurora.cmd start -Model qwen3:14b
```

To make another model the default, set `AURORA_MODEL=model:tag` in `.env`.

## Notes

- `start` launches `ollama serve` when the API is not already reachable, pulls the selected model if missing, loads it into VRAM, starts the local Host-header-fixing proxy, verifies the loaded state through `/api/ps`, and configures Tailscale Serve through that proxy.
- `run` is an alias for `start`, so it also warms the model before returning.
- Model warm-up can take several minutes when loading from disk into VRAM. Use `-NoPull` to prevent downloading a missing model.
- `status` reads Ollama's `/api/ps` endpoint and shows actual loaded state, processor split, context size, and expiry.
- `test` sends a generation request locally and through the configured Tailscale URL. Use `-SkipRemote` to test only the local API. If `AURORA_ENDPOINT` is unset, the remote test is skipped.
- `stop` disables the HTTPS Serve mapping, unloads the model, verifies the unloaded state through `/api/ps`, and then stops local `ollama` processes.
- Ollama remains bound to the loopback address; the proxy is also loopback-only and is the only local target published through Tailscale Serve.
- Tailscale Serve is intentionally non-persistent. It does not resume after a reboot; run `start` again when the PC comes back online.
- AURORA does not create a Windows startup task. Tailscale itself may still run as a Windows service, independently of Serve.

You need both `ollama` and `tailscale` available on `PATH`.

You can also configure the private endpoint for the current PowerShell session without editing `.env`:

```powershell
$env:AURORA_ENDPOINT = "https://your-tailnet-hostname.ts.net/"
```
