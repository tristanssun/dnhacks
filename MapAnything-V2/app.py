"""Multi-viewpoint MapAnything world builder and web UI."""
from __future__ import annotations

import json
import os
import shutil
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

os.environ.setdefault("PYTORCH_CUDA_ALLOC_CONF", "expandable_segments:True")

import cv2
import numpy as np
import trimesh

try:
    import torch
except ImportError:
    torch = None


class ReconstructionError(Exception):
    """User-facing reconstruction or ingest failure."""


class _GradioShim:
    Error = ReconstructionError

    @staticmethod
    def skip():
        return None


gr = _GradioShim()

ROOT = Path(__file__).resolve().parent
DATA_ROOT = Path(os.getenv("DATA_ROOT", ROOT))
UPLOADS = DATA_ROOT / "uploads"
LIVE = DATA_ROOT / "live_sessions"
OUTPUTS = DATA_ROOT / "outputs"
STATIC = ROOT / "static"
MODEL_ID = os.getenv("MAPANYTHING_MODEL", "facebook/map-anything-apache")
UPDATE_SECONDS = float(os.getenv("TWIN_UPDATE_SECONDS", "10"))
VIDEO_SUFFIXES = {".avi", ".m4v", ".mkv", ".mov", ".mp4", ".webm"}
IMAGE_SUFFIXES = {".bmp", ".jpeg", ".jpg", ".png", ".tif", ".tiff", ".webp"}
IMAGE_LOAD_SUFFIXES = {".jpg", ".jpeg", ".png"}
OVERLAP_FRAMES = 8
DEFAULT_SETTINGS = {
    "seconds_between_frames": 1.5,
    "max_frames": 40,
    "confidence_percentile": 10,
    "as_mesh": False,
}
MODEL = None
MODEL_LOCK = threading.Lock()
WORKERS: dict[str, threading.Thread] = {}
WORKER_GUARD = threading.Lock()


def _iso_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _paths(files) -> list[Path]:
    if not files:
        return []
    return [Path(item.get("name") if isinstance(item, dict) else item) for item in files]


def _read_json_set(path: Path) -> set[str]:
    return set(json.loads(path.read_text())) if path.exists() else set()


def _write_json(path: Path, payload) -> None:
    path.write_text(json.dumps(sorted(payload) if isinstance(payload, set) else payload))


def _safe_id(session_id: str) -> str:
    safe_id = Path(session_id or "").name
    if not safe_id or safe_id != session_id:
        raise gr.Error("Start a world first.")
    return safe_id


def _session_dir(session_id: str) -> Path:
    return LIVE / _safe_id(session_id)


def _world_path(session: Path) -> Path:
    return session / "world.json"


def _empty_world(session_id: str) -> dict:
    return {
        "id": session_id,
        "created_at": _iso_now(),
        "updated_at": _iso_now(),
        "status": "idle",
        "message": "Upload photos or videos from any viewpoint. The model will place them.",
        "updates": 0,
        "settings": dict(DEFAULT_SETTINGS),
        "sources": [],
    }


def _load_world(session: Path) -> dict:
    path = _world_path(session)
    if not path.exists():
        return _empty_world(session.name)
    world = json.loads(path.read_text())
    world.setdefault("settings", dict(DEFAULT_SETTINGS))
    world.setdefault("sources", [])
    return world


def _save_world(session: Path, world: dict) -> None:
    session.mkdir(parents=True, exist_ok=True)
    world["updated_at"] = _iso_now()
    _world_path(session).write_text(json.dumps(world, indent=2))


