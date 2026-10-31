import json
import os
import struct
import subprocess
import time
import zlib

BASE = os.environ.get("COMFY_BASE", "http://localhost:8188")


def nonce():
    """Per-run tag so fixture prompts never hit ComfyUI's prompt cache."""
    return time.time_ns() // 1_000_000

def http_json(method, path, payload=None):
    url = BASE + path
    if not url.startswith("http://"):
        raise ValueError(f"URL scheme not permitted: {url}")
    args = ["curl", "-s", "--max-time", "30", "-X", method, url]
    if payload is not None:
        args += ["-H", "Content-Type: application/json", "--data", json.dumps(payload)]
    proc = subprocess.run(args, capture_output=True, text=True, check=True)
    out = proc.stdout
    return 200, (json.loads(out) if out else None)

def queue_prompt(prompt, workflow=None, client_id="yara-test-client"):
    extra: dict = {"client_id": client_id}
    if workflow is not None:
        extra["extra_pnginfo"] = {"workflow": workflow}
    _, resp = http_json("POST", "/prompt", {"prompt": prompt, "extra_data": extra})
    return resp

def get_queue():
    _, q = http_json("GET", "/queue")
    return q or {}

def clear_queue():
    q = get_queue()
    ids = [p[1] for p in q.get("queue_pending", [])]
    if ids:
        http_json("POST", "/queue", {"delete": ids})
    for rid in (q.get("queue_running") or []):
        http_json("POST", "/interrupt", {"prompt_id": rid[1]})

def png_chunk(ctype, data):
    c = struct.pack(">I", len(data)) + ctype + data
    return c + struct.pack(">I", zlib.crc32(ctype + data) & 0xFFFFFFFF)

def make_png(path, width=64, height=64, rgb=(200, 50, 50), text_chunks=None):
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    out = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr) + png_chunk(b"IDAT", zlib.compress(raw))
    for kw, data in (text_chunks or []):
        out += png_chunk(b"tEXt", kw.encode() + b"\x00" + data.encode())
    with open(path, "wb") as f:
        f.write(out)

def read_text_chunks(path):
    with open(path, "rb") as f:
        data = f.read()
    i = 8
    chunks = {}
    while i < len(data):
        if i + 8 > len(data):
            break
        (length,) = struct.unpack(">I", data[i:i+4])
        ctype = data[i+4:i+8]
        payload = data[i+8:i+8+length]
        if ctype == b"tEXt":
            kw, _, txt = payload.partition(b"\x00")
            chunks[kw.decode()] = txt.decode("utf-8", "replace")
        i += 12 + length
        if ctype == b"IEND":
            break
    return chunks

def remove_text_chunk(path, keyword, out_path):
    with open(path, "rb") as f:
        data = f.read()
    i = 8
    out = b"\x89PNG\r\n\x1a\n"
    while i < len(data):
        if i + 8 > len(data):
            break
        (length,) = struct.unpack(">I", data[i:i+4])
        ctype = data[i+4:i+8]
        payload = data[i+8:i+8+length]
        crc = data[i+8+length:i+12+length]
        keep = not (ctype == b"tEXt" and payload.split(b"\x00", 1)[0].decode() == keyword)
        if keep:
            out += struct.pack(">I", length) + ctype + payload + crc
        i += 12 + length
        if ctype == b"IEND":
            break
    with open(out_path, "wb") as f:
        f.write(out)

if __name__ == "__main__":
    print(get_queue())
