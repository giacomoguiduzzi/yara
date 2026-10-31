# Yara end-to-end tests

Live-container test suite for `yara` against a running ComfyUI server.
Runs in GitHub Actions against both `obeliks/comfyui:master-cu128` and
`obeliks/comfyui:master-cu130` (see `.github/workflows/comfy-tests.yml`),
in CPU mode.

## Requirements

- A ComfyUI container reachable at `http://127.0.0.1:8188` (override with
  `COMFY_HOST` / `COMFY_PORT` / `COMFY_BASE`) with these directories mounted
  from `$COMFY_DIR` (default: `<repo>/.comfytest`):

  | host dir                      | container dir    |
  |-------------------------------|------------------|
  | `$COMFY_DIR/output`           | `/app/output`    |
  | `$COMFY_DIR/input`            | `/app/input`     |
  | `$COMFY_DIR/user`             | `/app/user`      |
  | `$COMFY_DIR/models`           | `/app/models`    |
  | `$COMFY_DIR/custom_nodes`     | `/app/custom_nodes` |
  | `$COMFY_DIR/custom_venv`      | `/app/custom_venv`  |

- A stable diffusion checkpoint at
  `$COMFY_DIR/models/checkpoints/v1-5-pruned.ckpt` (SD1.5, ~4.3 GB).
  The CI downloads it from CivitAI; locally:

  ```sh
  curl -L -o .comfytest/models/checkpoints/v1-5-pruned.ckpt \
    https://civitai.com/api/download/models/4
  ```

- A `yara` binary (default: `target/debug/yara`, override with `YARA_BIN`).
- Python 3 (stdlib only).

## Running

```sh
# local, GPU container on the default port
bash .comfytest/tests/run_tests.sh

# CI-style (fresh yara data dir, slower budgets for CPU)
YARA_BIN=$PWD/target/release/yara YARA_DATA_DIR=/tmp/yara-ci \
  SUITE_SLOW=1 bash .comfytest/tests/run_tests.sh
```

The script writes its own yara `config.json` into `YARA_DATA_DIR`
(default `$HOME/yara`), clears queue/history, and exits non-zero if any
check fails.

## What it covers

| phase | coverage |
|-------|----------|
| 1     | `save`/`examine`/`cancel`/`load`/`delete` round trip, workflow embedding in generated images |
| 2     | `examine` of a real KSampler prompt, `wait` |
| 3     | targeted interrupt: cancelled prompt errors, other prompt still succeeds |
| 4     | `regen`: unmuted KSampler added, LoadImage replaced, workflow re-embedded |
| 5     | `fix`: stored workflow re-embedded into an image missing it |
| 6     | `image` prompt/model readout from embedded data |
| 7     | `caffeine`/`melatonin` (Linux stubs) |
| 8     | `save -wr` captures a running prompt |

Fixture prompts carry a per-run nonce so repeated runs never hit
ComfyUI's persisted prompt cache (which would complete them instantly and
race the queue assertions).
