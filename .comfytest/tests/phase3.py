"""Phase 3: queue one slow and one fast KSampler prompt; print their queue numbers."""
import json

from helpers import get_queue, nonce, queue_prompt


def sampler_prompt(prefix, steps, size):
    return {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "v1-5-pruned.ckpt"}},
        "2": {"class_type": "CLIPTextEncode", "inputs": {"text": f"a green orb (run {nonce()})", "clip": ["1", 1]}},
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "", "clip": ["1", 1]}},
        "4": {"class_type": "EmptyLatentImage", "inputs": {"width": size, "height": size, "batch_size": 1}},
        "5": {"class_type": "KSampler", "inputs": {
            "model": ["1", 0], "seed": 7, "steps": steps, "cfg": 7.0,
            "sampler_name": "euler", "scheduler": "normal",
            "positive": ["2", 0], "negative": ["3", 0], "latent_image": ["4", 0], "denoise": 1.0}},
        "6": {"class_type": "VAEDecode", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
        "7": {"class_type": "SaveImage", "inputs": {"images": ["6", 0], "filename_prefix": prefix}},
    }

slow = queue_prompt(sampler_prompt("yara-t3-slow", 150, 512))
fast = queue_prompt(sampler_prompt("yara-t3-fast", 4, 64))
print("SLOW:", json.dumps(slow))
print("FAST:", json.dumps(fast))

q = get_queue()
for p in q.get("queue_pending", []) + q.get("queue_running", []):
    prefix = p[2]["7"]["inputs"]["filename_prefix"]
    print(f"queue-num={p[0]} id={p[1]} prefix={prefix}")
