"""Phase 4: build a synthetic PNG with an embedded prompt+workflow for the regen test.

The workflow has a muted KSampler (id 10, title !yara_unmute) and a LoadImage
node (id 11, title !yara_load_here). The embedded API prompt is the 'original'
one (KSampler muted/bypassed).
"""
import json

from helpers import make_png, nonce

# unique per run so the regen prompt never hits ComfyUI's prompt cache
POS_TEXT = f"a red cube on a table (run {nonce()})"

API_PROMPT = {
    "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "v1-5-pruned.ckpt"}},
    "2": {"class_type": "CLIPTextEncode", "inputs": {"text": POS_TEXT, "clip": ["1", 1]}},
    "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "", "clip": ["1", 1]}},
    "4": {"class_type": "EmptyLatentImage", "inputs": {"width": 64, "height": 64, "batch_size": 1}},
    "7": {"class_type": "VAEDecode", "inputs": {"samples": ["4", 0], "vae": ["1", 2]}},
    "8": {"class_type": "SaveImage", "inputs": {"images": ["7", 0], "filename_prefix": "regen-test"}},
    "11": {"class_type": "LoadImage", "inputs": {"image": "yara-test_00001_.png"}},
    "12": {"class_type": "SaveImage", "inputs": {"images": ["11", 0], "filename_prefix": "regen-load"}},
}

WORKFLOW = {
    "id": "wf-regen-test",
    "revision": 0,
    "last_node_id": 12,
    "last_link_id": 10,
    "nodes": [
        {
            "id": 1, "type": "CheckpointLoaderSimple", "mode": 0,
            "pos": [0, 0], "size": {"0": 320, "1": 120}, "order": 0,
            "inputs": [],
            "outputs": [
                {"name": "MODEL", "type": "MODEL", "links": [1], "slot_index": 0},
                {"name": "CLIP", "type": "CLIP", "links": [2, 3], "slot_index": 1},
                {"name": "VAE", "type": "VAE", "links": [8], "slot_index": 2},
            ],
            "widgets_values": ["v1-5-pruned.ckpt"],
        },
        {
            "id": 2, "type": "CLIPTextEncode", "mode": 0,
            "pos": [350, 0], "size": {"0": 320, "1": 100}, "order": 1,
            "inputs": [{"name": "clip", "type": "CLIP", "link": 2}],
            "outputs": [{"name": "CONDITIONING", "type": "CONDITIONING", "links": [4], "slot_index": 0}],
            "widgets_values": [POS_TEXT],
        },
        {
            "id": 3, "type": "CLIPTextEncode", "mode": 0,
            "pos": [350, 150], "size": {"0": 320, "1": 100}, "order": 2,
            "inputs": [{"name": "clip", "type": "CLIP", "link": 3}],
            "outputs": [{"name": "CONDITIONING", "type": "CONDITIONING", "links": [5], "slot_index": 0}],
            "widgets_values": [""],
        },
        {
            "id": 4, "type": "EmptyLatentImage", "mode": 0,
            "pos": [350, 300], "size": {"0": 320, "1": 120}, "order": 3,
            "inputs": [],
            "outputs": [{"name": "LATENT", "type": "LATENT", "links": [6], "slot_index": 0}],
            "widgets_values": [64, 64, 1],
        },
        {
            "id": 10, "type": "KSampler", "mode": 2,
            "title": "!yara_unmute",
            "pos": [720, 0], "size": {"0": 320, "1": 240}, "order": 4,
            "inputs": [
                {"name": "model", "type": "MODEL", "link": 1},
                {"name": "positive", "type": "CONDITIONING", "link": 4},
                {"name": "negative", "type": "CONDITIONING", "link": 5},
                {"name": "latent_image", "type": "LATENT", "link": 6},
            ],
            "outputs": [{"name": "LATENT", "type": "LATENT", "links": [7], "slot_index": 0}],
            "widgets_values": [123, "randomize", 10, 7.0, "euler", "normal", 0.9],
        },
        {
            "id": 7, "type": "VAEDecode", "mode": 0,
            "pos": [1080, 0], "size": {"0": 220, "1": 60}, "order": 5,
            "inputs": [
                {"name": "samples", "type": "LATENT", "link": 7},
                {"name": "vae", "type": "VAE", "link": 8},
            ],
            "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [9], "slot_index": 0}],
            "widgets_values": [],
        },
        {
            "id": 8, "type": "SaveImage", "mode": 0,
            "pos": [1330, 0], "size": {"0": 320, "1": 280}, "order": 6,
            "inputs": [{"name": "images", "type": "IMAGE", "link": 9}],
            "outputs": [],
            "widgets_values": ["regen-test"],
        },
        {
            "id": 11, "type": "LoadImage", "mode": 0,
            "title": "!yara_load_here",
            "pos": [720, 300], "size": {"0": 320, "1": 314}, "order": 7,
            "inputs": [],
            "outputs": [
                {"name": "IMAGE", "type": "IMAGE", "links": [10], "slot_index": 0},
                {"name": "MASK", "type": "MASK", "links": [], "slot_index": 1},
            ],
            "widgets_values": ["yara-test_00001_.png", "image"],
        },
        {
            "id": 12, "type": "SaveImage", "mode": 0,
            "pos": [1080, 300], "size": {"0": 320, "1": 280}, "order": 8,
            "inputs": [{"name": "images", "type": "IMAGE", "link": 10}],
            "outputs": [],
            "widgets_values": ["regen-load"],
        },
    ],
    "links": [
        [1, 1, 0, 10, 0, "MODEL"],
        [2, 1, 1, 2, 0, "CLIP"],
        [3, 1, 1, 3, 0, "CLIP"],
        [4, 2, 0, 10, 1, "CONDITIONING"],
        [5, 3, 0, 10, 2, "CONDITIONING"],
        [6, 4, 0, 10, 3, "LATENT"],
        [7, 10, 0, 7, 0, "LATENT"],
        [8, 1, 2, 7, 1, "VAE"],
        [9, 7, 0, 8, 0, "IMAGE"],
        [10, 11, 0, 12, 0, "IMAGE"],
    ],
}

if __name__ == "__main__":
    import sys

    path = sys.argv[1] if len(sys.argv) > 1 else "test_regen.png"
    make_png(
        path,
        text_chunks=[
            ("prompt", json.dumps(API_PROMPT)),
            ("workflow", json.dumps(WORKFLOW)),
        ],
    )
    print(f"wrote {path}")
