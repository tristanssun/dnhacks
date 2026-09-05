"""Multi-video and incrementally updated MapAnything reconstruction UI."""
from __future__ import annotations

import json
import os
import shutil
import threading
import time
import uuid
from pathlib import Path

os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")

import cv2
import gradio as gr
import numpy as np
import torch
import trimesh
from mapanything.models import MapAnything
from mapanything.utils.geometry import depthmap_to_world_frame
from mapanything.utils.image import load_images
from mapanything.utils.viz import predictions_to_glb

ROOT = Path(__file__).resolve().parent
DATA_ROOT = Path(os.getenv("DATA_ROOT", ROOT))
UPLOADS = DATA_ROOT / "uploads"
LIVE = DATA_ROOT / "live_sessions"
OUTPUTS = DATA_ROOT / "outputs"
MODEL_ID = os.getenv("MAPANYTHING_MODEL", "facebook/map-anything-apache")
UPDATE_SECONDS = float(os.getenv("TWIN_UPDATE_SECONDS", "10"))
VIDEO_SUFFIXES = {".avi", ".m4v", ".mkv", ".mov", ".mp4", ".webm"}
MODEL = None
MODEL_LOCK = threading.Lock()


def _paths(files) -> list[Path]:
    if not files:
        return []
    return [Path(item.get("name") if isinstance(item, dict) else item) for item in files]


