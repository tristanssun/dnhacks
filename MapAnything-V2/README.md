# Growing-world MapAnything

A web interface that turns photos and videos from many viewpoints into one
incrementally updated 3D world using Meta's MapAnything. You do not set camera
poses. Each new source is localized by the model and fused into the existing mesh.

## Start and access the GPU service

One-time setup:

```bash
git submodule update --init --recursive
./scripts/setup.sh
```

Submit the UI (six hours by default):

```bash
./scripts/submit_gpu.sh
```

For another duration, subject to the partition limit:

```bash
SLURM_TIME=12:00:00 ./scripts/submit_gpu.sh
```

Wait until `squeue -j JOB_ID` shows `RUNNING`, then obtain the tunnel command:

```bash
./scripts/tunnel.sh JOB_ID USER@LOGIN-HOST
```

Run the printed `ssh` command **on your laptop**, keep it open, and visit
<http://localhost:7860>. The service exists only while the Slurm job is running;
generated GLBs remain on cluster storage afterward.

## Grow a digital twin

1. Open the page and drop one or more videos or photos. The first batch can be
   a walkthrough, stills only, or a mix from different rooms and angles.
2. MapAnything reconstructs the new views, estimates each source's location, and
   writes those cameras into the world. The 3D viewer updates in place.
3. Add more viewpoints whenever you want: another phone clip, a photo of a
   missed corner, or a second camera's recording. Only the new media is
   reconstructed. It is aligned onto the existing twin with similarity ICP, so
   the mesh grows instead of starting over.

You never enter poses or pick a "starter" camera. The model assigns location.
Inference can take longer than the upload, so updates are serialized. This is
incremental clip and photo ingestion, not continuous webcam streaming. ICP needs
substantial visual overlap and can drift over many additions; begin with 20–40
frames per clip.

On a CUDA workstation, run `./scripts/run.sh` and open <http://localhost:7860>.

To exercise the interface without GPU weights:

```bash
MAPANYTHING_MOCK=1 python app.py
```

Test without downloading model weights:

```bash
. .venv/bin/activate
python tests/smoke_test.py
```

The default checkpoint is `facebook/map-anything-apache`.

For deployment without Slurm, see [MODAL.md](MODAL.md).
