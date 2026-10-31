import sys

sys.path.insert(0, ".")
from helpers import get_queue, nonce, queue_prompt


def slow_prompt(n):
    return {
        "1": {"class_type": "KSampler", "inputs": {"model": ["2", 0], "seed": 4000 + n, "steps": 200, "cfg": 5.0, "sampler_name": "euler", "scheduler": "normal", "positive": ["4", 0], "negative": ["5", 0], "latent_image": ["3", 0], "denoise": 1.0}},
        "2": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "v1-5-pruned.ckpt"}},
        "3": {"class_type": "EmptyLatentImage", "inputs": {"width": 256, "height": 256, "batch_size": 1}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": f"yara phase1 marker t1-{n} purple cube (run {nonce()})", "clip": ["2", 1]}},
        "5": {"class_type": "CLIPTextEncode", "inputs": {"text": "blurry", "clip": ["2", 1]}},
        "6": {"class_type": "VAEDecode", "inputs": {"samples": ["1", 0], "vae": ["2", 2]}},
        "7": {"class_type": "SaveImage", "inputs": {"filename_prefix": f"yara-t1-{n}", "images": ["6", 0]}},
    }


for i in (1, 2, 3):
    prompt = slow_prompt(i)
    wf = {
        "id": f"wf-t1-{i}",
        "nodes": [{"id": 7, "type": "SaveImage", "title": f"SaveImage t1-{i}"}],
        "extra_data": {},
    }
    r = queue_prompt(prompt, workflow=wf)
    print(f"queued {i}: {r}")
q = get_queue()
print("pending:", len(q["queue_pending"]), "running:", len(q["queue_running"]))