def _write_thumbnail(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.suffix.lower() in VIDEO_SUFFIXES:
        capture = cv2.VideoCapture(str(source))
        ok, frame = capture.read()
        capture.release()
        if not ok or frame is None:
            return
    else:
        frame = cv2.imread(str(source))
        if frame is None:
            return
    height, width = frame.shape[:2]
    scale = 240 / max(height, width)
    if scale < 1:
        frame = cv2.resize(frame, (max(1, int(width * scale)), max(1, int(height * scale))))
    cv2.imwrite(str(destination), frame, [cv2.IMWRITE_JPEG_QUALITY, 84])


def _new_source(stored: Path, original_name: str, kind: str) -> dict:
    source_id = uuid.uuid4().hex[:8]
    thumb = stored.parent.parent / "thumbs" / f"{source_id}.jpg"
    _write_thumbnail(stored, thumb)
    return {
        "id": source_id,
        "filename": Path(original_name).name,
        "stored_as": stored.name,
        "kind": kind,
        "status": "queued",
        "error": None,
        "queued_at": _iso_now(),
        "localized_at": None,
        "view_count": 0,
        "thumbnail": f"thumbs/{source_id}.jpg" if thumb.is_file() else None,
        "position": None,
        "forward": None,
        "cameras": [],
    }


def _register_sources(session: Path, items: list[tuple[Path, str, str]]) -> list[dict]:
    world = _load_world(session)
    known = {source["stored_as"] for source in world["sources"]}
    created = []
    for stored, original_name, kind in items:
        if stored.name in known:
            continue
        record = _new_source(stored, original_name, kind)
        world["sources"].append(record)
        created.append(record)
    if created:
        world["message"] = (
            f"Queued {len(created)} new source(s). The model will estimate each location "
            "and fuse the geometry into the world."
        )
        _save_world(session, world)
    return created


def _ensure_world(session: Path) -> dict:
    world = _load_world(session)
    videos, photos = _session_media(session)
    known = {source["stored_as"] for source in world["sources"]}
    extras = (
        [(video, video.name, "video") for video in videos if video.name not in known]
        + [(photo, photo.name, "photo") for photo in photos if photo.name not in known]
    )
    if extras:
        _register_sources(session, extras)
        world = _load_world(session)
    else:
        session.mkdir(parents=True, exist_ok=True)
        if not _world_path(session).exists():
            _save_world(session, world)
    return world


def _source_id_for_file(world: dict, path: Path) -> str | None:
    for source in world.get("sources", []):
        if source.get("stored_as") == path.name:
            return source["id"]
    return None


def _update_settings(session: Path, settings: dict) -> dict:
    world = _ensure_world(session)
    merged = dict(world.get("settings") or DEFAULT_SETTINGS)
    if "seconds_between_frames" in settings and settings["seconds_between_frames"] is not None:
        merged["seconds_between_frames"] = float(settings["seconds_between_frames"])
    if "max_frames" in settings and settings["max_frames"] is not None:
        merged["max_frames"] = int(settings["max_frames"])
    if "confidence_percentile" in settings and settings["confidence_percentile"] is not None:
        merged["confidence_percentile"] = float(settings["confidence_percentile"])
    if "as_mesh" in settings and settings["as_mesh"] is not None:
        merged["as_mesh"] = bool(settings["as_mesh"])
    world["settings"] = merged
    _save_world(session, world)
    return merged


def _normalize_photo(source: Path, dest_dir: Path, prefix: str) -> Path:
    suffix = source.suffix.lower()
    if suffix not in IMAGE_SUFFIXES:
        raise gr.Error(
            f"Unsupported photo type: {source.name}. Use JPEG, PNG, WebP, BMP, or TIFF."
        )
    image = cv2.imread(str(source))
    if image is None:
        raise gr.Error(f"Could not read photo {source.name}. Use JPEG or PNG.")
    dest_dir.mkdir(parents=True, exist_ok=True)
    destination = dest_dir / f"{prefix}-{uuid.uuid4().hex[:6]}.jpg"
    cv2.imwrite(str(destination), image, [cv2.IMWRITE_JPEG_QUALITY, 92])
    return destination


def _copy_photos(sources, dest_dir: Path, prefix: str = "gap") -> list[Path]:
    return [
        _normalize_photo(source, dest_dir, f"{prefix}_{index:04d}")
        for index, source in enumerate(sources)
    ]


def _extract_to_directory(sources, frame_dir, seconds_between_frames, max_frames,
                          min_frames=2, prefixes=None):
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
            tag = None
            if prefixes and video_index < len(prefixes) and prefixes[video_index]:
                tag = prefixes[video_index]
            while selected < max_frames:
                ok, frame = capture.read()
                if not ok:
                    break
                if frame_number % step == 0:
                    name = (
                        f"{tag}_f{frame_number:08d}.jpg"
                        if tag
                        else f"v{video_index:03d}_f{frame_number:08d}.jpg"
                    )
                    destination = staging / name
                    cv2.imwrite(str(destination), frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
                    frames.append(destination)
                    selected += 1
                frame_number += 1
            capture.release()
        if len(frames) < min_frames:
            raise gr.Error("At least two frames are required.")
        shutil.rmtree(frame_dir, ignore_errors=True)
        staging.rename(frame_dir)
        return [str(frame_dir / frame.name) for frame in frames]
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def extract_frames(files, seconds_between_frames: float, max_frames: int, photos=None):
    sources = _paths(files)
    extras = _paths(photos)
    if not sources:
        raise gr.Error("Upload at least one video.")
    frame_dir = UPLOADS / uuid.uuid4().hex[:12] / "images"
    frames = _extract_to_directory(sources, frame_dir, seconds_between_frames, max_frames)
    photo_files = _copy_photos(extras, Path(frame_dir), prefix="gap")
    all_frames = frames + [str(path) for path in photo_files]
    summary = f"Prepared {len(frames)} frames from {len(sources)} videos"
    if photo_files:
        summary += f" and {len(photo_files)} gap photos"
    return str(frame_dir), all_frames, f"{summary}."


def _view_filenames(frame_dir: Path) -> list[str]:
    return sorted(
        path.name
        for path in frame_dir.iterdir()
        if path.is_file() and path.suffix.lower() in IMAGE_LOAD_SUFFIXES
    )


def _pose_record(name: str, pose: np.ndarray) -> dict:
    matrix = np.asarray(pose, dtype=float)
    if matrix.ndim == 3:
        matrix = matrix[0]
    return {
        "name": name,
        "matrix": matrix.tolist(),
        "position": matrix[:3, 3].tolist(),
        "forward": matrix[:3, 2].tolist(),
    }


def _write_poses(frame_dir: Path, records: list[dict]) -> None:
    (frame_dir.parent / "poses.json").write_text(json.dumps(records))


def _mock_reconstruct(frame_dir: str, as_mesh: bool):
    """CPU stand-in used when MAPANYTHING_MOCK=1 so the UI can be exercised without a GPU."""
    image_dir = Path(frame_dir)
    names = _view_filenames(image_dir)
    rng = np.random.default_rng(abs(hash(image_dir.parent.name)) % (2**32))
    grid = np.stack(
        np.meshgrid(np.linspace(0, 2, 10), np.linspace(0, 2, 10), np.linspace(0, 1, 5)),
        axis=-1,
    ).reshape(-1, 3)
    extra_center = rng.uniform(-0.15, 2.15, 3)
    extra = extra_center + rng.normal(0, 0.16, (max(90, 36 * max(len(names), 1)), 3))
    points = np.concatenate([grid, extra])
    colors = np.concatenate(
        [
            np.full((len(grid), 4), [168, 174, 182, 255], dtype=np.uint8),
            np.column_stack(
                [rng.integers(70, 235, (len(extra), 3)), np.full((len(extra), 1), 255)]
            ).astype(np.uint8),
        ]
    )
    cloud = trimesh.points.PointCloud(points, colors=colors)
    OUTPUTS.mkdir(parents=True, exist_ok=True)
    output = OUTPUTS / f"reconstruction-{image_dir.parent.name}.glb"
    temporary = output.with_suffix(".tmp.glb")
    cloud.export(temporary)
    temporary.replace(output)
    poses = []
    center = np.array([1.0, 1.0, 0.45])
    for index, name in enumerate(names):
        angle = index * 0.37
        position = np.array(
            [1.0 + 1.35 * np.cos(angle), 1.0 + 1.35 * np.sin(angle), 1.15]
        )
        forward = center - position
        forward = forward / (np.linalg.norm(forward) + 1e-8)
        right = np.cross(np.array([0.0, 0.0, 1.0]), forward)
        if np.linalg.norm(right) < 1e-6:
            right = np.cross(np.array([0.0, 1.0, 0.0]), forward)
        right = right / (np.linalg.norm(right) + 1e-8)
        down = np.cross(forward, right)
        matrix = np.eye(4)
        matrix[:3, 0] = right
        matrix[:3, 1] = down
        matrix[:3, 2] = forward
        matrix[:3, 3] = position
        poses.append(_pose_record(name, matrix))
    _write_poses(image_dir, poses)
    _ = as_mesh
    return str(output), str(output), f"Complete: {len(names)} views reconstructed."


def reconstruct(frame_dir: str, confidence_percentile: float, as_mesh: bool):
    global MODEL
    if not frame_dir or not Path(frame_dir).is_dir():
        raise gr.Error("Extract frames first.")
    if os.getenv("MAPANYTHING_MOCK"):
        return _mock_reconstruct(frame_dir, as_mesh)
    if torch is None or not torch.cuda.is_available():
        raise gr.Error("CUDA is required. Launch this app with scripts/submit_gpu.sh.")
    from mapanything.models import MapAnything
    from mapanything.utils.geometry import depthmap_to_world_frame
    from mapanything.utils.image import load_images
    from mapanything.utils.viz import predictions_to_glb

    device = torch.device("cuda")
    with MODEL_LOCK, torch.inference_mode():
        if MODEL is None:
            MODEL = MapAnything.from_pretrained(MODEL_ID).to(device).eval()
        views = load_images(frame_dir)
        outputs = MODEL.infer(
            views,
            memory_efficient_inference=True,
            minibatch_size=1,
            use_amp=True,
            amp_dtype="bf16",
            apply_mask=True,
            mask_edges=True,
        )
    points, images, masks, poses = [], [], [], []
    view_names = _view_filenames(Path(frame_dir))
    for index, prediction in enumerate(outputs):
        depth = prediction["depth_z"][0].squeeze(-1)
        xyz, valid = depthmap_to_world_frame(
            depth, prediction["intrinsics"][0], prediction["camera_poses"][0]
        )
        mask = prediction["mask"][0].squeeze(-1).bool() & valid
        confidence = prediction["conf"][0].squeeze(-1)
        valid_confidence = confidence[mask]
        if valid_confidence.numel() and confidence_percentile > 0:
            threshold = torch.quantile(valid_confidence.float(), confidence_percentile / 100.0)
            mask &= confidence >= threshold
        points.append(xyz.cpu().numpy())
        images.append(prediction["img_no_norm"][0].cpu().numpy())
        masks.append(mask.cpu().numpy())
        pose = prediction["camera_poses"][0].detach().cpu().numpy()
        name = view_names[index] if index < len(view_names) else f"view_{index:03d}"
        poses.append(_pose_record(name, pose))
    scene = predictions_to_glb(
        {
            "world_points": np.stack(points),
            "images": np.stack(images),
            "final_masks": np.stack(masks),
        },
        as_mesh=as_mesh,
    )
    OUTPUTS.mkdir(parents=True, exist_ok=True)
    output = OUTPUTS / f"reconstruction-{Path(frame_dir).parent.name}.glb"
    temporary = output.with_suffix(".tmp.glb")
    scene.export(temporary)
    temporary.replace(output)
    _write_poses(Path(frame_dir), poses)
    return str(output), str(output), f"Complete: {len(views)} views reconstructed."


def _queue_videos(session: Path, sources) -> list[Path]:
    inbox = session / "videos"
    inbox.mkdir(parents=True, exist_ok=True)
    queued = []
    for source in sources:
        suffix = source.suffix.lower()
        if suffix not in VIDEO_SUFFIXES:
            raise gr.Error(f"Unsupported video type: {source.name}")
        destination = inbox / f"{time.time_ns()}-{uuid.uuid4().hex[:6]}{suffix}"
        shutil.copy2(source, destination)
        queued.append(destination)
    return queued


def _queue_photos(session: Path, sources) -> list[Path]:
    return [
        _normalize_photo(source, session / "photos", f"{time.time_ns()}")
        for source in sources
    ]


def _session_media(session: Path):
    videos = (
        sorted(
            path
            for path in (session / "videos").glob("*")
            if path.suffix.lower() in VIDEO_SUFFIXES
        )
        if (session / "videos").is_dir()
        else []
    )
    photos = (
        sorted(
            path
            for path in (session / "photos").glob("*")
            if path.suffix.lower() in IMAGE_SUFFIXES
        )
        if (session / "photos").is_dir()
        else []
    )
    return videos, photos


def _seed_overlap_frames(session: Path, dest_dir: Path) -> list[Path]:
    """Copy a few already-reconstructed views so new stills can register."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    increments = sorted(
        (path for path in session.glob("increment-*/images") if path.is_dir()),
        key=lambda path: path.stat().st_mtime,
    )
    if not increments:
        return []
    candidates = [
        path
        for path in sorted(increments[-1].iterdir())
        if path.is_file() and not path.name.startswith("overlap_")
    ] or [path for path in sorted(increments[-1].iterdir()) if path.is_file()]
    if not candidates:
        return []
    if len(candidates) <= OVERLAP_FRAMES:
        selected = candidates
    else:
        step = len(candidates) / OVERLAP_FRAMES
        selected = [candidates[int(index * step)] for index in range(OVERLAP_FRAMES)]
    copied = []
    for image in selected:
        destination = dest_dir / f"overlap_{image.name}"
        shutil.copy2(image, destination)
        copied.append(destination)
    return copied


def add_live_videos(session_id: str, files):
    sources = _paths(files)
    if not sources:
        raise gr.Error("Choose one or more video clips.")
    session_id = session_id or uuid.uuid4().hex[:12]
    session = _session_dir(session_id)
    queued = _queue_videos(session, sources)
    _register_sources(session, [(dest, src.name, "video") for dest, src in zip(queued, sources)])
    return session_id, None, f"Queued {len(sources)} new clip(s); the next tick will stitch them."


def add_live_photos(session_id: str, files):
    sources = _paths(files)
    if not session_id:
        raise gr.Error("Build a twin from a starter video first.")
    if not sources:
        raise gr.Error("Choose one or more still photos of the missing areas.")
    session = _session_dir(session_id)
    queued = _queue_photos(session, sources)
    _register_sources(session, [(dest, src.name, "photo") for dest, src in zip(queued, sources)])
    return None, f"Queued {len(sources)} gap photo(s); the next tick will stitch them."


def ingest_paths(session_id: str, items: list[tuple[Path, str]], settings=None) -> str:
    """Queue mixed photos and videos. The first batch can be photos, videos, or both."""
    if not items:
        raise gr.Error("Upload at least one photo or video.")
    session_id = session_id or uuid.uuid4().hex[:12]
    session = _session_dir(session_id)
    videos = [(path, name) for path, name in items if Path(name).suffix.lower() in VIDEO_SUFFIXES
              or path.suffix.lower() in VIDEO_SUFFIXES]
    photos = [(path, name) for path, name in items if Path(name).suffix.lower() in IMAGE_SUFFIXES
              or path.suffix.lower() in IMAGE_SUFFIXES]
    classified = {id(path) for path, _ in videos + photos}
    unknown = [name for path, name in items if id(path) not in classified]
    if unknown:
        raise gr.Error(
            f"Unsupported file type: {unknown[0]}. Use photos (JPEG, PNG, WebP, TIFF, BMP) "
            "or videos (MP4, MOV, WebM, MKV, AVI)."
        )
    queued = []
    if videos:
        stored = _queue_videos(session, [path for path, _ in videos])
        queued.extend((dest, name, "video") for dest, (_, name) in zip(stored, videos))
    if photos:
        stored = _queue_photos(session, [path for path, _ in photos])
        queued.extend((dest, name, "photo") for dest, (_, name) in zip(stored, photos))
    _register_sources(session, queued)
    if settings:
        _update_settings(session, settings)
    return session_id


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
    return float(cost), np.asarray(matrix, dtype=float)


def _transform_poses(poses: list[dict], matrix: np.ndarray) -> list[dict]:
    transformed = []
    for pose in poses:
        aligned = matrix @ np.asarray(pose["matrix"], dtype=float)
        transformed.append(_pose_record(pose["name"], aligned))
    return transformed


def _assign_localizations(session: Path, new_files: list[Path], poses: list[dict],
                          matrix: np.ndarray | None) -> None:
    world = _ensure_world(session)
    if matrix is not None and poses:
        poses = _transform_poses(poses, matrix)
    new_names = {path.name for path in new_files}
    for source in world["sources"]:
        if source["stored_as"] not in new_names:
            continue
        cameras = [pose for pose in poses if pose["name"].startswith(f"{source['id']}_")]
        source["status"] = "localized"
        source["error"] = None
        source["localized_at"] = _iso_now()
        if cameras:
            positions = np.array([camera["position"] for camera in cameras], dtype=float)
            forwards = np.array([camera["forward"] for camera in cameras], dtype=float)
            source["position"] = positions.mean(axis=0).tolist()
            mean_forward = forwards.mean(axis=0)
            norm = np.linalg.norm(mean_forward)
            source["forward"] = (mean_forward / norm).tolist() if norm > 1e-8 else [0.0, 0.0, 1.0]
            source["view_count"] = len(cameras)
            source["cameras"] = [
                {"position": camera["position"], "forward": camera["forward"]}
                for camera in cameras
            ]
    world["updates"] = int(world.get("updates") or 0) + 1
    world["status"] = "idle"
    _save_world(session, world)


def _mark_sources(session: Path, files: list[Path], status: str, error: str | None = None,
                  message: str | None = None) -> None:
    world = _ensure_world(session)
    names = {path.name for path in files}
    for source in world["sources"]:
        if source["stored_as"] in names:
            source["status"] = status
            source["error"] = error
    if message is not None:
        world["message"] = message
        world["status"] = "error" if status == "failed" else world.get("status", "idle")
    _save_world(session, world)


def update_live_twin(session_id, seconds_between_frames, max_frames,
                     confidence_percentile, as_mesh):
    """Rebuild only when the session has received new clips or gap photos."""
    if not session_id:
        return gr.skip(), gr.skip(), "Upload photos or videos to begin."
    session = _session_dir(session_id)
    videos, photos = _session_media(session)
    processed_videos = _read_json_set(session / "processed_videos.json")
    processed_photos = _read_json_set(session / "processed_photos.json")
    new_videos = [video for video in videos if video.name not in processed_videos]
    new_photos = [photo for photo in photos if photo.name not in processed_photos]
    if not new_videos and not new_photos:
        if not videos and not photos:
            return gr.skip(), gr.skip(), "Waiting for photos or videos."
        return gr.skip(), gr.skip(), (
            f"Up to date: {len(videos)} clip(s) and {len(photos)} photo(s). "
            f"Checking every {UPDATE_SECONDS:g}s."
        )
    world = _ensure_world(session)
    _mark_sources(
        session,
        new_videos + new_photos,
        "processing",
        message="Localizing new viewpoints and fusing them into the world.",
    )
    world = _load_world(session)
    world["status"] = "processing"
    _save_world(session, world)
    increment = session / f"increment-{uuid.uuid4().hex[:8]}"
    image_dir = increment / "images"
    destination = OUTPUTS / f"live-{session_id}.glb"
    try:
        if new_videos:
            prefixes = [_source_id_for_file(world, video) for video in new_videos]
            _extract_to_directory(
                new_videos, image_dir, seconds_between_frames, max_frames,
                min_frames=0, prefixes=prefixes,
            )
        else:
            image_dir.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                _seed_overlap_frames(session, image_dir)
        for index, photo in enumerate(new_photos):
            source_id = _source_id_for_file(world, photo)
            prefix = f"{source_id}_still" if source_id else f"gap_{index:04d}"
            _normalize_photo(photo, image_dir, prefix)
        view_paths = [
            path for path in image_dir.iterdir() if path.is_file()
        ] if image_dir.is_dir() else []
        if len(view_paths) < 2:
            shutil.rmtree(increment, ignore_errors=True)
            raise gr.Error(
                "Need at least two views. Upload a longer video, more photos, or another viewpoint."
            )
        addition, _, result = reconstruct(str(image_dir), confidence_percentile, as_mesh)
        poses_path = increment / "poses.json"
        poses = json.loads(poses_path.read_text()) if poses_path.exists() else []
        matrix = None
        OUTPUTS.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            cost, matrix = _merge_increment(destination, Path(addition), destination)
            alignment = f" ICP alignment cost: {cost:.5g}."
        else:
            shutil.copy2(addition, destination)
            alignment = " Initialized the twin."
        processed_videos.update(video.name for video in new_videos)
        processed_photos.update(photo.name for photo in new_photos)
        _write_json(session / "processed_videos.json", processed_videos)
        _write_json(session / "processed_photos.json", processed_photos)
        _assign_localizations(session, new_videos + new_photos, poses, matrix)
        added = " and ".join(
            part for part in (
                f"{len(new_videos)} new clip(s)" if new_videos else "",
                f"{len(new_photos)} gap photo(s)" if new_photos else "",
            ) if part
        )
        status = (
            f"{result} Added {added} / {len(view_paths)} frames without "
            f"reprocessing earlier clips.{alignment}"
        )
        world = _load_world(session)
        world["status"] = "idle"
        world["message"] = status
        _save_world(session, world)
        return str(destination), str(destination), status
    except Exception as exc:
        _mark_sources(
            session,
            new_videos + new_photos,
            "failed",
            error=str(exc),
            message=str(exc),
        )
        raise


def build_starter_twin(session_id, videos, photos, seconds_between_frames, max_frames,
                       confidence_percentile, as_mesh):
    sources = _paths(videos)
    extras = _paths(photos)
    if not sources:
        raise gr.Error("Upload a starter video of the space.")
    session_id = session_id or uuid.uuid4().hex[:12]
    session = _session_dir(session_id)
    queued = _queue_videos(session, sources)
    _register_sources(session, [(dest, src.name, "video") for dest, src in zip(queued, sources)])
    if extras:
        queued_photos = _queue_photos(session, extras)
        _register_sources(
            session, [(dest, src.name, "photo") for dest, src in zip(queued_photos, extras)]
        )
    viewer, download, status = update_live_twin(
        session_id, seconds_between_frames, max_frames, confidence_percentile, as_mesh
    )
    return session_id, None, None, viewer, download, status


def add_gap_photos(session_id, photos, seconds_between_frames, max_frames,
                   confidence_percentile, as_mesh):
    extras = _paths(photos)
    if not session_id:
        raise gr.Error("Build a twin from a starter video first.")
    if not extras:
        raise gr.Error("Choose one or more still photos of the missing areas.")
    session = _session_dir(session_id)
    queued = _queue_photos(session, extras)
    _register_sources(session, [(dest, src.name, "photo") for dest, src in zip(queued, extras)])
    viewer, download, status = update_live_twin(
        session_id, seconds_between_frames, max_frames, confidence_percentile, as_mesh
    )
    return None, viewer, download, status


def _glb_path(session_id: str) -> Path:
    return OUTPUTS / f"live-{_safe_id(session_id)}.glb"


def _public_source(session_id: str, source: dict) -> dict:
    payload = dict(source)
    if source.get("thumbnail"):
        payload["thumbnail_url"] = f"/api/worlds/{session_id}/{source['thumbnail']}"
    return payload


def public_world(session_id: str) -> dict:
    session = _session_dir(session_id)
    world = _ensure_world(session)
    glb = _glb_path(session_id)
    videos = [source for source in world["sources"] if source["kind"] == "video"]
    photos = [source for source in world["sources"] if source["kind"] == "photo"]
    localized = [source for source in world["sources"] if source["status"] == "localized"]
    views = sum(int(source.get("view_count") or 0) for source in world["sources"])
    return {
        "id": world["id"],
        "created_at": world.get("created_at"),
        "updated_at": world.get("updated_at"),
        "status": world.get("status") or "idle",
        "message": world.get("message") or "",
        "updates": int(world.get("updates") or 0),
        "settings": world.get("settings") or dict(DEFAULT_SETTINGS),
        "has_model": glb.is_file(),
        "model_url": f"/api/worlds/{session_id}/model.glb?t={int(glb.stat().st_mtime)}" if glb.is_file() else None,
        "model_bytes": glb.stat().st_size if glb.is_file() else 0,
        "sources": [_public_source(session_id, source) for source in world["sources"]],
        "stats": {
            "videos": len(videos),
            "photos": len(photos),
            "localized": len(localized),
            "views": views,
            "queued": sum(source["status"] == "queued" for source in world["sources"]),
            "processing": sum(source["status"] == "processing" for source in world["sources"]),
            "failed": sum(source["status"] == "failed" for source in world["sources"]),
        },
        "runtime": {
            "cuda": bool(torch is not None and torch.cuda.is_available()),
            "mock": bool(os.getenv("MAPANYTHING_MOCK")),
            "model": MODEL_ID,
        },
    }


def _run_worker(session_id: str) -> None:
    session = _session_dir(session_id)
    while True:
        world = _ensure_world(session)
        settings = world.get("settings") or DEFAULT_SETTINGS
        videos, photos = _session_media(session)
        processed_videos = _read_json_set(session / "processed_videos.json")
        processed_photos = _read_json_set(session / "processed_photos.json")
        pending = [video for video in videos if video.name not in processed_videos] + [
            photo for photo in photos if photo.name not in processed_photos
        ]
        if not pending:
            world["status"] = "idle"
            if not world.get("message"):
                world["message"] = "World is up to date."
            _save_world(session, world)
            return
        try:
            update_live_twin(
                session_id,
                settings.get("seconds_between_frames", 1.5),
                settings.get("max_frames", 40),
                settings.get("confidence_percentile", 10),
                settings.get("as_mesh", False),
            )
        except Exception:
            return


def _kick_worker(session_id: str) -> None:
    with WORKER_GUARD:
        thread = WORKERS.get(session_id)
        if thread and thread.is_alive():
            return
        worker = threading.Thread(
            target=_run_worker, args=(session_id,), daemon=True, name=f"world-{session_id}"
        )
        WORKERS[session_id] = worker
        worker.start()


def create_world(settings=None) -> dict:
    session_id = uuid.uuid4().hex[:12]
    session = _session_dir(session_id)
    world = _empty_world(session_id)
    _save_world(session, world)
    if settings:
        _update_settings(session, settings)
    return public_world(session_id)


try:
    import secrets

    import uvicorn
    from fastapi import FastAPI, File, Form, HTTPException, UploadFile
    from fastapi.responses import FileResponse
    from fastapi.staticfiles import StaticFiles
    from starlette.middleware.base import BaseHTTPMiddleware
    from starlette.requests import Request
    from starlette.responses import Response

    class _BasicAuth(BaseHTTPMiddleware):
        async def dispatch(self, request: Request, call_next) -> Response:
            username = os.getenv("GRADIO_USERNAME")
            password = os.getenv("GRADIO_PASSWORD")
            if not username or not password:
                return await call_next(request)
            header = request.headers.get("authorization", "")
            if header.startswith("Basic "):
                import base64

                try:
                    decoded = base64.b64decode(header.split(" ", 1)[1]).decode("utf-8")
                    offered_user, offered_password = decoded.split(":", 1)
                except Exception:
                    offered_user = offered_password = ""
                if secrets.compare_digest(offered_user, username) and secrets.compare_digest(
                    offered_password, password
                ):
                    return await call_next(request)
            return Response(
                "Authentication required",
                status_code=401,
                headers={"WWW-Authenticate": "Basic"},
            )

    web = FastAPI(title="MapAnything Growing World", docs_url=None, redoc_url=None)
    web.add_middleware(_BasicAuth)

    @web.get("/")
    def _index():
        return FileResponse(STATIC / "index.html")

    @web.get("/favicon.ico")
    def _favicon():
        return Response(status_code=204)

    @web.get("/api/runtime")
    def _runtime():
        return {
            "cuda": bool(torch is not None and torch.cuda.is_available()),
            "mock": bool(os.getenv("MAPANYTHING_MOCK")),
            "model": MODEL_ID,
        }

    @web.post("/api/worlds")
    def _create_world_route(
        seconds_between_frames: float = Form(1.5),
        max_frames: int = Form(40),
        confidence_percentile: float = Form(10),
        as_mesh: bool = Form(False),
    ):
        return create_world(
            {
                "seconds_between_frames": seconds_between_frames,
                "max_frames": max_frames,
                "confidence_percentile": confidence_percentile,
                "as_mesh": as_mesh,
            }
        )

    @web.get("/api/worlds/{world_id}")
    def _get_world(world_id: str):
        try:
            return public_world(world_id)
        except gr.Error as exc:
            raise HTTPException(404, str(exc)) from exc

    @web.patch("/api/worlds/{world_id}")
    def _patch_world(
        world_id: str,
        seconds_between_frames: float | None = Form(None),
        max_frames: int | None = Form(None),
        confidence_percentile: float | None = Form(None),
        as_mesh: bool | None = Form(None),
    ):
        try:
            session = _session_dir(world_id)
        except gr.Error as exc:
            raise HTTPException(404, str(exc)) from exc
        _update_settings(
            session,
            {
                "seconds_between_frames": seconds_between_frames,
                "max_frames": max_frames,
                "confidence_percentile": confidence_percentile,
                "as_mesh": as_mesh,
            },
        )
        return public_world(world_id)

    @web.post("/api/worlds/{world_id}/sources")
    async def _upload_sources(
        world_id: str,
        files: list[UploadFile] = File(...),
        seconds_between_frames: float = Form(1.5),
        max_frames: int = Form(40),
        confidence_percentile: float = Form(10),
        as_mesh: bool = Form(False),
    ):
        if not files:
            raise HTTPException(400, "Upload at least one photo or video.")
        try:
            session_id = _safe_id(world_id)
        except gr.Error:
            created = create_world()
            session_id = created["id"]
        session = LIVE / session_id
        session.mkdir(parents=True, exist_ok=True)
        incoming = session / "incoming"
        incoming.mkdir(exist_ok=True)
        items: list[tuple[Path, str]] = []
        try:
            for upload in files:
                original = Path(upload.filename or "upload.bin").name
                destination = incoming / f"{time.time_ns()}-{original}"
                with destination.open("wb") as handle:
                    shutil.copyfileobj(upload.file, handle)
                items.append((destination, original))
            ingest_paths(
                session_id,
                items,
                {
                    "seconds_between_frames": seconds_between_frames,
                    "max_frames": max_frames,
                    "confidence_percentile": confidence_percentile,
                    "as_mesh": as_mesh,
                },
            )
        except gr.Error as exc:
            raise HTTPException(400, str(exc)) from exc
        finally:
            for path, _name in items:
                path.unlink(missing_ok=True)
        _kick_worker(session_id)
        return public_world(session_id)

    @web.get("/api/worlds/{world_id}/model.glb")
    def _model(world_id: str):
        path = _glb_path(world_id)
        if not path.is_file():
            raise HTTPException(404, "This world has no mesh yet.")
        return FileResponse(
            path,
            media_type="model/gltf-binary",
            filename=f"{world_id}.glb",
            headers={"Cache-Control": "no-store"},
        )

    @web.get("/api/worlds/{world_id}/thumbs/{name}")
    def _thumb(world_id: str, name: str):
        path = _session_dir(world_id) / "thumbs" / Path(name).name
        if not path.is_file():
            raise HTTPException(404, "Thumbnail not found.")
        return FileResponse(path, media_type="image/jpeg")

    if STATIC.is_dir():
        web.mount("/static", StaticFiles(directory=STATIC), name="static")

except ImportError:
    web = None


if __name__ == "__main__":
    if web is None:
        raise SystemExit("FastAPI is required to serve the web UI. Install fastapi and uvicorn.")
    username = os.getenv("GRADIO_USERNAME")
    password = os.getenv("GRADIO_PASSWORD")
    uvicorn.run(
        web,
        host=os.getenv("HOST", "0.0.0.0"),
        port=int(os.getenv("PORT", "7860")),
        log_level="info",
    )
    _ = (username, password)
