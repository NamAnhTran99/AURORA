# AURORA

AURORA is a Windows PowerShell CLI for controlling a local Ollama server and publishing it through Tailscale Serve.

Defaults:

- Model: `gpt-oss:20b`
- Local Ollama API: `http://127.0.0.1:11434`
- Tailscale endpoint: configured at runtime through the `AURORA_ENDPOINT` environment variable
- Serve mapping: `tailscale serve --bg --yes --https=443 http://127.0.0.1:11434`

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
cmd\aurora start
cmd\aurora stop
cmd\aurora status
cmd\aurora run
cmd\aurora test
cmd\aurora context
```

## Notes

- `start` launches `ollama serve` when the API is not already reachable, pulls `gpt-oss:20b` if missing, and configures Tailscale Serve.
- `run` is an alias for `start`.
- `status` reads Ollama's `/api/ps` endpoint and shows actual loaded state, processor split, context size, and expiry.
- `test` sends a generation request locally and through the configured Tailscale URL. Use `-SkipRemote` to test only the local API.
- `stop` disables the HTTPS Serve mapping, unloads the model, verifies the unloaded state through `/api/ps`, and then stops local `ollama` processes.

You need both `ollama` and `tailscale` available on `PATH`.

Before using the remote test, configure the private endpoint in the current PowerShell session:

```powershell
$env:AURORA_ENDPOINT = "https://your-tailnet-hostname.ts.net/"
```
