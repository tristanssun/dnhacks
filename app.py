"""Open-source multi-video UI for MapAnything reconstruction."""

from __future__ import annotations

import os
import shutil
import uuid
from pathlib import Path

os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")

import cv2
import gradio as gr
import numpy as np
import torch

from mapanything.models import MapAnything
from mapanything.utils.geometry import depthmap_to_world_frame
from mapanything.utils.image import load_images
from mapanything.utils.viz import predictions_to_glb

ROOT = Path(__file__).resolve().parent
UPLOADS = ROOT / "uploads"
OUTPUTS = ROOT / "outputs"
MODEL_ID = os.getenv("MAPANYTHING_MODEL", "facebook/map-anything-apache")
MODEL = None


def _paths(files) -> list[Path]:
    if not files:
        return []
    result = []
    for item in files:
        value = item.get("name") if isinstance(item, dict) else item
        result.append(Path(value))
    return result


def extract_frames(files, seconds_between_frames: float, max_frames: int):
    """Extract evenly spaced frames from every uploaded video."""
    sources = _paths(files)
    if not sources:
        raise gr.Error("Upload at least one video.")
    job = uuid.uuid4().hex[:12]
    frame_dir = UPLOADS / job / "images"
    frame_dir.mkdir(parents=True)
    frames: list[str] = []
    for video_index, source in enumerate(sources):
        capture = cv2.VideoCapture(str(source))
        fps = capture.get(cv2.CAP_PROP_FPS)
        if not capture.isOpened() or fps <= 0:
            raise gr.Error(f"Could not decode {source.name}")
        step = max(1, round(fps * seconds_between_frames))
        frame_number = selected = 0
        while selected < max_frames:
            ok, frame = capture.read()
            if not ok:
                break
            if frame_number % step == 0:
                destination = frame_dir / f"v{video_index:02d}_f{frame_number:08d}.jpg"
                cv2.imwrite(str(destination), frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
                frames.append(str(destination))
                selected += 1
            frame_number += 1
        capture.release()
    if len(frames) < 2:
        shutil.rmtree(frame_dir.parent, ignore_errors=True)
        raise gr.Error("At least two frames are required.")
    message = f"Prepared {len(frames)} frames from {len(sources)} videos."
    return str(frame_dir), frames, message


def reconstruct(frame_dir: str, confidence_percentile: float, as_mesh: bool):
    global MODEL
    if not frame_dir or not Path(frame_dir).is_dir():
        raise gr.Error("Extract frames first.")
    if not torch.cuda.is_available():
        raise gr.Error("CUDA is required. Launch this app with scripts/submit_gpu.sh.")
    device = torch.device("cuda")
    if MODEL is None:
        MODEL = MapAnything.from_pretrained(MODEL_ID).to(device).eval()
    views = load_images(frame_dir)
    with torch.inference_mode():
        outputs = MODEL.infer(
            views,
            memory_efficient_inference=True,
            minibatch_size=1,
            use_amp=True,
            amp_dtype="bf16",
            apply_mask=True,
            mask_edges=True,
        )
    points, images, masks = [], [], []
    for prediction in outputs:
        depth = prediction["depth_z"][0].squeeze(-1)
        xyz, valid = depthmap_to_world_frame(
            depth, prediction["intrinsics"][0], prediction["camera_poses"][0]
        )
        mask = prediction["mask"][0].squeeze(-1).bool() & valid
        confidence = prediction["conf"][0].squeeze(-1)
        valid_confidence = confidence[mask]
        if valid_confidence.numel() and confidence_percentile > 0:
            threshold = torch.quantile(
                valid_confidence.float(), confidence_percentile / 100.0
            )
            mask &= confidence >= threshold
        points.append(xyz.cpu().numpy())
        images.append(prediction["img_no_norm"][0].cpu().numpy())
        masks.append(mask.cpu().numpy())
    scene_data = {
        "world_points": np.stack(points),
        "images": np.stack(images),
        "final_masks": np.stack(masks),
    }
    scene = predictions_to_glb(scene_data, as_mesh=as_mesh)
    OUTPUTS.mkdir(parents=True, exist_ok=True)
    output = OUTPUTS / f"reconstruction-{Path(frame_dir).parent.name}.glb"
    scene.export(output)
    return str(output), str(output), f"Complete: {len(views)} views reconstructed."


existing_outputs = sorted(OUTPUTS.glob("reconstruction-*.glb"))
existing_scene = str(existing_outputs[-1]) if existing_outputs else None

with gr.Blocks(title="Phone videos to 3D · MapAnything") as demo:
    gr.Markdown(
        "# Phone videos → interactive 3D\n"
        "Upload overlapping videos of one scene. Frames stay on this machine and the "
        "Apache-licensed MapAnything checkpoint reconstructs a metric 3D scene."
    )
    state = gr.State()
    videos = gr.File(
        label="Videos", file_count="multiple", file_types=["video"], type="filepath"
    )
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
    run.click(reconstruct, [state, confidence, mesh], [viewer, download, status])


if __name__ == "__main__":
    demo.queue(default_concurrency_limit=1).launch(
        server_name=os.getenv("HOST", "0.0.0.0"),
        server_port=int(os.getenv("PORT", "7860")),
        show_error=True,
    )
