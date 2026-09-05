"""Small local smoke tests that do not download model weights."""

import tempfile
from pathlib import Path
import sys

import cv2
import numpy as np
import trimesh

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app


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
    original_reconstruct = app.reconstruct
    app.LIVE = root / "live_sessions"
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
    app.LIVE = original_live
    app.reconstruct = original_reconstruct

print("smoke test passed")
