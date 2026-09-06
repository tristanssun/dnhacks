#!/usr/bin/env python3
"""Index scan recordings and archived 3D models with Gemini.

Videos: write <video>.analysis.json and one JSON line per completed task in
videos/tasks.jsonl. Models: write <model>.analysis.json and one line per
place in models/index.jsonl. --search ranks both corpora (vector if a key
is present, lexical otherwise).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any

API_ROOT = "https://generativelanguage.googleapis.com"
DEFAULT_MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.6-flash")
MODEL_FALLBACKS = [
    "gemini-3.6-flash",
    "gemini-3.5-flash",
    "gemini-flash-latest",
    "gemini-2.5-flash",
]
DEFAULT_EMBED = os.environ.get("GEMINI_EMBED_MODEL", "gemini-embedding-001")
EMBED_FALLBACKS = [
    "gemini-embedding-001",
    "gemini-embedding-2",
    "text-embedding-004",
]
PROMPT = """You are reviewing a first-person scan recording from a mapping phone.
The wearer is walking a real space (often a room, hallway, or stair) for a
collaborative map. Segment the video into discrete completed tasks: actions
that finished, not continuous walking. Examples: entered a room, inspected a
doorway, scanned a wall, found an object, climbed stairs, exited a space.

Return JSON only with this shape:
{
  "summary": "2-4 sentence overview of the walk",
  "tasks": [
    {
      "title": "short completed-task name",
      "description": "what happened and what is visible",
      "start_s": 0.0,
      "end_s": 12.5,
      "status": "completed",
      "objects": ["door"],
      "location": "entry hallway"
    }
  ]
}

Rules:
- Only include tasks that were completed in the footage.
- status must be "completed" for every task.
- Timestamps are seconds from the start of this video and must be in order.
- Cover the whole recording without large gaps.
- Be specific about rooms, objects, and actions. No filler.
"""
MODEL_PROMPT = """You are reviewing a 3D scan of a real mapped space. You may
get a texture atlas (unfolded wall, floor, and ceiling photos), plus metadata
and completed walk tasks from the same run.

Describe the space and list distinct places or features someone would search
for later (rooms, doorways, stairs, objects, furniture).

Return JSON only with this shape:
{
  "summary": "2-4 sentence overview of the space",
  "places": [
    {
      "title": "short place or feature name",
      "description": "what is visible and where it sits",
      "objects": ["door"],
      "location": "entry hallway"
    }
  ]
}

