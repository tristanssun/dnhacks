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


class BusyError(ReconstructionError):
    """Raised when a mutation cannot run because reconstruction is in progress."""


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
IMAGE_SUFFIXES = {".bmp", ".heic", ".heif", ".jpeg", ".jpg", ".png", ".tif", ".tiff", ".webp"}
IMAGE_LOAD_SUFFIXES = {".jpg", ".jpeg", ".png"}
SKIP_SUFFIXES = {".aae", ".db", ".ini", ".json", ".txt", ".xml"}
SKIP_NAMES = {".ds_store", "desktop.ini", "thumbs.db"}
_HEIC_BRANDS = {b"heic", b"heif", b"heim", b"heix", b"mif1", b"msf1"}
OVERLAP_FRAMES = 16
ICP_SCALE_MIN = 0.5
ICP_SCALE_MAX = 2.0
ICP_COST_MAX = 0.15
VIEWER_MAX_POINTS = 400_000
INGEST_RESOLUTIONS = (518, 770, 1036)
DEFAULT_INGEST_RESOLUTION = 518
DEFAULT_SETTINGS = {
    "seconds_between_frames": 0.5,
    "max_frames": 40,
    "confidence_percentile": 10,
    "as_mesh": False,
    "ingest_resolution": DEFAULT_INGEST_RESOLUTION,
}
MODEL = None
MODEL_LOCK = threading.Lock()
PREVIEW_LOCK = threading.Lock()
WORKERS: dict[str, threading.Thread] = {}
WORKER_GUARD = threading.Lock()
SESSION_LOCKS: dict[str, threading.Lock] = {}
SESSION_LOCKS_GUARD = threading.Lock()


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


def _as_bool(value, default: bool = False) -> bool:
    """Parse form or JSON booleans. The string 'false' must not become True."""
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"1", "true", "yes", "on"}:
            return True
        if lowered in {"0", "false", "no", "off", ""}:
            return False
    return default


def _normalize_ingest_resolution(value) -> int:
    if value is None or value == "":
        return DEFAULT_INGEST_RESOLUTION
    try:
        resolution = int(value)
    except (TypeError, ValueError):
        return DEFAULT_INGEST_RESOLUTION
    return min(INGEST_RESOLUTIONS, key=lambda item: abs(item - resolution))


def load_images_kwargs(ingest_resolution: int = DEFAULT_INGEST_RESOLUTION) -> dict:
    """Kwargs for load_images. 518 keeps the vendor default fixed_mapping path."""
    resolution = _normalize_ingest_resolution(ingest_resolution)
    if resolution == DEFAULT_INGEST_RESOLUTION:
        return {}
    return {
        "resize_mode": "longest_side",
        "size": resolution,
        "patch_size": 14,
    }


def _merged_settings(settings=None) -> dict:
    merged = dict(DEFAULT_SETTINGS)
    if not settings:
        return merged
    incoming = dict(settings)
    if incoming.get("ingest_resolution") is not None:
        incoming["ingest_resolution"] = _normalize_ingest_resolution(
            incoming["ingest_resolution"]
        )
    if "as_mesh" in incoming:
        incoming["as_mesh"] = _as_bool(incoming.get("as_mesh"), False)
    merged.update(incoming)
    return merged


def _load_world(session: Path) -> dict:
    path = _world_path(session)
    if not path.exists():
        return _empty_world(session.name)
    world = json.loads(path.read_text())
    world["settings"] = _merged_settings(world.get("settings"))
    world.setdefault("sources", [])
    return world


def _save_world(session: Path, world: dict) -> None:
    session.mkdir(parents=True, exist_ok=True)
    world["updated_at"] = _iso_now()
    _world_path(session).write_text(json.dumps(world, indent=2))


def _sniff_media(path: Path) -> str | None:
    try:
        header = path.read_bytes()[:32]
    except OSError:
        return None
    if header.startswith(b"\xff\xd8\xff") or header.startswith(b"\x89PNG\r\n\x1a\n"):
        return "photo"
    if header[:4] == b"RIFF" and header[8:12] == b"WEBP":
        return "photo"
    if header.startswith(b"BM") or header[:2] in {b"II", b"MM"}:
        return "photo"
    if len(header) >= 12 and header[4:8] == b"ftyp":
        return "photo" if header[8:12].lower() in _HEIC_BRANDS else "video"
    if header.startswith(b"\x1aE\xdf\xa3"):
        return "video"
    return None


