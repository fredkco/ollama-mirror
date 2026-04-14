# ollama-mirror

Build an HTTP-served offline mirror for Ollama models.

`ollama-fetch.sh` reads model references from a list, pulls models with `ollama`, exports blob files and rewritten `Modelfile`s, and generates a small repository (`manifest.tsv`, `manifest.json`, `index.html`, `ollama-offline.sh`) that can be hosted on any web server.

This project assumes Ollama is installed via Snap (`snap install ollama`) on the target host.

Search keywords: `ollama-offline`, `ollama offline`, `offline ollama repository`.

## Compatibility

Tested on Ubuntu 22.04, 24.04, and 26.04 (beta).

## Requirements

- Linux with Bash
- `ollama` installed as a Snap package
- `awk`, `sed`, `grep`, `sort`, `tee`, `date`, `basename`, `realpath`, `stat`
- Enough disk space for model blobs

## Quick Start

```bash
git clone https://github.com/fredkco/ollama-mirror.git
cd ollama-mirror
chmod +x ollama-fetch.sh
./ollama-fetch.sh models.list ./ollama-offline
```

## Input List Format (`models.list`)

```text
llama3.2
llama3.2:latest
qwen2.5-coder:7b
myuser/mymodel:latest
# comments are ignored
```

If no tag is provided, `:latest` is assumed.

## Generated Output

By default, output is written to `./ollama-offline`:

- `blobs/`
- `models/*.Modelfile`
- `manifest.tsv`
- `manifest.json`
- `index.html`
- `repo-metadata.env`
- `ollama-offline.sh`

The fetch process is incremental and keeps state in `ollama-offline/.state/`.

## Host The Repository

From the project directory:

```bash
python3 -m http.server 8080
```

This makes the repo available at:

- `http://<server>:8080/ollama-offline`

## Install Models From The Mirror

On the target machine:

```bash
wget http://<server>:8080/ollama-offline/ollama-offline.sh
chmod +x ollama-offline.sh
export OLLAMA_REPO_URL="http://<server>:8080/ollama-offline"
./ollama-offline.sh list
./ollama-offline.sh install llama3.2
./ollama-offline.sh install-all
```

## Useful Environment Variables

- `OLLAMA_REPO_URL`: mirror base URL used by `ollama-offline.sh`
- `OLLAMA_CACHE_DIR`: local cache for downloaded manifest/model artifacts
- `SNAP_OLLAMA_MODELS_DIR`: override Snap models directory (default: `$HOME/snap/ollama/common/.ollama/models`)
- `CUSTOM_OLLAMA_MODELS_DIR`: custom models directory for non-snap Ollama installs

## Using a custom models directory

If your local Ollama install uses a non-snap models directory, pass `--models-location` when running `ollama-offline.sh`:

```bash
./ollama-offline.sh --models-location=/usr/share/ollama/.ollama/models install llama3.2
```

You can also set `OLLAMA_MODELS` in your environment if your Ollama runtime requires a custom models path.

## Publishing Notes

- Keep generated artifacts out of git unless you intentionally want to publish binaries.
- Verify each model's redistribution and license terms before sharing.