Rules:
- Be specific about rooms, objects, and layout. No filler.
- Prefer places a person would name when looking the space up later.
- If the atlas is an unwrap, infer the real space, not the UV layout.
"""


def log(msg: str) -> None:
    print(f"[video-summary] {msg}", file=sys.stderr, flush=True)


def read_key(data_dir: str) -> str:
    for name in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"):
        val = (os.environ.get(name) or "").strip()
        if val:
            return val
    path = os.path.join(data_dir, "gemini.key")
    if os.path.isfile(path):
        return open(path, encoding="utf-8").read().strip()
    return ""


def read_json(path: str) -> dict[str, Any]:
    if not os.path.isfile(path):
        return {}
    try:
        obj = json.loads(open(path, encoding="utf-8").read() or "{}")
        return obj if isinstance(obj, dict) else {}
    except json.JSONDecodeError:
        return {}


def write_json(path: str, obj: dict[str, Any]) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def patch_sidecar(path: str, **fields: Any) -> None:
    obj = read_json(path)
    obj.update(fields)
    write_json(path, obj)


def http_json(
    method: str,
    url: str,
    body: Any | None = None,
    headers: dict[str, str] | None = None,
    raw: bytes | None = None,
    timeout: float = 120.0,
) -> tuple[int, dict[str, str], Any]:
    data = raw
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw_body = resp.read()
            hdr = {k.lower(): v for k, v in resp.headers.items()}
            parsed: Any = None
            if raw_body:
                try:
                    parsed = json.loads(raw_body.decode("utf-8"))
                except json.JSONDecodeError:
                    parsed = raw_body.decode("utf-8", "replace")
            return resp.getcode(), hdr, parsed
    except urllib.error.HTTPError as e:
        raw_body = e.read()
        parsed = None
        if raw_body:
            try:
                parsed = json.loads(raw_body.decode("utf-8"))
            except json.JSONDecodeError:
                parsed = raw_body.decode("utf-8", "replace")
        return e.code, {k.lower(): v for k, v in e.headers.items()}, parsed


def extract_json(text: str) -> dict[str, Any]:
    text = (text or "").strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            return obj
    except json.JSONDecodeError:
        pass
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        obj = json.loads(text[start : end + 1])
        if isinstance(obj, dict):
            return obj
    raise ValueError("Gemini response was not JSON")


def which(name: str) -> str:
    env = os.environ.get("PATH") or ""
    extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    parts = extras + [p for p in env.split(":") if p]
    for folder in parts:
        path = os.path.join(folder, name)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return ""


def make_proxy(src: str, dest: str) -> str:
    ffmpeg = which("ffmpeg")
    if not ffmpeg:
        return src
    cmd = [
        ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
        "-i", src,
        "-vf", "fps=1,scale='min(640,iw)':-2",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "28", "-pix_fmt", "yuv420p",
        "-an", "-movflags", "+faststart",
        dest,
    ]
    try:
        subprocess.run(cmd, check=True, timeout=600)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        log(f"ffmpeg proxy failed ({e}); using original")
        return src
    if os.path.isfile(dest) and os.path.getsize(dest) > 0:
        log(f"proxy {os.path.getsize(dest)} bytes from {os.path.getsize(src)}")
        return dest
    return src


def upload_file(key: str, path: str, mime: str = "video/mp4") -> dict[str, Any]:
    size = os.path.getsize(path)
    start_url = f"{API_ROOT}/upload/v1beta/files?key={key}"
    status, hdrs, body = http_json(
        "POST",
        start_url,
        {"file": {"display_name": os.path.basename(path)}},
        {
            "X-Goog-Upload-Protocol": "resumable",
            "X-Goog-Upload-Command": "start",
            "X-Goog-Upload-Header-Content-Length": str(size),
            "X-Goog-Upload-Header-Content-Type": mime,
        },
        timeout=60.0,
    )
    upload_url = hdrs.get("x-goog-upload-url") or ""
    if status >= 300 or not upload_url:
        raise RuntimeError(f"Gemini upload start failed {status}: {body}")
    with open(path, "rb") as f:
        raw = f.read()
    status, _hdrs, body = http_json(
        "POST",
        upload_url,
        raw=raw,
        headers={
            "X-Goog-Upload-Offset": "0",
            "X-Goog-Upload-Command": "upload, finalize",
            "Content-Length": str(len(raw)),
            "Content-Type": mime,
        },
        timeout=600.0,
    )
    if status >= 300 or not isinstance(body, dict):
        raise RuntimeError(f"Gemini upload failed {status}: {body}")
    info = body.get("file") if isinstance(body.get("file"), dict) else body
    name = str(info.get("name") or "")
    if not name:
        raise RuntimeError(f"Gemini upload missing file name: {body}")
    deadline = time.time() + 300
    while time.time() < deadline:
        state = str(info.get("state") or "")
        if state == "ACTIVE":
            return info
        if state == "FAILED":
            raise RuntimeError(f"Gemini file processing failed: {info}")
        time.sleep(2.0)
        st, _h, got = http_json("GET", f"{API_ROOT}/v1beta/{name}?key={key}", timeout=60.0)
        if st >= 300 or not isinstance(got, dict):
            raise RuntimeError(f"Gemini file poll failed {st}: {got}")
        info = got
    raise RuntimeError("Gemini file did not become ACTIVE")


def delete_file(key: str, name: str) -> None:
    if not name:
        return
    try:
        http_json("DELETE", f"{API_ROOT}/v1beta/{name}?key={key}", timeout=30.0)
    except Exception as e:
        log(f"file delete ignored: {e}")


def generate_json(key: str, parts: list[dict[str, Any]], model: str) -> dict[str, Any]:
    url = f"{API_ROOT}/v1beta/models/{model}:generateContent?key={key}"
    payload = {
        "contents": [{"parts": parts}],
        "generationConfig": {
            "temperature": 0.2,
            "responseMimeType": "application/json",
        },
    }
    last = None
    for attempt in range(4):
        status, _h, body = http_json("POST", url, payload, timeout=600.0)
        if status == 503:
            wait = 5 * (attempt + 1)
            log(f"generate 503 on {model}, retry in {wait}s")
            last = RuntimeError(f"Gemini generate failed {status}: {body}")
            time.sleep(wait)
            continue
        if status >= 300 or not isinstance(body, dict):
            raise RuntimeError(f"Gemini generate failed {status}: {body}")
        cands = body.get("candidates") or []
        if not cands:
            raise RuntimeError(f"Gemini returned no candidates: {body}")
        got = (((cands[0] or {}).get("content") or {}).get("parts") or [])
        text = "".join(str(p.get("text") or "") for p in got if isinstance(p, dict))
        return extract_json(text)
    raise last or RuntimeError("Gemini generate failed")


def generate_json_with_fallback(
    key: str, parts: list[dict[str, Any]], preferred: str
) -> tuple[dict[str, Any], str]:
    models = [preferred] + [m for m in MODEL_FALLBACKS if m != preferred]
    last: Exception | None = None
    for model in models:
        log(f"generate model={model}")
        try:
            return generate_json(key, parts, model), model
        except Exception as e:
            last = e
            msg = str(e)
            if "404" in msg or "NOT_FOUND" in msg or "no longer available" in msg:
                log(f"model {model} unavailable, trying next")
                continue
            raise
    raise RuntimeError(str(last) if last else "Gemini generate failed")


def generate_summary(key: str, file_uri: str, model: str) -> dict[str, Any]:
    return generate_json(key, [
        {"file_data": {"mime_type": "video/mp4", "file_uri": file_uri}},
        {"text": PROMPT},
    ], model)


def generate_summary_with_fallback(key: str, file_uri: str, preferred: str) -> tuple[dict[str, Any], str]:
    return generate_json_with_fallback(key, [
        {"file_data": {"mime_type": "video/mp4", "file_uri": file_uri}},
        {"text": PROMPT},
    ], preferred)


def embed_values(item: Any) -> list[float] | None:
    if not isinstance(item, dict):
        return None
    values = item.get("values")
    if values is None and isinstance(item.get("embedding"), dict):
        values = item["embedding"].get("values")
    if not isinstance(values, list):
        return None
    return [float(v) for v in values]


def embed_texts(key: str, texts: list[str], model: str, task: str = "RETRIEVAL_DOCUMENT") -> list[list[float]]:
    if not texts:
        return []
    url = f"{API_ROOT}/v1beta/models/{model}:batchEmbedContents?key={key}"
    out: list[list[float]] = []
    for i in range(0, len(texts), 16):
        chunk = texts[i : i + 16]
        reqs = [{
            "model": f"models/{model}",
            "content": {"parts": [{"text": t}]},
            "taskType": task,
        } for t in chunk]
        status, _h, body = http_json("POST", url, {"requests": reqs}, timeout=120.0)
        if status >= 300 or not isinstance(body, dict):
            raise RuntimeError(f"Gemini embed failed {status}: {body}")
        embeddings = body.get("embeddings") or []
        if len(embeddings) != len(chunk):
            raise RuntimeError(f"Gemini embed count mismatch {len(embeddings)} != {len(chunk)}")
        for item in embeddings:
            values = embed_values(item)
            if values is None:
                raise RuntimeError(f"Gemini embed missing values: {item}")
            out.append(values)
    return out


def embed_texts_with_fallback(
    key: str, texts: list[str], preferred: str, task: str = "RETRIEVAL_DOCUMENT"
) -> tuple[list[list[float]], str]:
    models = [preferred] + [m for m in EMBED_FALLBACKS if m != preferred]
    last: Exception | None = None
    for model in models:
        try:
            return embed_texts(key, texts, model, task), model
        except Exception as e:
            last = e
            log(f"embed model {model} failed: {e}")
    raise RuntimeError(str(last) if last else "Gemini embed failed")


def task_id(video_name: str, index: int) -> str:
    stem = video_name.rsplit(".", 1)[0]
    return f"{stem}:t{index:02d}"


def normalize_tasks(video: str, duration_s: float, raw: list[Any]) -> list[dict[str, Any]]:
    tasks: list[dict[str, Any]] = []
    for i, item in enumerate(raw, start=1):
        if not isinstance(item, dict):
            continue
        title = str(item.get("title") or f"Task {i}").strip()
        desc = str(item.get("description") or "").strip()
        try:
            start_s = max(0.0, float(item.get("start_s") or 0.0))
        except (TypeError, ValueError):
            start_s = 0.0
        try:
            end_s = float(item.get("end_s") or start_s)
        except (TypeError, ValueError):
            end_s = start_s
        if duration_s > 0:
            start_s = min(start_s, duration_s)
            end_s = min(max(end_s, start_s), duration_s)
        elif end_s < start_s:
            end_s = start_s
        objects = item.get("objects") if isinstance(item.get("objects"), list) else []
        objects = [str(o).strip() for o in objects if str(o).strip()]
        location = str(item.get("location") or "").strip()
        embed_text = (
            f"Completed task: {title}. {desc} "
            f"Location: {location or 'unknown'}. "
            f"Objects: {', '.join(objects) or 'none'}. "
            f"Recording {video} {start_s:.1f}-{end_s:.1f}s."
        )
        tasks.append({
            "id": task_id(video, i),
            "index": i,
            "video": video,
            "title": title,
            "description": desc,
            "start_s": round(start_s, 2),
            "end_s": round(end_s, 2),
            "status": "completed",
            "objects": objects,
            "location": location,
            "embed_text": embed_text,
        })
    return tasks


def rewrite_tasks_jsonl(path: str, video: str, tasks: list[dict[str, Any]]) -> None:
    lines: list[str] = []
    if os.path.isfile(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and obj.get("video") == video:
                continue
            lines.append(line)
    for task in tasks:
        slim = dict(task)
        lines.append(json.dumps(slim, ensure_ascii=False))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")
    os.replace(tmp, path)


def rewrite_jsonl(path: str, drop_key: str, drop_value: str, rows: list[dict[str, Any]]) -> None:
    lines: list[str] = []
    if os.path.isfile(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and obj.get(drop_key) == drop_value:
                continue
            lines.append(line)
    for row in rows:
        lines.append(json.dumps(row, ensure_ascii=False))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")
    os.replace(tmp, path)


def load_jsonl(path: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not os.path.isfile(path):
        return rows
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows


def model_stem(name: str) -> str:
    return name[:-4] if name.endswith(".ply") else name


def place_id(model_name: str, index: int) -> str:
    return f"{model_stem(model_name)}:p{index:02d}"


def related_video_tasks(data_dir: str, run: int, address: str) -> list[dict[str, Any]]:
    video_dir = os.path.join(data_dir, "videos")
    tasks = load_jsonl(os.path.join(video_dir, "tasks.jsonl"))
    if not tasks:
        return []
    run_by_video: dict[str, int] = {}
    addr_by_video: dict[str, str] = {}
    if os.path.isdir(video_dir):
        for name in os.listdir(video_dir):
            if not name.endswith(".mp4.json"):
                continue
            meta = read_json(os.path.join(video_dir, name))
            video = str(meta.get("name") or name[:-5])
            try:
                run_by_video[video] = int(meta.get("run") or 0)
            except (TypeError, ValueError):
                run_by_video[video] = 0
            addr_by_video[video] = str(meta.get("address") or "").strip()
    out: list[dict[str, Any]] = []
    for task in tasks:
        video = str(task.get("video") or "")
        if run > 0 and run_by_video.get(video) == run:
            out.append(task)
            continue
        if run <= 0 and address and addr_by_video.get(video) == address:
            out.append(task)
    return out


def normalize_places(
    model: str,
    raw: list[Any],
    summary: str,
    address: str,
    title: str,
) -> list[dict[str, Any]]:
    places: list[dict[str, Any]] = []
    for i, item in enumerate(raw, start=1):
        if not isinstance(item, dict):
            continue
        name = str(item.get("title") or f"Place {i}").strip()
        desc = str(item.get("description") or "").strip()
        objects = item.get("objects") if isinstance(item.get("objects"), list) else []
        objects = [str(o).strip() for o in objects if str(o).strip()]
        location = str(item.get("location") or "").strip()
        embed_text = (
            f"3D model place: {name}. {desc} "
            f"Location: {location or address or 'unknown'}. "
            f"Objects: {', '.join(objects) or 'none'}. "
            f"Model {model}."
        )
        places.append({
            "id": place_id(model, i),
            "kind": "place",
            "index": i,
            "model": model,
            "title": name,
            "description": desc,
            "objects": objects,
            "location": location,
            "address": address,
            "embed_text": embed_text,
        })
    overview = (
        f"3D model of {title or address or model}. {summary} "
        f"Location: {address or 'unknown'}. "
        f"Places: {', '.join(p['title'] for p in places) or 'none'}."
    )
    places.insert(0, {
        "id": f"{model_stem(model)}:model",
        "kind": "model",
        "index": 0,
        "model": model,
        "title": title or address or model_stem(model),
        "description": summary,
        "objects": [],
        "location": address,
        "address": address,
        "embed_text": overview,
    })
    return places


def attach_embeddings(
    key: str, rows: list[dict[str, Any]], embed_model: str
) -> tuple[list[list[float]], str, int]:
    if not rows:
        return [], "", 0
    try:
        embeddings, embed_model = embed_texts_with_fallback(
            key, [str(r.get("embed_text") or r.get("title") or "") for r in rows], embed_model
        )
        dim = len(embeddings[0]) if embeddings else 0
        for row, vec in zip(rows, embeddings):
            row["embedding"] = vec
        return embeddings, embed_model, dim
    except Exception as e:
        log(f"embeddings skipped: {e}")
        return [], "", 0


def index_model(model: str, data_dir: str) -> dict[str, Any]:
    sidecar = model + ".json"
    analysis_path = model + ".analysis.json"
    meta = read_json(sidecar)
    model_name = os.path.basename(model)
    stem = model_stem(model)
    atlas = stem + ".jpg"
    address = str(meta.get("address") or "").strip()
    title = str(meta.get("title") or "").strip()
    try:
        run = int(meta.get("run") or 0)
    except (TypeError, ValueError):
        run = 0
    key = read_key(data_dir)
    if not key:
        raise RuntimeError("Set GEMINI_API_KEY or put the key in collab-data/gemini.key")
    patch_sidecar(sidecar, index_status="processing", index_error="")
    related = related_video_tasks(data_dir, run, address)
    related_txt = ""
    if related:
        bits = []
        for task in related[:24]:
            bits.append(
                f"- {task.get('title')}: {task.get('description')} "
                f"({task.get('location') or ''})"
            )
        related_txt = "Walk tasks from the same scan:\n" + "\n".join(bits)
    context = (
        f"Model file: {model_name}\n"
        f"Title: {title or 'unknown'}\n"
        f"Address: {address or 'unknown'}\n"
        f"Kind: {meta.get('kind') or 'unknown'}\n"
        f"Nodes: {meta.get('nodes') or 0}, faces: {meta.get('faces') or 0}\n"
        f"{related_txt}\n\n{MODEL_PROMPT}"
    )
    parts: list[dict[str, Any]] = [{"text": context}]
    file_name = ""
    model_id = DEFAULT_MODEL
    if os.path.isfile(atlas) and os.path.getsize(atlas) > 0:
        log(f"upload atlas {atlas} model={model_id}")
        info = upload_file(key, atlas, "image/jpeg")
        file_name = str(info.get("name") or "")
        uri = str(info.get("uri") or "")
        if uri:
            parts.insert(0, {"file_data": {"mime_type": "image/jpeg", "file_uri": uri}})
    try:
        parsed, model_id = generate_json_with_fallback(key, parts, model_id)
    finally:
        delete_file(key, file_name)
    summary = str(parsed.get("summary") or "").strip()
    places = normalize_places(model_name, parsed.get("places") or [], summary, address, title)
    embeddings, embed_model, dim = attach_embeddings(key, places, DEFAULT_EMBED)
    analysis = {
        "ok": True,
        "status": "ready",
        "name": model_name,
        "kind": "model",
        "summary": summary,
        "places": places,
        "place_count": max(0, len(places) - 1),
        "model": model_id,
        "embed_model": embed_model if embeddings else "",
        "embedding_dim": dim,
        "created": int(time.time()),
        "error": "",
    }
    write_json(analysis_path, analysis)
    rewrite_jsonl(os.path.join(os.path.dirname(model), "index.jsonl"), "model", model_name, places)
    patch_sidecar(
        sidecar,
        index_status="ready",
        index_error="",
        place_count=max(0, len(places) - 1),
    )
    log(f"ready model {model_name} places={len(places)} embed_dim={dim}")
    return analysis


def query_tokens(q: str) -> list[str]:
    return [t for t in re.findall(r"[a-z0-9]+", (q or "").lower()) if len(t) > 1]


def lexical_score(q: str, text: str) -> float:
    tokens = query_tokens(q)
    if not tokens:
        return 0.0
    hay = (text or "").lower()
    return sum(1.0 for t in tokens if t in hay) / float(len(tokens))


def cosine(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = 0.0
    na = 0.0
    nb = 0.0
    for x, y in zip(a, b):
        dot += x * y
        na += x * x
        nb += y * y
    if na <= 0 or nb <= 0:
        return 0.0
    return dot / ((na ** 0.5) * (nb ** 0.5))


def corpus_text(row: dict[str, Any]) -> str:
    objects = row.get("objects") if isinstance(row.get("objects"), list) else []
    return " ".join([
        str(row.get("title") or ""),
        str(row.get("description") or ""),
        str(row.get("location") or ""),
        str(row.get("address") or ""),
        str(row.get("embed_text") or ""),
        " ".join(str(o) for o in objects),
    ])


def load_search_corpus(data_dir: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for task in load_jsonl(os.path.join(data_dir, "videos", "tasks.jsonl")):
        item = dict(task)
        item.setdefault("kind", "task")
        rows.append(item)
    for place in load_jsonl(os.path.join(data_dir, "models", "index.jsonl")):
        item = dict(place)
        item.setdefault("kind", str(place.get("kind") or "place"))
        rows.append(item)
    return rows


def model_for_run(data_dir: str, video: str) -> str:
    video_meta = read_json(os.path.join(data_dir, "videos", video + ".json"))
    try:
        run = int(video_meta.get("run") or 0)
    except (TypeError, ValueError):
        run = 0
    address = str(video_meta.get("address") or "").strip()
    models_dir = os.path.join(data_dir, "models")
    if not os.path.isdir(models_dir):
        return ""
    best = ""
    for name in os.listdir(models_dir):
        if not name.endswith(".ply.json"):
            continue
        meta = read_json(os.path.join(models_dir, name))
        try:
            mrun = int(meta.get("run") or 0)
        except (TypeError, ValueError):
            mrun = 0
        if run > 0 and mrun == run:
            return str(meta.get("name") or name[:-5])
        if not best and address and str(meta.get("address") or "") == address:
            best = str(meta.get("name") or name[:-5])
    return best


def fmt_clock(s: Any) -> str:
    try:
        n = max(0, int(round(float(s) or 0.0)))
    except (TypeError, ValueError):
        n = 0
    return f"{n // 60}:{n % 60:02d}"


def hit_from_row(row: dict[str, Any], score: float, data_dir: str) -> dict[str, Any]:
    kind = str(row.get("kind") or "task")
    title = str(row.get("title") or row.get("id") or "Match")
    video = str(row.get("video") or "")
    model = str(row.get("model") or "")
    if kind == "task" and video and not model:
        model = model_for_run(data_dir, video)
    location = str(row.get("location") or row.get("address") or "")
    if kind == "task":
        detail = "Recording"
        if video:
            detail += " · " + fmt_clock(row.get("start_s"))
        if location:
            detail += " · " + location
    elif kind == "model":
        detail = "3D model"
        if location:
            detail += " · " + location
    else:
        detail = "Model"
        if location:
            detail += " · " + location
    try:
        start_s = float(row.get("start_s") or 0.0)
    except (TypeError, ValueError):
        start_s = 0.0
    try:
        lat = float(row.get("lat") or 0.0)
        lng = float(row.get("lng") or 0.0)
    except (TypeError, ValueError):
        lat = 0.0
        lng = 0.0
    return {
        "kind": kind,
        "label": title,
        "detail": detail,
        "score": round(score, 4),
        "id": str(row.get("id") or ""),
        "video": video,
        "model": model,
        "start_s": start_s,
        "lat": lat,
        "lng": lng,
    }


def search_history(query: str, data_dir: str, limit: int = 12) -> dict[str, Any]:
    q = (query or "").strip()
    rows = load_search_corpus(data_dir)
    if not q:
        return {"ok": True, "query": "", "hits": []}
    qvec: list[float] = []
    embed_model = ""
    key = read_key(data_dir)
    if key:
        try:
            vecs, embed_model = embed_texts_with_fallback(
                key, [q], DEFAULT_EMBED, "RETRIEVAL_QUERY"
            )
            if vecs:
                qvec = vecs[0]
        except Exception as e:
            log(f"query embed skipped: {e}")
    scored: list[tuple[float, dict[str, Any]]] = []
    for row in rows:
        lex = lexical_score(q, corpus_text(row))
        vec = row.get("embedding") if isinstance(row.get("embedding"), list) else []
        try:
            vecf = [float(v) for v in vec]
        except (TypeError, ValueError):
            vecf = []
        sim = cosine(qvec, vecf) if qvec and vecf else 0.0
        score = (0.75 * sim + 0.25 * lex) if qvec and vecf else lex
        if score < 0.12:
            continue
        scored.append((score, row))
    scored.sort(key=lambda pair: pair[0], reverse=True)
    hits = [hit_from_row(row, score, data_dir) for score, row in scored[:limit]]
    return {
        "ok": True,
        "query": q,
        "hits": hits,
        "embed_model": embed_model if qvec else "",
        "count": len(hits),
    }


def summarize(video: str, data_dir: str) -> dict[str, Any]:
    sidecar = video + ".json"
    analysis_path = video + ".analysis.json"
    meta = read_json(sidecar)
    video_name = os.path.basename(video)
    duration_s = float(meta.get("duration_s") or 0.0)
    key = read_key(data_dir)
    if not key:
        raise RuntimeError("Set GEMINI_API_KEY or put the key in collab-data/gemini.key")
    patch_sidecar(sidecar, summary_status="processing", summary_error="")
    model = DEFAULT_MODEL
    embed_model = DEFAULT_EMBED
    file_name = ""
    with tempfile.TemporaryDirectory(prefix="collab-summary-") as tmp:
        proxy = os.path.join(tmp, "proxy.mp4")
        src = make_proxy(video, proxy)
        log(f"upload {src} model={model}")
        info = upload_file(key, src)
        file_name = str(info.get("name") or "")
        uri = str(info.get("uri") or "")
        if not uri:
            raise RuntimeError(f"Gemini file missing uri: {info}")
        try:
            parsed, model = generate_summary_with_fallback(key, uri, model)
        finally:
            delete_file(key, file_name)
    summary = str(parsed.get("summary") or "").strip()
    tasks = normalize_tasks(video_name, duration_s, parsed.get("tasks") or [])
    embeddings: list[list[float]] = []
    dim = 0
    if tasks:
        try:
            embeddings, embed_model = embed_texts_with_fallback(
                key, [t["embed_text"] for t in tasks], embed_model
            )
            if embeddings:
                dim = len(embeddings[0])
                for task, vec in zip(tasks, embeddings):
                    task["embedding"] = vec
        except Exception as e:
            log(f"embeddings skipped: {e}")
            embeddings = []
            embed_model = ""
    analysis = {
        "ok": True,
        "status": "ready",
        "name": video_name,
        "summary": summary,
        "tasks": tasks,
        "task_count": len(tasks),
        "model": model,
        "embed_model": embed_model if embeddings else "",
        "embedding_dim": dim,
        "created": int(time.time()),
        "duration_s": duration_s,
        "error": "",
    }
    write_json(analysis_path, analysis)
    video_dir = os.path.dirname(video)
    rewrite_tasks_jsonl(os.path.join(video_dir, "tasks.jsonl"), video_name, tasks)
    patch_sidecar(
        sidecar,
        summary_status="ready",
        summary_error="",
        task_count=len(tasks),
    )
    log(f"ready {video_name} tasks={len(tasks)} embed_dim={dim}")
    return analysis


def self_test() -> int:
    sample = extract_json('```json\n{"summary":"Hall walk","tasks":[{"title":"Enter","start_s":0,"end_s":4}]}\n```')
    assert sample["summary"] == "Hall walk"
    tasks = normalize_tasks("clip.mp4", 10.0, sample["tasks"])
    assert tasks[0]["id"] == "clip:t01"
    assert tasks[0]["status"] == "completed"
    assert "Completed task: Enter" in tasks[0]["embed_text"]
    places = normalize_places(
        "room.ply",
        [{"title": "Doorway", "description": "Wood door", "objects": ["door"], "location": "hall"}],
        "A hall with a door.",
        "123 Main St",
        "123 Main St",
    )
    assert places[0]["kind"] == "model" and places[0]["id"] == "room:model"
    assert places[1]["id"] == "room:p01" and "Doorway" in places[1]["embed_text"]
    assert lexical_score("door hall", "Cleared doorway in the hall") == 1.0
    assert cosine([1.0, 0.0], [1.0, 0.0]) > 0.99
    ranked = search_history("doorway", os.path.dirname(__file__) + "/.no-such-data")
    assert ranked["ok"] is True and ranked["hits"] == []
    print("self-test ok", flush=True)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Index collab recordings and models with Gemini")
    ap.add_argument("--video", help="Absolute path to the .mp4")
    ap.add_argument("--model", help="Absolute path to an archived .ply")
    ap.add_argument("--search", action="store_true", help="Rank history for --query")
    ap.add_argument("--query", default="", help="Search text (with --search)")
    ap.add_argument("--data-dir", default="", help="collab-data directory (for gemini.key)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.search:
        data_dir = args.data_dir or os.getcwd()
        print(json.dumps(search_history(args.query, os.path.abspath(data_dir)), ensure_ascii=False), flush=True)
        return 0
    if args.model:
        model = os.path.abspath(args.model)
        if not os.path.isfile(model):
            log(f"missing model {model}")
            return 2
        data_dir = args.data_dir or os.path.dirname(os.path.dirname(model))
        sidecar = model + ".json"
        try:
            index_model(model, data_dir)
            return 0
        except Exception as e:
            log(f"error {e}")
            patch_sidecar(sidecar, index_status="error", index_error=str(e)[:400])
            return 1
    if not args.video:
        ap.error("--video, --model, or --search is required")
    video = os.path.abspath(args.video)
    if not os.path.isfile(video):
        log(f"missing video {video}")
        return 2
    data_dir = args.data_dir or os.path.dirname(os.path.dirname(video))
    sidecar = video + ".json"
    try:
        summarize(video, data_dir)
        return 0
    except Exception as e:
        log(f"error {e}")
        patch_sidecar(sidecar, summary_status="error", summary_error=str(e)[:400])
        return 1


if __name__ == "__main__":
    sys.exit(main())
