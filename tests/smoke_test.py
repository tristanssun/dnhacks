"""Small local smoke tests that do not download model weights."""

import tempfile
from pathlib import Path
import sys

import cv2
import numpy as np

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

print("smoke test passed")