def _media_kind(path: Path, name: str) -> str | None:
    label = Path(name).name.lower()
    suffix = Path(name).suffix.lower() or path.suffix.lower()
    if label in SKIP_NAMES or suffix in SKIP_SUFFIXES:
        return "skip"
    if suffix in VIDEO_SUFFIXES:
        return "video"
    if suffix in IMAGE_SUFFIXES:
        return "photo"
    return _sniff_media(path)


def _read_bgr(source: Path):
    image = cv2.imread(str(source), cv2.IMREAD_COLOR)
    if image is not None:
        return image
    try:
        from PIL import Image, ImageOps

        try:
            from pillow_heif import register_heif_opener

            register_heif_opener()
        except ImportError:
            pass
        with Image.open(source) as pil:
            rgb = np.array(ImageOps.exif_transpose(pil).convert("RGB"))
        return cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    except Exception:
        return None


def _write_thumbnail(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.suffix.lower() in VIDEO_SUFFIXES:
        capture = cv2.VideoCapture(str(source))
        ok, frame = capture.read()
        capture.release()
        if not ok or frame is None:
            return
    else:
        frame = _read_bgr(source)
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
    merged = _merged_settings(world.get("settings"))
    if "seconds_between_frames" in settings and settings["seconds_between_frames"] is not None:
        merged["seconds_between_frames"] = float(settings["seconds_between_frames"])
    if "max_frames" in settings and settings["max_frames"] is not None:
        merged["max_frames"] = int(settings["max_frames"])
    if "confidence_percentile" in settings and settings["confidence_percentile"] is not None:
        merged["confidence_percentile"] = float(settings["confidence_percentile"])
    if "as_mesh" in settings and settings["as_mesh"] is not None:
        merged["as_mesh"] = _as_bool(settings["as_mesh"], False)
    if "ingest_resolution" in settings and settings["ingest_resolution"] is not None:
        merged["ingest_resolution"] = _normalize_ingest_resolution(settings["ingest_resolution"])
    world["settings"] = merged
    _save_world(session, world)
    return merged


def _normalize_photo(source: Path, dest_dir: Path, prefix: str) -> Path:
    image = _read_bgr(source)
    if image is None:
        raise gr.Error(
            f"Could not read photo {source.name}. Use JPEG, PNG, WebP, HEIC, BMP, or TIFF."
        )
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
    temporary = output.with_name(f"{output.stem}-{uuid.uuid4().hex[:8]}.tmp.glb")
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


def reconstruct(
    frame_dir: str,
    confidence_percentile: float,
    as_mesh: bool,
    ingest_resolution: int = DEFAULT_INGEST_RESOLUTION,
):
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
        views = load_images(frame_dir, **load_images_kwargs(ingest_resolution))
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
    temporary = output.with_name(f"{output.stem}-{uuid.uuid4().hex[:8]}.tmp.glb")
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
            if _sniff_media(source) != "video":
                raise gr.Error(f"Unsupported video type: {source.name}")
            suffix = ".mp4"
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
    """Copy already-reconstructed views so a new increment can register."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    folders = []
    for pattern in ("rebuild-*/images", "increment-*/images"):
        folders.extend(path for path in session.glob(pattern) if path.is_dir())
    folders.sort(key=lambda path: path.stat().st_mtime)
    if not folders:
        return []
    newest = folders[-1]
    pool = folders[-2:] if newest.parent.name.startswith("increment-") else [newest]
    candidates = []
    seen: set[str] = set()
    for folder in pool:
        files = [
            path
            for path in sorted(folder.iterdir())
            if path.is_file() and not path.name.startswith("overlap_")
        ] or [path for path in sorted(folder.iterdir()) if path.is_file()]
        for path in files:
            if path.name in seen:
                continue
            seen.add(path.name)
            candidates.append(path)
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
    videos, photos, unknown = [], [], []
    for path, name in items:
        kind = _media_kind(path, name)
        if kind == "video":
            videos.append((path, name))
        elif kind == "photo":
            photos.append((path, name))
        elif kind != "skip":
            unknown.append(name)
    if not videos and not photos:
        raise gr.Error(
            f"Unsupported file type: {(unknown or ['upload'])[0]}. Use photos "
            "(JPEG, PNG, WebP, HEIC, TIFF, BMP) or videos (MP4, MOV, WebM, MKV, AVI)."
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


def _session_update_lock(session_id: str) -> threading.Lock:
    with SESSION_LOCKS_GUARD:
        lock = SESSION_LOCKS.get(session_id)
        if lock is None:
            lock = threading.Lock()
            SESSION_LOCKS[session_id] = lock
        return lock


def _glb_path(session_id: str) -> Path:
    return OUTPUTS / f"live-{_safe_id(session_id)}.glb"


def _prev_glb_path(session_id: str) -> Path:
    return OUTPUTS / f"live-{_safe_id(session_id)}.prev.glb"


def _unique_tmp(path: Path) -> Path:
    return path.with_name(f"{path.stem}-{uuid.uuid4().hex[:8]}.tmp{path.suffix}")


def _is_cuda_oom(exc: BaseException) -> bool:
    if torch is not None:
        oom_type = getattr(torch.cuda, "OutOfMemoryError", None)
        if oom_type is not None and isinstance(exc, oom_type):
            return True
    text = str(exc).lower()
    name = type(exc).__name__.lower().replace("_", "")
    return "out of memory" in text or "outofmemory" in name or "cuda oom" in text


def _clear_cuda_cache() -> None:
    if torch is not None and getattr(torch, "cuda", None) is not None:
        try:
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        except Exception:
            pass


def _similarity_scale(matrix: np.ndarray) -> float:
    return float(np.cbrt(abs(np.linalg.det(np.asarray(matrix, dtype=float)[:3, :3]))))


def _alignment_rejected(cost: float, scale: float, extent: float) -> str | None:
    """Return a user-facing reason when incremental ICP is unsafe to apply."""
    if not np.isfinite(cost) or not np.isfinite(scale) or scale <= 0:
        return (
            "Could not align the new viewpoint without damaging the existing twin. "
            "The previous reconstruction was kept."
        )
    if scale < ICP_SCALE_MIN or scale > ICP_SCALE_MAX:
        return (
            f"Could not align the new viewpoint without damaging the existing twin "
            f"(ICP scale {scale:.3g} is too far from 1). "
            "The previous reconstruction was kept."
        )
    limit = min(ICP_COST_MAX, max(0.04, 0.08 * max(float(extent), 1e-6)))
    if float(cost) > limit:
        return (
            f"Could not align the new viewpoint without damaging the existing twin "
            f"(ICP cost {cost:.5g}, scale {scale:.3g}). "
            "The previous reconstruction was kept."
        )
    return None


def _install_glb(destination: Path, source: Path) -> None:
    """Atomically replace the live GLB after copying the last good file aside."""
    OUTPUTS.mkdir(parents=True, exist_ok=True)
    if source.resolve() == destination.resolve():
        return
    staged = _unique_tmp(destination)
    shutil.copy2(source, staged)
    if destination.is_file():
        prev = destination.with_name(f"{destination.stem}.prev.glb")
        prev_tmp = _unique_tmp(prev)
        shutil.copy2(destination, prev_tmp)
        prev_tmp.replace(prev)
    staged.replace(destination)


def _list_view_paths(image_dir: Path) -> list[Path]:
    if not image_dir.is_dir():
        return []
    return [
        path
        for path in image_dir.iterdir()
        if path.is_file() and path.suffix.lower() in IMAGE_LOAD_SUFFIXES
    ]


def _fill_image_dir(
    session: Path,
    image_dir: Path,
    videos: list[Path],
    photos: list[Path],
    world: dict,
    seconds_between_frames,
    max_frames,
    seed_overlap: bool,
) -> list[Path]:
    if videos:
        prefixes = [_source_id_for_file(world, video) for video in videos]
        _extract_to_directory(
            videos, image_dir, seconds_between_frames, max_frames,
            min_frames=0, prefixes=prefixes,
        )
    else:
        image_dir.mkdir(parents=True, exist_ok=True)
        if seed_overlap:
            _seed_overlap_frames(session, image_dir)
    for index, photo in enumerate(photos):
        source_id = _source_id_for_file(world, photo)
        prefix = f"{source_id}_still" if source_id else f"gap_{index:04d}"
        _normalize_photo(photo, image_dir, prefix)
    return _list_view_paths(image_dir)


def _added_phrase(new_videos: list[Path], new_photos: list[Path]) -> str:
    return " and ".join(
        part for part in (
            f"{len(new_videos)} new clip(s)" if new_videos else "",
            f"{len(new_photos)} gap photo(s)" if new_photos else "",
        ) if part
    )


def _read_poses(work_dir: Path) -> list[dict]:
    path = work_dir / "poses.json"
    return json.loads(path.read_text()) if path.exists() else []


def _prune_view_dirs(session: Path, keep: int = 2) -> None:
    groups: dict[str, list[Path]] = {"increment-": [], "rebuild-": []}
    for path in session.iterdir():
        if not path.is_dir():
            continue
        for prefix in groups:
            if path.name.startswith(prefix):
                groups[prefix].append(path)
    for dirs in groups.values():
        dirs.sort(key=lambda item: item.stat().st_mtime)
        for old in dirs[:-keep]:
            shutil.rmtree(old, ignore_errors=True)


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
    """Similarity-ICP align an overlapping increment, then append its points.

    Writes the merge to a temp file and only replaces destination when the
    similarity transform looks sane. The previous live GLB is preserved as
    ``.prev.glb`` before a successful replace.
    """
    old_points, old_colors = _scene_points(existing)
    new_points, new_colors = _scene_points(addition)
    rng = np.random.default_rng(0)
    old_sample = old_points[rng.choice(len(old_points), min(20_000, len(old_points)), replace=False)]
    new_sample = new_points[rng.choice(len(new_points), min(20_000, len(new_points)), replace=False)]
    old_extent = float(np.linalg.norm(np.ptp(old_sample, axis=0)))
    new_extent = float(np.linalg.norm(np.ptp(new_sample, axis=0)))
    scale = old_extent / new_extent if new_extent > 1e-8 else 1.0
    initial = np.eye(4)
    initial[:3, :3] *= scale
    initial[:3, 3] = old_sample.mean(axis=0) - scale * new_sample.mean(axis=0)
    matrix, _, cost = trimesh.registration.icp(
        new_sample, old_sample, initial=initial, max_iterations=30,
        scale=True, reflection=False)
    matrix = np.asarray(matrix, dtype=float)
    fitted_scale = _similarity_scale(matrix)
    rejected = _alignment_rejected(float(cost), fitted_scale, old_extent)
    if rejected:
        return float(cost), fitted_scale, matrix, rejected
    aligned = trimesh.transform_points(new_points, matrix)
    merged = trimesh.points.PointCloud(
        np.concatenate([old_points, aligned]), colors=np.concatenate([old_colors, new_colors]))
    staged = _unique_tmp(destination)
    merged.export(staged)
    _install_glb(destination, staged)
    staged.unlink(missing_ok=True)
    return float(cost), fitted_scale, matrix, None


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


def _mark_processed(session: Path, processed_videos: set[str], processed_photos: set[str],
                    new_videos: list[Path], new_photos: list[Path]) -> None:
    processed_videos.update(video.name for video in new_videos)
    processed_photos.update(photo.name for photo in new_photos)
    _write_json(session / "processed_videos.json", processed_videos)
    _write_json(session / "processed_photos.json", processed_photos)


def _complete_twin(session: Path, session_id: str, destination: Path, files: list[Path],
                   poses: list[dict], matrix, new_videos: list[Path], new_photos: list[Path],
                   processed_videos: set[str], processed_photos: set[str], status: str):
    _ensure_preview(session_id)
    _mark_processed(session, processed_videos, processed_photos, new_videos, new_photos)
    _assign_localizations(session, files, poses, matrix)
    world = _load_world(session)
    world["status"] = "idle"
    world["message"] = status
    _save_world(session, world)
    _prune_view_dirs(session)
    return str(destination), str(destination), status


def update_live_twin(session_id, seconds_between_frames, max_frames,
                     confidence_percentile, as_mesh,
                     ingest_resolution=DEFAULT_INGEST_RESOLUTION):
    """Rebuild the twin when the session has received new clips or gap photos."""
    if not session_id:
        return gr.skip(), gr.skip(), "Upload photos or videos to begin."
    session_id = _safe_id(session_id)
    with _session_update_lock(session_id):
        return _update_live_twin_locked(
            session_id, seconds_between_frames, max_frames,
            confidence_percentile, as_mesh, ingest_resolution,
        )


def _update_live_twin_locked(
    session_id, seconds_between_frames, max_frames,
    confidence_percentile, as_mesh, ingest_resolution,
):
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
    saved = _merged_settings(world.get("settings"))
    seconds_between_frames = float(
        saved.get("seconds_between_frames", seconds_between_frames)
    )
    max_frames = int(saved.get("max_frames", max_frames))
    confidence_percentile = float(
        saved.get("confidence_percentile", confidence_percentile)
    )
    as_mesh = _as_bool(saved.get("as_mesh"), as_mesh)
    ingest_resolution = _normalize_ingest_resolution(
        saved.get("ingest_resolution", ingest_resolution)
    )
    _mark_sources(
        session,
        new_videos + new_photos,
        "processing",
        message="Localizing new viewpoints and fusing them into the world.",
    )
    world = _load_world(session)
    world["status"] = "processing"
    _save_world(session, world)
    destination = _glb_path(session_id)
    has_existing = destination.is_file()
    ingest_resolution = _normalize_ingest_resolution(ingest_resolution)
    added = _added_phrase(new_videos, new_photos)
    work = session / f"{'rebuild' if has_existing else 'increment'}-{uuid.uuid4().hex[:8]}"
    image_dir = work / "images"

    def infer(image_dir: Path):
        return reconstruct(
            str(image_dir),
            confidence_percentile,
            as_mesh,
            ingest_resolution=ingest_resolution,
        )

    def keep_previous(message: str):
        _mark_processed(session, processed_videos, processed_photos, new_videos, new_photos)
        _mark_sources(
            session,
            new_videos + new_photos,
            "failed",
            error=message,
            message=message,
        )
        return str(destination), str(destination), message

    try:
        if has_existing:
            view_paths = _fill_image_dir(
                session, image_dir, videos, photos, world,
                seconds_between_frames, max_frames, seed_overlap=False,
            )
            if not view_paths:
                shutil.rmtree(work, ignore_errors=True)
                raise gr.Error(
                    "Could not extract any views. Upload a photo or a longer video."
                )
            try:
                addition, _, result = infer(image_dir)
                poses = _read_poses(work)
                _install_glb(destination, Path(addition))
                status = (
                    f"{result} Added {added}. "
                    f"Rebuilt the twin from {len(view_paths)} views."
                )
                return _complete_twin(
                    session, session_id, destination, videos + photos, poses, None,
                    new_videos, new_photos, processed_videos, processed_photos, status,
                )
            except Exception as exc:
                if not _is_cuda_oom(exc):
                    raise
                _clear_cuda_cache()
                shutil.rmtree(work, ignore_errors=True)
                work = session / f"increment-{uuid.uuid4().hex[:8]}"
                image_dir = work / "images"

        view_paths = _fill_image_dir(
            session, image_dir, new_videos, new_photos, world,
            seconds_between_frames, max_frames,
            seed_overlap=has_existing and not new_videos,
        )
        if not view_paths:
            shutil.rmtree(work, ignore_errors=True)
            raise gr.Error(
                "Could not extract any views. Upload a photo or a longer video."
            )
        try:
            addition, _, result = infer(image_dir)
        except Exception as exc:
            if has_existing and _is_cuda_oom(exc):
                _clear_cuda_cache()
                return keep_previous(
                    "GPU ran out of memory while adding this viewpoint. "
                    "The previous reconstruction was kept."
                )
            raise
        poses = _read_poses(work)
        matrix = None
        if has_existing:
            cost, scale, matrix, rejected = _merge_increment(
                destination, Path(addition), destination
            )
            if rejected:
                return keep_previous(rejected)
            alignment = (
                f" GPU ran out of memory for a full rebuild, so this update used "
                f"incremental alignment. ICP alignment cost: {cost:.5g} "
                f"(scale {scale:.3g})."
            )
        else:
            _install_glb(destination, Path(addition))
            alignment = " Initialized the twin."
        status = (
            f"{result} Added {added} / {len(view_paths)} frames.{alignment}"
        )
        return _complete_twin(
            session, session_id, destination, new_videos + new_photos, poses, matrix,
            new_videos, new_photos, processed_videos, processed_photos, status,
        )
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
                       confidence_percentile, as_mesh,
                       ingest_resolution=DEFAULT_INGEST_RESOLUTION):
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
    _update_settings(
        session,
        {
            "seconds_between_frames": seconds_between_frames,
            "max_frames": max_frames,
            "confidence_percentile": confidence_percentile,
            "as_mesh": as_mesh,
            "ingest_resolution": ingest_resolution,
        },
    )
    viewer, download, status = update_live_twin(
        session_id, seconds_between_frames, max_frames, confidence_percentile, as_mesh,
        ingest_resolution,
    )
    return session_id, None, None, viewer, download, status


def add_gap_photos(session_id, photos, seconds_between_frames, max_frames,
                   confidence_percentile, as_mesh,
                   ingest_resolution=DEFAULT_INGEST_RESOLUTION):
    extras = _paths(photos)
    if not session_id:
        raise gr.Error("Build a twin from a starter video first.")
    if not extras:
        raise gr.Error("Choose one or more still photos of the missing areas.")
    session = _session_dir(session_id)
    queued = _queue_photos(session, extras)
    _register_sources(session, [(dest, src.name, "photo") for dest, src in zip(queued, extras)])
    _update_settings(
        session,
        {
            "seconds_between_frames": seconds_between_frames,
            "max_frames": max_frames,
            "confidence_percentile": confidence_percentile,
            "as_mesh": as_mesh,
            "ingest_resolution": ingest_resolution,
        },
    )
    viewer, download, status = update_live_twin(
        session_id, seconds_between_frames, max_frames, confidence_percentile, as_mesh,
        ingest_resolution,
    )
    return None, viewer, download, status


def _preview_path(session_id: str) -> Path:
    return OUTPUTS / f"live-{_safe_id(session_id)}-preview.glb"


def _ensure_preview(session_id: str) -> Path | None:
    """Write a downsampled, transform-baked GLB the browser can load quickly."""
    source = _glb_path(session_id)
    if not source.is_file():
        return None
    destination = _preview_path(session_id)
    if destination.is_file() and destination.stat().st_mtime >= source.stat().st_mtime:
        return destination
    with PREVIEW_LOCK:
        if destination.is_file() and destination.stat().st_mtime >= source.stat().st_mtime:
            return destination
        return _write_preview(source, destination)


def _write_preview(source: Path, destination: Path) -> Path | None:
    scene = trimesh.load(source, force="scene")
    vertices, colors = [], []
    names = list(getattr(scene.graph, "nodes_geometry", None) or scene.geometry.keys())
    for name in names:
        try:
            matrix, geom_name = scene.graph.get(name)
            geometry = scene.geometry[geom_name]
            points = trimesh.transform_points(np.asarray(geometry.vertices), matrix)
        except Exception:
            geometry = scene.geometry[name]
            points = np.asarray(geometry.vertices)
        vertex_colors = getattr(geometry.visual, "vertex_colors", None)
        if vertex_colors is None or len(vertex_colors) != len(points):
            vertex_colors = np.full((len(points), 4), 255, dtype=np.uint8)
        vertices.append(points)
        colors.append(np.asarray(vertex_colors, dtype=np.uint8))
    if not vertices:
        return None
    points = np.concatenate(vertices)
    vertex_colors = np.concatenate(colors)
    if len(points) > VIEWER_MAX_POINTS:
        pick = np.random.default_rng(0).choice(len(points), VIEWER_MAX_POINTS, replace=False)
        points, vertex_colors = points[pick], vertex_colors[pick]
    OUTPUTS.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f"{destination.stem}-{uuid.uuid4().hex[:8]}.tmp.glb")
    trimesh.points.PointCloud(points, colors=vertex_colors).export(temporary)
    temporary.replace(destination)
    return destination


def _reconstruction_busy(session_id: str) -> bool:
    session = _session_dir(session_id)
    world = _load_world(session)
    if world.get("status") == "processing":
        return True
    if any(source.get("status") == "processing" for source in world.get("sources", [])):
        return True
    with WORKER_GUARD:
        thread = WORKERS.get(session_id)
        return bool(thread and thread.is_alive())


def _reset_source_localization(source: dict) -> None:
    source["status"] = "queued"
    source["error"] = None
    source["localized_at"] = None
    source["view_count"] = 0
    source["position"] = None
    source["forward"] = None
    source["cameras"] = []


def delete_source(session_id: str, source_id: str) -> dict:
    """Remove a viewpoint and rebuild the twin from whatever sources remain."""
    session_id = _safe_id(session_id)
    source_id = Path(source_id or "").name
    if not source_id:
        raise gr.Error("Viewpoint not found.")
    session = _session_dir(session_id)
    with _session_update_lock(session_id):
        return _delete_source_locked(session_id, source_id, session)


def _delete_source_locked(session_id: str, source_id: str, session: Path) -> dict:
    if _reconstruction_busy(session_id):
        raise BusyError(
            "Cannot delete a viewpoint while reconstruction is in progress. "
            "Wait for the current update to finish."
        )
    world = _ensure_world(session)
    source = next((item for item in world["sources"] if item.get("id") == source_id), None)
    if source is None:
        raise gr.Error("Viewpoint not found.")
    stored = source.get("stored_as")
    kind = source.get("kind")
    if stored:
        if kind == "video":
            (session / "videos" / stored).unlink(missing_ok=True)
        else:
            (session / "photos" / stored).unlink(missing_ok=True)
    thumb_name = Path(source.get("thumbnail") or f"thumbs/{source_id}.jpg").name
    (session / "thumbs" / thumb_name).unlink(missing_ok=True)
    world["sources"] = [item for item in world["sources"] if item.get("id") != source_id]
    glb = _glb_path(session_id)
    glb.unlink(missing_ok=True)
    _prev_glb_path(session_id).unlink(missing_ok=True)
    _preview_path(session_id).unlink(missing_ok=True)
    remaining = world["sources"]
    if not remaining:
        _write_json(session / "processed_videos.json", set())
        _write_json(session / "processed_photos.json", set())
        world["status"] = "idle"
        world["message"] = "All viewpoints removed. Upload photos or videos to rebuild the world."
        world["updates"] = int(world.get("updates") or 0) + 1
        _save_world(session, world)
        return public_world(session_id)
    # Drop the live GLB and reprocess remaining media so deleted geometry cannot linger.
    _write_json(session / "processed_videos.json", set())
    _write_json(session / "processed_photos.json", set())
    for item in remaining:
        _reset_source_localization(item)
    world["status"] = "idle"
    world["message"] = "Viewpoint removed. Rebuilding the world from remaining sources."
    world["updates"] = int(world.get("updates") or 0) + 1
    _save_world(session, world)
    _kick_worker(session_id)
    return public_world(session_id)


def rebuild_world(session_id: str) -> dict:
    """Clear processed markers and re-run every source with the saved settings."""
    session_id = _safe_id(session_id)
    session = _session_dir(session_id)
    with _session_update_lock(session_id):
        return _rebuild_world_locked(session_id, session)


def _rebuild_world_locked(session_id: str, session: Path) -> dict:
    if _reconstruction_busy(session_id):
        raise BusyError(
            "Cannot rebuild while reconstruction is in progress. "
            "Wait for the current update to finish."
        )
    world = _ensure_world(session)
    if not world.get("sources"):
        world["message"] = "No sources to rebuild. Upload photos or videos first."
        _save_world(session, world)
        return public_world(session_id)
    _write_json(session / "processed_videos.json", set())
    _write_json(session / "processed_photos.json", set())
    for item in world["sources"]:
        _reset_source_localization(item)
    glb = _glb_path(session_id)
    glb.unlink(missing_ok=True)
    _prev_glb_path(session_id).unlink(missing_ok=True)
    _preview_path(session_id).unlink(missing_ok=True)
    world["status"] = "idle"
    world["message"] = "Rebuilding the world with current reconstruction settings."
    world["updates"] = int(world.get("updates") or 0) + 1
    _save_world(session, world)
    _kick_worker(session_id)
    return public_world(session_id)


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
        "model_url": (
            f"/api/worlds/{session_id}/model.glb?preview=1&t={int(glb.stat().st_mtime)}"
            if glb.is_file() else None
        ),
        "download_url": (
            f"/api/worlds/{session_id}/model.glb?t={int(glb.stat().st_mtime)}"
            if glb.is_file() else None
        ),
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
            saved = _merged_settings(settings)
            update_live_twin(
                session_id,
                saved["seconds_between_frames"],
                saved["max_frames"],
                saved["confidence_percentile"],
                saved["as_mesh"],
                saved["ingest_resolution"],
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
    from fastapi import FastAPI, File, Form, HTTPException, Query, UploadFile
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
        return FileResponse(
            STATIC / "index.html",
            headers={"Cache-Control": "no-store"},
        )

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
        seconds_between_frames: float = Form(0.5),
        max_frames: int = Form(40),
        confidence_percentile: float = Form(10),
        as_mesh: bool = Form(False),
        ingest_resolution: int = Form(DEFAULT_INGEST_RESOLUTION),
    ):
        return create_world(
            {
                "seconds_between_frames": seconds_between_frames,
                "max_frames": max_frames,
                "confidence_percentile": confidence_percentile,
                "as_mesh": as_mesh,
                "ingest_resolution": ingest_resolution,
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
        ingest_resolution: int | None = Form(None),
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
                "ingest_resolution": ingest_resolution,
            },
        )
        return public_world(world_id)

    @web.post("/api/worlds/{world_id}/sources")
    async def _upload_sources(
        world_id: str,
        files: list[UploadFile] = File(...),
        seconds_between_frames: float = Form(0.5),
        max_frames: int = Form(40),
        confidence_percentile: float = Form(10),
        as_mesh: bool = Form(False),
        ingest_resolution: int = Form(DEFAULT_INGEST_RESOLUTION),
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
            print(
                f"ingest {session_id}: {[name for _path, name in items]}",
                flush=True,
            )
            ingest_paths(
                session_id,
                items,
                {
                    "seconds_between_frames": seconds_between_frames,
                    "max_frames": max_frames,
                    "confidence_percentile": confidence_percentile,
                    "as_mesh": as_mesh,
                    "ingest_resolution": ingest_resolution,
                },
            )
        except gr.Error as exc:
            print(f"ingest failed {session_id}: {exc}", flush=True)
            raise HTTPException(400, str(exc)) from exc
        finally:
            for path, _name in items:
                path.unlink(missing_ok=True)
        _kick_worker(session_id)
        return public_world(session_id)

    @web.post("/api/worlds/{world_id}/rebuild")
    def _rebuild_world(world_id: str):
        try:
            return rebuild_world(world_id)
        except BusyError as exc:
            raise HTTPException(409, str(exc)) from exc
        except gr.Error as exc:
            message = str(exc)
            status = 404 if "not found" in message.lower() else 400
            raise HTTPException(status, message) from exc

    @web.delete("/api/worlds/{world_id}/sources/{source_id}")
    def _delete_source(world_id: str, source_id: str):
        try:
            return delete_source(world_id, source_id)
        except BusyError as exc:
            raise HTTPException(409, str(exc)) from exc
        except gr.Error as exc:
            message = str(exc)
            status = 404 if "not found" in message.lower() else 400
            raise HTTPException(status, message) from exc

    @web.get("/api/worlds/{world_id}/model.glb")
    def _model(world_id: str, preview: bool = Query(False)):
        path = _glb_path(world_id)
        if not path.is_file():
            raise HTTPException(404, "This world has no mesh yet.")
        if preview:
            path = _ensure_preview(world_id) or path
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
