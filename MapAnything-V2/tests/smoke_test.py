"""Small local smoke tests that do not download model weights."""

import tempfile
from pathlib import Path
import sys

import cv2
import numpy as np
import trimesh

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app


def make_photo(path: Path, color: tuple[int, int, int]) -> None:
    image = np.full((48, 64, 3), color, dtype=np.uint8)
    image[10:20, 10:20] = 255
    cv2.imwrite(str(path), image)


def make_video(path: Path, color: tuple[int, int, int]) -> None:
    writer = cv2.VideoWriter(
        str(path), cv2.VideoWriter_fourcc(*"MJPG"), 4, (64, 48)
    )
    assert writer.isOpened()
    for index in range(8):
        frame = np.full((48, 64, 3), color, dtype=np.uint8)
        frame[:, index : index + 4] = 255
        writer.write(frame)
    writer.release()


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    first, second = root / "first.avi", root / "second.avi"
    make_video(first, (10, 20, 30))
    make_video(second, (30, 20, 10))
    frame_dir, frames, status = app.extract_frames([first, second], 0.5, 3)
    assert len(frames) == 6
    assert len({Path(frame).name for frame in frames}) == 6
    assert all(Path(frame).is_file() for frame in frames)
    assert "2 videos" in status
    assert Path(frame_dir).is_dir()

    # A live session durably accepts successive clips. Patch GPU reconstruction
    # so this test exercises update detection without downloading model weights.
    original_live = app.LIVE
    original_outputs = app.OUTPUTS
    original_reconstruct = app.reconstruct
    app.LIVE = root / "live_sessions"
    app.OUTPUTS = root / "outputs"
    app.OUTPUTS.mkdir()
    fake_scene = root / "scene.glb"
    cube = np.array([[x, y, z] for x in (0., 1.) for y in (0., 1.) for z in (0., 1.)])
    trimesh.points.PointCloud(cube).export(fake_scene)
    app.reconstruct = lambda frame_dir, confidence, mesh: (
        str(fake_scene), str(fake_scene), f"Complete from {frame_dir}"
    )
    session_id, cleared, message = app.add_live_videos("", [first, second])
    assert session_id and cleared is None and "2 new clip" in message
    viewer, download, status = app.update_live_twin(session_id, 0.5, 3, 10, False)
    assert viewer == download and Path(viewer).is_file()
    assert "2 new clip(s) / 6 frames" in status
    processed = app.LIVE / session_id / "processed_videos.json"
    first_processed = processed.read_text()
    _, _, unchanged = app.update_live_twin(session_id, 0.5, 3, 20, False)
    assert processed.read_text() == first_processed and "Up to date" in unchanged
    app.add_live_videos(session_id, [first])
    viewer, _, status = app.update_live_twin(session_id, 0.5, 3, 10, False)
    assert Path(viewer).is_file() and "1 new clip(s)" in status and "ICP" in status

    gap_a, gap_b = root / "gap_a.jpg", root / "gap_b.png"
    make_photo(gap_a, (200, 10, 10))
    make_photo(gap_b, (10, 200, 10))
    frame_dir, mixed, mixed_status = app.extract_frames([first], 0.5, 3, [gap_a, gap_b])
    assert "1 videos" in mixed_status and "2 gap photos" in mixed_status
    assert len(mixed) == 5
    assert sum(Path(path).name.startswith("gap_") for path in mixed) == 2
    assert all(Path(path).is_file() for path in mixed)
    assert Path(frame_dir).is_dir()

    cleared, queued = app.add_live_photos(session_id, [gap_a, gap_b])
    assert cleared is None and "2 gap photo" in queued
    viewer, _, status = app.update_live_twin(session_id, 0.5, 3, 10, False)
    assert Path(viewer).is_file() and "2 gap photo(s)" in status and "ICP" in status
    processed_photos = app.LIVE / session_id / "processed_photos.json"
    first_photos = processed_photos.read_text()
    _, _, unchanged_photos = app.update_live_twin(session_id, 0.5, 3, 10, False)
    assert processed_photos.read_text() == first_photos and "Up to date" in unchanged_photos

    only_a, only_b = root / "only_a.jpg", root / "only_b.png"
    make_photo(only_a, (10, 10, 200))
    make_photo(only_b, (10, 200, 200))
    photo_session = app.ingest_paths("", [(only_a, "only_a.jpg"), (only_b, "only_b.png")])
    viewer, _, status = app.update_live_twin(photo_session, 0.5, 3, 10, False)
    assert Path(viewer).is_file() and "2 gap photo(s)" in status and "Initialized" in status
    world = app.public_world(photo_session)
    assert world["stats"]["photos"] == 2 and world["stats"]["videos"] == 0
    assert world["stats"]["localized"] == 2 and world["has_model"]

    heic_named = root / "IMG_1234.HEIC"
    heic_named.write_bytes(only_a.read_bytes())
    sidecar = root / "IMG_1234.AAE"
    sidecar.write_text("edit sidecar")
    heic_session = app.ingest_paths("", [(heic_named, "IMG_1234.HEIC"), (sidecar, "IMG_1234.AAE")])
    heic_world = app.public_world(heic_session)
    assert heic_world["stats"]["photos"] == 1 and heic_world["stats"]["videos"] == 0

    solo = root / "solo.jpg"
    make_photo(solo, (20, 80, 160))
    solo_session = app.ingest_paths("", [(solo, "solo.jpg")])
    viewer, _, status = app.update_live_twin(solo_session, 0.5, 3, 10, False)
    assert Path(viewer).is_file() and "1 gap photo(s)" in status and "Initialized" in status

    mixed_session = app.ingest_paths(
        "",
        [(first, "first.avi"), (gap_a, "gap_a.jpg")],
    )
    assert mixed_session
    mixed_world = app.public_world(mixed_session)
    assert mixed_world["stats"]["videos"] == 1 and mixed_world["stats"]["photos"] == 1
    assert all(source["status"] == "queued" for source in mixed_world["sources"])

    app.LIVE = original_live
    app.OUTPUTS = original_outputs
    app.reconstruct = original_reconstruct

print("smoke test passed")