def _extract_to_directory(sources, frame_dir, seconds_between_frames, max_frames):
    """Atomically replace frame_dir with evenly sampled, collision-free frames."""
    staging = frame_dir.with_name(f"{frame_dir.name}.new-{uuid.uuid4().hex[:8]}")
    staging.mkdir(parents=True)
    frames = []
    try:
        for video_index, source in enumerate(sources):
            capture = cv2.VideoCapture(str(source))
            fps = capture.get(cv2.CAP_PROP_FPS)
            if not capture.isOpened() or fps <= 0:
                capture.release()
                raise gr.Error(f"Could not decode {source.name}")
            step = max(1, round(fps * seconds_between_frames))
            frame_number = selected = 0
            while selected < max_frames:
                ok, frame = capture.read()
                if not ok:
                    break
                if frame_number % step == 0:
                    destination = staging / f"v{video_index:03d}_f{frame_number:08d}.jpg"
                    cv2.imwrite(str(destination), frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
                    frames.append(destination)
                    selected += 1
                frame_number += 1
            capture.release()
        if len(frames) < 2:
            raise gr.Error("At least two frames are required.")
        shutil.rmtree(frame_dir, ignore_errors=True)
        staging.rename(frame_dir)
        return [str(frame_dir / frame.name) for frame in frames]
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def extract_frames(files, seconds_between_frames: float, max_frames: int):
    sources = _paths(files)
    if not sources:
        raise gr.Error("Upload at least one video.")
    frame_dir = UPLOADS / uuid.uuid4().hex[:12] / "images"
    frames = _extract_to_directory(sources, frame_dir, seconds_between_frames, max_frames)
    return str(frame_dir), frames, f"Prepared {len(frames)} frames from {len(sources)} videos."


def reconstruct(frame_dir: str, confidence_percentile: float, as_mesh: bool):
    global MODEL
    if not frame_dir or not Path(frame_dir).is_dir():
        raise gr.Error("Extract frames first.")
    if not torch.cuda.is_available():
        raise gr.Error("CUDA is required. Launch this app with scripts/submit_gpu.sh.")
    device = torch.device("cuda")
    with MODEL_LOCK, torch.inference_mode():
        if MODEL is None:
            MODEL = MapAnything.from_pretrained(MODEL_ID).to(device).eval()
        views = load_images(frame_dir)
        outputs = MODEL.infer(views, memory_efficient_inference=True, minibatch_size=1,
                              use_amp=True, amp_dtype="bf16", apply_mask=True, mask_edges=True)
    points, images, masks = [], [], []
    for prediction in outputs:
        depth = prediction["depth_z"][0].squeeze(-1)
        xyz, valid = depthmap_to_world_frame(
            depth, prediction["intrinsics"][0], prediction["camera_poses"][0])
        mask = prediction["mask"][0].squeeze(-1).bool() & valid
        confidence = prediction["conf"][0].squeeze(-1)
        valid_confidence = confidence[mask]
        if valid_confidence.numel() and confidence_percentile > 0:
            threshold = torch.quantile(valid_confidence.float(), confidence_percentile / 100.0)
            mask &= confidence >= threshold
        points.append(xyz.cpu().numpy())
        images.append(prediction["img_no_norm"][0].cpu().numpy())
        masks.append(mask.cpu().numpy())
    scene = predictions_to_glb({"world_points": np.stack(points), "images": np.stack(images),
                                "final_masks": np.stack(masks)}, as_mesh=as_mesh)
    OUTPUTS.mkdir(parents=True, exist_ok=True)
    output = OUTPUTS / f"reconstruction-{Path(frame_dir).parent.name}.glb"
    temporary = output.with_suffix(".tmp.glb")
    scene.export(temporary)
    temporary.replace(output)
    return str(output), str(output), f"Complete: {len(views)} views reconstructed."


def _session_dir(session_id: str) -> Path:
    safe_id = Path(session_id or "").name
    if not safe_id or safe_id != session_id:
        raise gr.Error("Start a live session first.")
    return LIVE / safe_id


def add_live_videos(session_id: str, files):
    sources = _paths(files)
    if not sources:
        raise gr.Error("Choose one or more video clips.")
    session_id = session_id or uuid.uuid4().hex[:12]
    inbox = _session_dir(session_id) / "videos"
    inbox.mkdir(parents=True, exist_ok=True)
    for source in sources:
        suffix = source.suffix.lower()
        if suffix not in VIDEO_SUFFIXES:
            raise gr.Error(f"Unsupported video type: {source.name}")
        shutil.copy2(source, inbox / f"{time.time_ns()}-{uuid.uuid4().hex[:6]}{suffix}")
    return session_id, None, f"Queued {len(sources)} new clip(s); the next tick will stitch them."


def _scene_points(path: Path):
    scene = trimesh.load(path, force="scene")
    vertices, colors = [], []
    for geometry in scene.geometry.values():
        vertices.append(np.asarray(geometry.vertices))
        vertex_colors = getattr(geometry.visual, "vertex_colors", None)
        if vertex_colors is None or len(vertex_colors) != len(geometry.vertices):
            vertex_colors = np.full((len(geometry.vertices), 4), 255, dtype=np.uint8)
        colors.append(np.asarray(vertex_colors, dtype=np.uint8))
    if not vertices:
        raise gr.Error(f"No point geometry found in {path.name}")
    return np.concatenate(vertices), np.concatenate(colors)


def _merge_increment(existing: Path, addition: Path, destination: Path):
    """Similarity-ICP align an overlapping increment, then append its points."""
    old_points, old_colors = _scene_points(existing)
    new_points, new_colors = _scene_points(addition)
    rng = np.random.default_rng(0)
    old_sample = old_points[rng.choice(len(old_points), min(20_000, len(old_points)), replace=False)]
    new_sample = new_points[rng.choice(len(new_points), min(20_000, len(new_points)), replace=False)]
    old_extent = np.linalg.norm(np.ptp(old_sample, axis=0))
    new_extent = np.linalg.norm(np.ptp(new_sample, axis=0))
    scale = old_extent / new_extent if new_extent > 1e-8 else 1.0
    initial = np.eye(4)
    initial[:3, :3] *= scale
    initial[:3, 3] = old_sample.mean(axis=0) - scale * new_sample.mean(axis=0)
    matrix, _, cost = trimesh.registration.icp(
        new_sample, old_sample, initial=initial, max_iterations=30,
        scale=True, reflection=False)
    aligned = trimesh.transform_points(new_points, matrix)
    merged = trimesh.points.PointCloud(
        np.concatenate([old_points, aligned]), colors=np.concatenate([old_colors, new_colors]))
    temporary = destination.with_suffix(".tmp.glb")
    merged.export(temporary)
    temporary.replace(destination)
    return float(cost)


def update_live_twin(session_id, seconds_between_frames, max_frames,
                     confidence_percentile, as_mesh):
    """Jointly rebuild the scene only when the session has received new clips."""
    if not session_id:
        return gr.skip(), gr.skip(), "Upload clips to start a live session."
    session = _session_dir(session_id)
    videos = sorted(p for p in (session / "videos").glob("*")
                    if p.suffix.lower() in VIDEO_SUFFIXES)
    if not videos:
        return gr.skip(), gr.skip(), "Waiting for video clips."
    processed_path = session / "processed_videos.json"
    processed = set(json.loads(processed_path.read_text())) if processed_path.exists() else set()
    new_videos = [video for video in videos if video.name not in processed]
    if not new_videos:
        return gr.skip(), gr.skip(), f"Up to date: {len(videos)} clip(s). Checking every {UPDATE_SECONDS:g}s."
    increment = session / f"increment-{uuid.uuid4().hex[:8]}"
    frames = _extract_to_directory(new_videos, increment / "images",
                                   seconds_between_frames, max_frames)
    addition, _, result = reconstruct(str(increment / "images"), confidence_percentile, as_mesh)
    destination = OUTPUTS / f"live-{session_id}.glb"
    if destination.exists():
        cost = _merge_increment(destination, Path(addition), destination)
        alignment = f" ICP alignment cost: {cost:.5g}."
    else:
        shutil.copy2(addition, destination)
        alignment = " Initialized the twin."
    processed.update(video.name for video in new_videos)
    processed_path.write_text(json.dumps(sorted(processed)))
    return str(destination), str(destination), (
        f"{result} Added {len(new_videos)} new clip(s) / {len(frames)} frames without "
        f"reprocessing earlier clips.{alignment}")


existing_outputs = sorted(OUTPUTS.glob("reconstruction-*.glb"), key=lambda p: p.stat().st_mtime)
existing_scene = str(existing_outputs[-1]) if existing_outputs else None

with gr.Blocks(title="Live digital twin · MapAnything") as demo:
    gr.Markdown("# Phone videos → live digital twin\nUpload overlapping clips. MapAnything "
                f"jointly reconstructs all accumulated clips and checks every **{UPDATE_SECONDS:g} seconds**.")
    session_state = gr.State("")
    with gr.Tab("Live incremental twin"):
        live_videos = gr.File(label="New overlapping video clips", file_count="multiple",
                              file_types=["video"], type="filepath")
        add_clips = gr.Button("Add clips to live twin", variant="primary")
        live_status = gr.Markdown("Upload clips to start a live session.")
        with gr.Row():
            live_interval = gr.Slider(0.25, 5, value=1.5, step=0.25, label="Seconds between frames")
            live_max_frames = gr.Slider(2, 200, value=40, step=1, label="Max frames per clip")
        with gr.Row():
            live_confidence = gr.Slider(0, 50, value=10, step=1, label="Filter lowest-confidence %")
            live_mesh = gr.Checkbox(value=False, label="Connect points as mesh")
        live_viewer = gr.Model3D(value=existing_scene, label="Updating digital twin", height=650)
        live_download = gr.File(value=existing_scene, label="Download latest GLB")
        timer = gr.Timer(value=UPDATE_SECONDS, active=True)
        add_clips.click(add_live_videos, [session_state, live_videos],
                        [session_state, live_videos, live_status])
        timer.tick(update_live_twin,
                   [session_state, live_interval, live_max_frames, live_confidence, live_mesh],
                   [live_viewer, live_download, live_status], concurrency_limit=1,
                   concurrency_id="reconstruction")

    with gr.Tab("One-shot reconstruction"):
        state = gr.State()
        videos = gr.File(label="Videos", file_count="multiple", file_types=["video"], type="filepath")
        with gr.Row():
            interval = gr.Slider(0.25, 5, value=1.5, step=0.25, label="Seconds between frames")
            max_frames = gr.Slider(2, 200, value=40, step=1, label="Max frames per video")
        extract = gr.Button("1 · Extract and preview frames", variant="secondary")
        gallery = gr.Gallery(label="Selected frames", columns=6, height=320)
        with gr.Row():
            confidence = gr.Slider(0, 50, value=10, step=1, label="Filter lowest-confidence %")
            mesh = gr.Checkbox(value=False, label="Connect points as mesh")
        run = gr.Button("2 · Reconstruct 3D scene", variant="primary")
        status = gr.Markdown()
        viewer = gr.Model3D(value=existing_scene, label="Interactive reconstruction", height=650)
        download = gr.File(value=existing_scene, label="Download GLB")
        extract.click(extract_frames, [videos, interval, max_frames], [state, gallery, status])
        run.click(reconstruct, [state, confidence, mesh], [viewer, download, status],
                  concurrency_limit=1, concurrency_id="reconstruction")

if __name__ == "__main__":
    username = os.getenv("GRADIO_USERNAME")
    password = os.getenv("GRADIO_PASSWORD")
    auth = (username, password) if username and password else None
    demo.queue(default_concurrency_limit=1).launch(
        server_name=os.getenv("HOST", "0.0.0.0"), server_port=int(os.getenv("PORT", "7860")),
        show_error=True, share=False, auth=auth)
