"""Small local smoke tests that do not download model weights."""

import tempfile
from pathlib import Path
import sys

import cv2
import numpy as np
import trimesh

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app

assert app.load_images_kwargs(518) == {}
assert app.load_images_kwargs() == {}
assert app.load_images_kwargs(770) == {
    "resize_mode": "longest_side",
    "size": 770,
    "patch_size": 14,
}
assert app.load_images_kwargs(1036)["size"] == 1036
assert app._normalize_ingest_resolution(800) == 770
assert app._normalize_ingest_resolution(None) == 518
assert app._normalize_ingest_resolution("1036") == 1036
assert app._merged_settings({"max_frames": 10})["ingest_resolution"] == 518
assert app._merged_settings({"ingest_resolution": 1000})["ingest_resolution"] == 1036
assert app._as_bool("false") is False
assert app._as_bool("true") is True
assert app._as_bool("off") is False
assert app._merged_settings({"as_mesh": "false"})["as_mesh"] is False
assert app._merged_settings({"as_mesh": "true"})["as_mesh"] is True


def run_twin(session_id, seconds=0.5, max_frames=3, confidence=10, as_mesh=False):
    app._update_settings(
        app._session_dir(session_id),
        {
            "seconds_between_frames": seconds,
            "max_frames": max_frames,
            "confidence_percentile": confidence,
            "as_mesh": as_mesh,
        },
    )
    return app.update_live_twin(session_id, seconds, max_frames, confidence, as_mesh)


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
    app.reconstruct = lambda frame_dir, confidence, mesh, ingest_resolution=518: (
        str(fake_scene), str(fake_scene), f"Complete from {frame_dir}"
    )
    session_id, cleared, message = app.add_live_videos("", [first, second])
    assert session_id and cleared is None and "2 new clip" in message
    viewer, download, status = run_twin(session_id)
    assert viewer == download and Path(viewer).is_file()
    assert "2 new clip(s) / 6 frames" in status
    stale_session, _, _ = app.add_live_videos("", [first, second])
    app._update_settings(
        app._session_dir(stale_session),
        {"seconds_between_frames": 0.5, "max_frames": 3, "as_mesh": "true"},
    )
    assert app._load_world(app._session_dir(stale_session))["settings"]["as_mesh"] is True
    _, _, stale_status = app.update_live_twin(stale_session, 99, 99, 10, False)
    assert "6 frames" in stale_status
    processed = app.LIVE / session_id / "processed_videos.json"
    first_processed = processed.read_text()
    _, _, unchanged = run_twin(session_id, confidence=20)
    assert processed.read_text() == first_processed and "Up to date" in unchanged
    app.add_live_videos(session_id, [first])
    viewer, _, status = run_twin(session_id)
    assert Path(viewer).is_file() and "1 new clip(s)" in status
    assert "Rebuilt the twin" in status or "ICP" in status
    assert (app.OUTPUTS / f"live-{session_id}.prev.glb").is_file()

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
    viewer, _, status = run_twin(session_id)
    assert Path(viewer).is_file() and "2 gap photo(s)" in status
    assert "Rebuilt the twin" in status or "ICP" in status
    processed_photos = app.LIVE / session_id / "processed_photos.json"
    first_photos = processed_photos.read_text()
    _, _, unchanged_photos = run_twin(session_id)
    assert processed_photos.read_text() == first_photos and "Up to date" in unchanged_photos

    only_a, only_b = root / "only_a.jpg", root / "only_b.png"
    make_photo(only_a, (10, 10, 200))
    make_photo(only_b, (10, 200, 200))
    photo_session = app.ingest_paths("", [(only_a, "only_a.jpg"), (only_b, "only_b.png")])
    viewer, _, status = run_twin(photo_session)
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
    viewer, _, status = run_twin(solo_session)
    assert Path(viewer).is_file() and "1 gap photo(s)" in status and "Initialized" in status

    mixed_session = app.ingest_paths(
        "",
        [(first, "first.avi"), (gap_a, "gap_a.jpg")],
    )
    assert mixed_session
    mixed_world = app.public_world(mixed_session)
    assert mixed_world["stats"]["videos"] == 1 and mixed_world["stats"]["photos"] == 1
    assert all(source["status"] == "queued" for source in mixed_world["sources"])

    original_kick = app._kick_worker
    app._kick_worker = lambda session_id: None
    try:
        photo_world = app.public_world(photo_session)
        victim = photo_world["sources"][0]
        session_path = app.LIVE / photo_session
        stored = session_path / "photos" / victim["stored_as"]
        thumb = session_path / "thumbs" / f"{victim['id']}.jpg"
        assert stored.is_file()
        after_delete = app.delete_source(photo_session, victim["id"])
        assert victim["id"] not in {source["id"] for source in after_delete["sources"]}
        assert after_delete["stats"]["photos"] == 1
        assert not after_delete["has_model"]
        assert not stored.exists()
        assert not thumb.exists()
        assert victim["stored_as"] not in app._read_json_set(session_path / "processed_photos.json")
        remaining = after_delete["sources"][0]
        assert remaining["status"] == "queued" and remaining["cameras"] == []
        viewer, _, status = run_twin(photo_session)
        assert Path(viewer).is_file() and "1 gap photo(s)" in status
        rebuilt = app.public_world(photo_session)
        assert rebuilt["has_model"] and rebuilt["stats"]["localized"] == 1

        app._update_settings(session_path, {"as_mesh": "true", "seconds_between_frames": 0.25})
        assert app._load_world(session_path)["settings"]["as_mesh"] is True
        rebuilt_settings = app.rebuild_world(photo_session)
        assert not rebuilt_settings["has_model"]
        assert rebuilt_settings["sources"][0]["status"] == "queued"
        assert app._read_json_set(session_path / "processed_photos.json") == set()
        viewer, _, status = run_twin(photo_session, seconds=0.25, as_mesh=True)
        assert Path(viewer).is_file() and "1 gap photo(s)" in status
        rebuilt = app.public_world(photo_session)
        assert rebuilt["has_model"] and rebuilt["settings"]["as_mesh"] is True

        last = rebuilt["sources"][0]
        empty_world = app.delete_source(photo_session, last["id"])
        assert empty_world["stats"]["photos"] == 0 and not empty_world["has_model"]
        assert not (app.OUTPUTS / f"live-{photo_session}.glb").exists()
        assert empty_world["sources"] == []

        busy_session = app._session_dir(mixed_session)
        busy_world = app._load_world(busy_session)
        busy_world["status"] = "processing"
        app._save_world(busy_session, busy_world)
        try:
            app.delete_source(mixed_session, mixed_world["sources"][0]["id"])
            raise AssertionError("delete should reject an in-progress reconstruction")
        except app.BusyError as exc:
            assert "in progress" in str(exc).lower()
        try:
            app.rebuild_world(mixed_session)
            raise AssertionError("rebuild should reject an in-progress reconstruction")
        except app.BusyError as exc:
            assert "in progress" in str(exc).lower()
        busy_world["status"] = "idle"
        app._save_world(busy_session, busy_world)
        try:
            app.delete_source(mixed_session, "zzzzzzzz")
            raise AssertionError("delete should reject an unknown viewpoint")
        except app.ReconstructionError as exc:
            assert "not found" in str(exc).lower()
    finally:
        app._kick_worker = original_kick

    assert app._alignment_rejected(0.01, 1.02, 2.0) is None
    assert "scale" in (app._alignment_rejected(0.01, 4.2, 2.0) or "")
    assert "previous reconstruction was kept" in (app._alignment_rejected(2.5, 1.0, 2.0) or "")

    dest = root / "existing.glb"
    addition = root / "addition.glb"
    cube = np.array([[x, y, z] for x in (0.0, 1.0) for y in (0.0, 1.0) for z in (0.0, 1.0)])
    trimesh.points.PointCloud(cube).export(dest)
    before = dest.read_bytes()
    trimesh.points.PointCloud(cube * 25 + np.array([80.0, 0.0, 0.0])).export(addition)
    cost, scale, _matrix, rejected = app._merge_increment(dest, addition, dest)
    assert rejected and dest.read_bytes() == before
    assert scale < app.ICP_SCALE_MIN or scale > app.ICP_SCALE_MAX or cost > app.ICP_COST_MAX

    oom_calls = {"n": 0}

    def oom_then_ok(frame_dir, confidence, mesh, ingest_resolution=518):
        oom_calls["n"] += 1
        dest_glb = app.OUTPUTS / f"live-{oom_session}.glb"
        if dest_glb.is_file() and oom_calls["n"] == 2:
            raise RuntimeError("CUDA out of memory")
        return str(fake_scene), str(fake_scene), f"Complete from {frame_dir}"

    oom_session = app.ingest_paths("", [(first, "oom-first.avi")])
    app.reconstruct = oom_then_ok
    viewer, _, status = run_twin(oom_session)
    assert Path(viewer).is_file() and "Initialized" in status
    app.add_live_videos(oom_session, [second])
    viewer, _, status = run_twin(oom_session)
    assert Path(viewer).is_file() and "1 new clip(s)" in status and "ICP" in status

    app.LIVE = original_live
    app.OUTPUTS = original_outputs
    app.reconstruct = original_reconstruct

print("smoke test passed")
