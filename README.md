# Live multi-video MapAnything

An Apache-2.0 Gradio interface that turns overlapping phone-video clips into an
incrementally updated digital twin using Meta's MapAnything.

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

## Update a digital twin

1. Open **Live incremental twin**, upload overlapping clips, and click **Add clips**.
2. Leave the page open. It checks every 10 seconds and reconstructs only newly
   added clips. Their overlapping point cloud is registered to the existing twin
   with similarity ICP, then appended without reprocessing earlier clips.
3. Add another overlapping clip the same way; download the updated GLB in the UI.

Inference can take longer than ten seconds, so updates are serialized. This is
incremental clip ingestion, not continuous webcam streaming. ICP needs substantial
visual overlap and can drift over many additions; begin with 20–40 frames per clip.

On a CUDA workstation, run `./scripts/run.sh` and open <http://localhost:7860>.

Test without downloading model weights:

```bash
. .venv/bin/activate
python tests/smoke_test.py
```

The default checkpoint is `facebook/map-anything-apache`.

For deployment without Slurm, see [MODAL.md](MODAL.md).
