#!/bin/bash
# End-to-end test suite for yara against a live ComfyUI container.
# The container must already be running and reachable at COMFY_BASE.
#
# Environment overrides (all optional):
#   YARA_BIN      path to the yara binary                      (default: <repo>/target/debug/yara)
#   COMFY_DIR     ComfyUI data dir: output/input/models/...    (default: <repo>/.comfytest)
#   YARA_DATA_DIR yara appdata dir: config, saved queues       (default: $HOME/yara)
#   COMFY_HOST / COMFY_PORT                                    (defaults: 127.0.0.1 / 8188)
#   COMFY_BASE    full URL, defaults to http://$COMFY_HOST:$COMFY_PORT
#   SUITE_SLOW=1  widen wait/timeout budgets for CPU runners
set -u
cd "$(dirname "$0")"

REPO=$(cd ../.. && pwd)
YARA=${YARA_BIN:-$REPO/target/debug/yara}
COMFY=${COMFY_DIR:-$REPO/.comfytest}
OUT=$COMFY/output
YARADIR=${YARA_DATA_DIR:-$HOME/yara}
COMFY_HOST=${COMFY_HOST:-127.0.0.1}
COMFY_PORT=${COMFY_PORT:-8188}
COMFY_BASE=${COMFY_BASE:-http://$COMFY_HOST:$COMFY_PORT}
export COMFY_BASE
PY=python3

# CPU runners are tens of times slower than a GPU; scale the time budgets
if [ "${SUITE_SLOW:-0}" = "1" ]; then
    DRAIN=900; LOADTO=1800; WAITTO=900; REGENTO=1800
else
    DRAIN=300; LOADTO=300; WAITTO=300; REGENTO=600
fi

mkdir -p "$YARADIR" "$YARADIR/saved_queues" "$OUT" "$COMFY/input"
cat > "$YARADIR/config.json" <<EOF
{
  "melatonin_sleep_mode_timer": 30,
  "comfyui_output_directory": "$OUT",
  "comfyui_input_directory": "$COMFY/input",
  "regen_directory": "$OUT/regen",
  "workflow_recovery_directories": ["$OUT"],
  "comfyui_port": "$COMFY_PORT",
  "comfyui_address": "$COMFY_HOST",
  "default_window_position": [0, 0],
  "default_window_size": [750, 750],
  "base_image": null,
  "window_decorations": false,
  "mouse_passthrough": true,
  "always_on_top": true,
  "framerate_cap": 6
}
EOF
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { # check <desc> <command...>
    local desc="$1"; shift
    if "$@" > /tmp/yara_check.log 2>&1; then ok "$desc"; else bad "$desc (see /tmp/yara_check.log)"; sed -n '1,15p' /tmp/yara_check.log | sed 's/^/    /'; fi
}

wait_queue_empty() { # wait_queue_empty <max_seconds>
    for _ in $(seq 1 "$1"); do
        N=$($PY -c "from helpers import get_queue; q = get_queue(); print(len(q.get('queue_pending', [])) + len(q.get('queue_running', [])))")
        [ "$N" = "0" ] && return 0
        sleep 1
    done
    return 1
}

echo "=== phase 0: cleanup ==="
$PY -c "from helpers import clear_queue; clear_queue()"
$PY -c "
import json
from helpers import http_json
# clear history so re-runs stay idempotent
import urllib.request
with urllib.request.urlopen('$COMFY_BASE/history') as r:
    hist = json.loads(r.read().decode())
ids = list(hist.keys())
if ids:
    http_json('POST', '/history', {'delete': ids})
print('history cleared:', len(ids))
"
rm -f "$OUT"/*.png
rm -f "$COMFY"/input/*.png
rm -f "$COMFY"/tests/test_regen.png "$COMFY"/tests/fixme.png
echo '{"workflows": {}}' > "$YARADIR/workflow_storage.json"
rm -f "$YARADIR"/saved_queues/*.json

echo "=== phase 1: save / examine / cancel / load round trip ==="
$PY phase1.py
sleep 2
EXAM=$($YARA examine 2>&1)
echo "$EXAM" | grep -q "v1-5-pruned" && ok "examine shows model name" || bad "examine shows model name: $EXAM"
echo "$EXAM" | grep -q "yara phase1 marker" && ok "examine shows positive prompt" || bad "examine shows positive prompt: $EXAM"

check "save -wr t1 (running + pending)" $YARA save -wr t1
if [ -f "$YARADIR/saved_queues/t1.json" ]; then ok "saved queue file exists"; else bad "saved queue file missing"; fi
$PY - "$YARADIR/saved_queues/t1.json" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
assert len(data) == 3, f"expected 3 prompts, got {len(data)}"
for i, p in enumerate(data, 1):
    assert p["workflow"]["id"] == f"wf-t1-{i}", p["workflow"]
    assert p["prompt"]["prompt"]["7"]["inputs"]["filename_prefix"] == f"yara-t1-{i}"
print("saved queue contents verified")
EOF
[ $? -eq 0 ] && ok "saved queue contents" || bad "saved queue contents"

if $YARA list | grep -q t1; then ok "list shows t1"; else bad "list shows t1"; fi

# wait for the first three prompts to finish, then queue fresh ones and cancel
if wait_queue_empty $DRAIN; then ok "queue drained after phase 1 batch 1"; else bad "queue drained after phase 1 batch 1"; fi
$PY phase1.py > /dev/null
sleep 1
NUMS=$($PY - <<'EOF'
from helpers import get_queue
q = get_queue()
print(" ".join(str(p[0]) for p in q.get("queue_pending", [])))
EOF
)
echo "pending numbers: $NUMS"
NCOUNT=$(echo $NUMS | wc -w)
if [ "$NCOUNT" -lt 1 ]; then bad "cancel setup (no pending prompts to cancel)"; NCOUNT=1; fi
FIRST=$(echo $NUMS | awk '{print $1}')
REST=$(echo $NUMS | awk '{for(i=2;i<=NF;i++) printf "%s ", $i}')
check "cancel one pending" $YARA cancel $FIRST
LEFT=$($PY -c "from helpers import get_queue; print(len(get_queue().get('queue_pending', [])))")
EXPECTED=$((NCOUNT - 1))
[ "$LEFT" = "$EXPECTED" ] && ok "one prompt removed from queue" || bad "expected $EXPECTED pending, got $LEFT"
check "cancel remaining pending" $YARA cancel $REST
LEFT=$($PY -c "from helpers import get_queue; print(len(get_queue().get('queue_pending', [])))")
[ "$LEFT" = "0" ] && ok "queue emptied by cancel" || bad "expected 0 pending, got $LEFT"

check "load t1 (generates + embeds)" timeout $LOADTO $YARA load t1
check "wait after load" timeout $WAITTO $YARA wait
$PY - <<EOF
import glob, json, sys
from helpers import read_text_chunks
for i in (1, 2, 3):
    pattern = "$OUT/yara-t1-" + str(i) + "_*.png"
    files = sorted(glob.glob(pattern))
    assert files, f"no images for yara-t1-{i}"
    path = files[-1]
    chunks = read_text_chunks(path)
    assert "prompt" in chunks, f"{path}: no prompt chunk"
    assert "workflow" in chunks, f"{path}: no workflow chunk"
    wf = json.loads(chunks["workflow"])
    assert wf["id"] == "wf-t1-" + str(i), f"{path}: wrong workflow {wf.get('id')}"
    print(f"verified {path}")
EOF
[ $? -eq 0 ] && ok "yara-embedded workflows in loaded images" || bad "yara-embedded workflows in loaded images"

check "delete t1" $YARA delete t1
[ ! -f "$YARADIR/saved_queues/t1.json" ] && ok "saved queue file removed" || bad "saved queue file removed"

echo "=== phase 2: examine KSampler prompt + wait ==="
$PY phase2.py
sleep 1
EXAM=$($YARA examine 2>&1)
echo "$EXAM" | grep -q "v1-5-pruned" && ok "examine shows model name" || bad "examine shows model name: $EXAM"
echo "$EXAM" | grep -q "a purple crystal" && ok "examine shows positive prompt" || bad "examine shows positive prompt: $EXAM"
check "wait completes" timeout $WAITTO $YARA wait
ls "$OUT"/yara-t2_*.png >/dev/null 2>&1 && ok "KSampler image generated" || bad "KSampler image generated"

echo "=== phase 3: targeted interrupt ==="
$PY phase3.py > /tmp/phase3.log 2>&1
cat /tmp/phase3.log
SLOWNUM=$(grep 'prefix=yara-t3-slow' /tmp/phase3.log | grep -oP 'queue-num=\K[0-9]+')
SLOWRUNNING=0
for _ in $(seq 1 90); do
    if $PY -c "
from helpers import get_queue
q = get_queue()
running = [p for p in q.get('queue_running', []) if p[2].get('7', {}).get('inputs', {}).get('filename_prefix') == 'yara-t3-slow']
exit(0 if running else 1)
" 2>/dev/null; then SLOWRUNNING=1; break; fi
    sleep 2
done
[ "$SLOWRUNNING" = "1" ] && ok "slow prompt reached running state" || bad "slow prompt reached running state"
if [ -n "${SLOWNUM:-}" ]; then
    check "cancel running prompt (targeted interrupt)" timeout 60 $YARA cancel $SLOWNUM
    sleep 15
    $PY - <<EOF
import json, urllib.request

def get(url):
    with urllib.request.urlopen(url) as r:
        return json.loads(r.read().decode())

def prefix(h):
    try:
        return h["prompt"][2].get("7", {}).get("inputs", {}).get("filename_prefix", "")
    except (KeyError, TypeError):
        return ""

hist = get("$COMFY_BASE/history")
slow = [h for h in hist.values() if prefix(h) == "yara-t3-slow"]
fast = [h for h in hist.values() if prefix(h) == "yara-t3-fast"]
assert len(slow) == 1, f"expected 1 slow prompt in history, got {len(slow)}"
assert len(fast) == 1, f"expected 1 fast prompt in history, got {len(fast)}"
print("slow prompt status:", slow[0]["status"]["status_str"])
print("fast prompt status:", fast[0]["status"]["status_str"])
assert slow[0]["status"]["status_str"] == "error", "interrupted prompt should be error"
assert fast[0]["status"]["status_str"] == "success", "other prompt should succeed"
print("interrupt isolation verified")
EOF
    [ $? -eq 0 ] && ok "interrupted prompt errored, other prompt finished" || bad "interrupt isolation"
else
    bad "could not determine slow prompt queue number"
fi

echo "=== phase 4: regen ==="
$PY - <<EOF
import sys
sys.path.insert(0, '.')
from helpers import make_png
make_png("$COMFY/input/yara-test_00001_.png")
print("input image created")
EOF
$PY phase4.py "$COMFY/tests/test_regen.png"
check "regen source png" timeout $REGENTO $YARA regen "$COMFY/tests/test_regen.png"
check "wait after regen" timeout $WAITTO $YARA wait
$PY - <<EOF
import glob, json, os, sys
from helpers import read_text_chunks
for prefix in ("regen-test", "regen-load"):
    files = sorted(glob.glob("$OUT/" + prefix + "_*.png"))
    assert files, f"no {prefix} images"
    path = files[-1]
    chunks = read_text_chunks(path)
    prompt = json.loads(chunks["prompt"])
    assert "workflow" in chunks, f"{path}: no workflow chunk"
    print(f"verified {path}")
path = sorted(glob.glob("$OUT/regen-test_*.png"))[-1]
chunks = read_text_chunks(path)
prompt = json.loads(chunks["prompt"])
wf = json.loads(chunks["workflow"])
assert prompt["10"]["class_type"] == "KSampler", "KSampler node not added"
assert prompt["10"]["inputs"]["seed"] == 123
assert prompt["10"]["inputs"]["sampler_name"] == "euler"
assert prompt["7"]["inputs"]["samples"] == ["10", 0], "VAEDecode not rewired"
assert prompt["11"]["class_type"] == "LoadImage"
assert prompt["11"]["inputs"]["image"].startswith("_test_regen"), prompt["11"]
nodes = {n["id"]: n for n in wf["nodes"]}
assert nodes[10]["mode"] == 0, "KSampler not unmuted in workflow"
assert nodes[11]["type"] == "LoadImage" and nodes[11]["widgets_values"][0].startswith("_test_regen"), "LoadImage not replaced in workflow"
assert os.path.exists("$COMFY/input/" + prompt["11"]["inputs"]["image"]), "source image not copied to input dir"
print("regen verified:", path)
EOF
[ $? -eq 0 ] && ok "regen: unmuted KSampler + LoadImage replacement + workflow embedded" || bad "regen verification"
ls "$OUT"/regen-load_*.png >/dev/null 2>&1 && ok "regen-load (LoadImage) image generated" || bad "regen-load image generated"

echo "=== phase 5: fix ==="
$PY phase5.py "$COMFY/tests/fixme.png" > /tmp/phase5.log 2>&1
cat /tmp/phase5.log
sleep 1
check "save -wr fixq (running included)" $YARA save -wr fixq
HASH=$($PY -c "import json; d=json.load(open('$YARADIR/saved_queues/fixq.json')); print(d[0]['hash'])")
[ -n "$HASH" ] && ok "hash extracted from saved queue: $HASH" || bad "hash extraction"
$YARA delete fixq > /dev/null
$PY - "$HASH" <<EOF
import json, sys
sys.path.insert(0, '.')
from phase5 import W5
h = sys.argv[1]
storage = {"workflows": {h: W5}}
with open("$YARADIR/workflow_storage.json", "w") as f:
    json.dump(storage, f)
print("storage seeded")
EOF
[ $? -eq 0 ] && ok "fix fixtures prepared" || bad "fix fixtures prepared"
check "yara fix file" timeout 60 $YARA fix "$COMFY/tests/fixme.png"
$PY - <<EOF
import json, sys
sys.path.insert(0, '.')
from helpers import read_text_chunks
from phase5 import W5
chunks = read_text_chunks("$COMFY/tests/fixme.png")
assert "workflow" in chunks, "workflow not embedded by yara fix"
wf = json.loads(chunks["workflow"])
assert wf["id"] == W5["id"], wf.get("id")
print("yara fix verified")
EOF
[ $? -eq 0 ] && ok "yara fix embedded stored workflow" || bad "yara fix embedding"

echo "=== phase 6: image ==="
REGENFILE=$(ls -1 "$OUT"/regen-test_*.png 2>/dev/null | tail -1)
IMAGEOUT=$(printf '%s\nq\n' "$REGENFILE" | timeout 60 $YARA image 2>&1)
echo "$IMAGEOUT" | grep -q "a red cube on a table" && ok "image shows positive prompt" || bad "image shows positive prompt: $IMAGEOUT"
echo "$IMAGEOUT" | grep -q "v1-5-pruned" && ok "image shows model name" || bad "image shows model name: $IMAGEOUT"

echo "=== phase 7: sleep mode commands ==="
check "caffeine runs" $YARA caffeine
check "melatonin runs" $YARA melatonin

echo "=== phase 8: save -wr (running included) ==="
$PY - <<'EOF'
from helpers import queue_prompt
p = {
    "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "v1-5-pruned.ckpt"}},
    "2": {"class_type": "CLIPTextEncode", "inputs": {"text": "a blue sky", "clip": ["1", 1]}},
    "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "", "clip": ["1", 1]}},
    "4": {"class_type": "EmptyLatentImage", "inputs": {"width": 128, "height": 128, "batch_size": 1}},
    "5": {"class_type": "KSampler", "inputs": {
        "model": ["1", 0], "seed": 1, "steps": 100, "cfg": 7.0, "sampler_name": "euler",
        "scheduler": "normal", "positive": ["2", 0], "negative": ["3", 0],
        "latent_image": ["4", 0], "denoise": 1.0}},
    "6": {"class_type": "VAEDecode", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
    "7": {"class_type": "SaveImage", "inputs": {"images": ["6", 0], "filename_prefix": "yara-t8"}},
}
wf = {"id": "wf-t8", "nodes": [], "links": []}
print(queue_prompt(p, wf))
EOF
sleep 3
check "save -wr t8" $YARA save -wr t8
$PY - <<EOF
import json
data = json.load(open("$YARADIR/saved_queues/t8.json"))
prefixes = [p["prompt"]["prompt"]["7"]["inputs"]["filename_prefix"] for p in data]
assert "yara-t8" in prefixes, prefixes
print("t8 saved with running prompt included")
EOF
[ $? -eq 0 ] && ok "save -wr includes running prompt" || bad "save -wr includes running prompt"

echo
echo "======================================"
echo "RESULTS: $PASS passed, $FAIL failed"
echo "======================================"
[ "$FAIL" = "0" ]
