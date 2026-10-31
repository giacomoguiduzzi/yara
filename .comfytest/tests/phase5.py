"""Phase 5: queue a long-running prompt M5 with a marker workflow W5 for the fix test."""
from helpers import make_png, nonce, queue_prompt

M5 = {
    "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "v1-5-pruned.ckpt"}},
    "2": {"class_type": "CLIPTextEncode", "inputs": {"text": f"a yellow triangle (run {nonce()})", "clip": ["1", 1]}},
    "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "", "clip": ["1", 1]}},
    "4": {"class_type": "EmptyLatentImage", "inputs": {"width": 128, "height": 128, "batch_size": 1}},
    "5": {"class_type": "KSampler", "inputs": {
        "model": ["1", 0], "seed": 99, "steps": 300, "cfg": 7.0,
        "sampler_name": "euler", "scheduler": "normal",
        "positive": ["2", 0], "negative": ["3", 0], "latent_image": ["4", 0], "denoise": 1.0}},
    "6": {"class_type": "VAEDecode", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
    "7": {"class_type": "SaveImage", "inputs": {"images": ["6", 0], "filename_prefix": "yara-t5"}},
}

W5 = {
    "id": "wf-fix-test",
    "nodes": [
        {"id": 1, "type": "CheckpointLoaderSimple", "mode": 0, "title": "node of wf-fix-test"},
        {"id": 7, "type": "SaveImage", "mode": 0},
    ],
    "links": [],
}

if __name__ == "__main__":
    import json
    import sys

    png_path = sys.argv[1]
    make_png(png_path, text_chunks=[("prompt", json.dumps(M5))])
    print(queue_prompt(M5, W5))
