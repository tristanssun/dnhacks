"""Reconstruct the two workspace phone videos, then exit."""

from pathlib import Path

from app import extract_frames, reconstruct

ROOT = Path(__file__).resolve().parent
videos = sorted([*ROOT.glob("*.MOV"), *ROOT.glob("*.mov")])
if not videos:
    raise SystemExit("No .MOV videos found in the project root")

frame_dir, frames, message = extract_frames(videos, 1.5, 40)
print(message, flush=True)
viewer, download, message = reconstruct(frame_dir, 10, False)
print(message, flush=True)
print(f"GLB: {download}", flush=True)
