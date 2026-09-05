# Multi-video MapAnything

An Apache-2.0 browser interface that turns overlapping phone videos into an
interactive 3D reconstruction using Meta's
[MapAnything](https://github.com/facebookresearch/map-anything).

## What it does

- uploads multiple phone videos at once;
- samples frames from every video with collision-free names;
- runs the Apache-licensed `facebook/map-anything-apache` checkpoint on CUDA;
- previews the reconstruction interactively and exports a portable GLB file.

## Install and run

```bash
git submodule update --init --recursive
./scripts/setup.sh
./scripts/submit_gpu.sh
```

When Slurm starts the job, inspect `outputs/server-<job-id>.log` for the compute
node name. Forward the web port from your computer and open
`http://localhost:7860`:

```bash
ssh -J USER@LOGIN-HOST -L 7860:localhost:7860 USER@COMPUTE-NODE
```

For a workstation with CUDA, run `./scripts/run.sh` directly.

## Capture tips

Move slowly, keep the same scene visible, use diffuse lighting, avoid zooming,
and aim for substantial overlap between videos. Start with 20–40 frames per
video. More frames use more GPU memory and do not always improve results.

## Licensing

This interface is Apache-2.0. MapAnything is included as an Apache-2.0 git
submodule and defaults to its Apache checkpoint. Uploaded videos and generated
outputs are ignored by Git.
