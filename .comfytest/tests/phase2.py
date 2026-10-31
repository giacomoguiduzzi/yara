"""Phase 2: queue one KSampler prompt (real checkpoint) for examine/wait tests."""
from helpers import nonce, queue_prompt

prompt = {
    "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "v1-5-pruned.ckpt"}},
    # unique text per run: a deterministic graph would be served instantly
    # from ComfyUI's persisted prompt cache on re-runs, and the prompt would
    # leave the queue before `yara examine` can see it
    "2": {"class_type": "CLIPTextEncode", "inputs": {"text": f"a purple crystal (run {nonce()})", "clip": ["1", 1]}},
    "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "blurry", "clip": ["1", 1]}},
    "4": {"class_type": "EmptyLatentImage", "inputs": {"width": 256, "height": 256, "batch_size": 1}},
    "5": {"class_type": "KSampler", "inputs": {
        "model": ["1", 0], "seed": 42, "steps": 150, "cfg": 6.0,
        "sampler_name": "euler", "scheduler": "normal",
        "positive": ["2", 0], "negative": ["3", 0], "latent_image": ["4", 0], "denoise": 1.0}},
    "6": {"class_type": "VAEDecode", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
    "7": {"class_type": "SaveImage", "inputs": {"images": ["6", 0], "filename_prefix": "yara-t2"}},
}
workflow = {"id": "wf-t2", "nodes": [], "links": []}
print(queue_prompt(prompt, workflow))
