# Modal deployment

This package runs the MapAnything UI on an H200 without Slurm. Modal supplies a
public HTTPS URL, while a persistent Volume stores uploads, live sessions, GLBs,
Hugging Face weights, and Torch caches.

## Deploy

Install and authenticate the Modal CLI on your computer:

```bash
python -m pip install modal
modal setup
```

Extract this ZIP, enter its project directory, and test a temporary deployment:

```bash
modal serve modal_app.py
```

Open the `modal.run` URL printed by the command. Stop the development deployment
with Ctrl-C. For a persistent URL that survives closing your terminal:

```bash
modal deploy modal_app.py
```

The persistent URL remains addressable, but the GPU scales to zero after 20 idle
minutes by default. Its first request then has a cold start. To continuously keep
one H200 allocated, deploy with:

```bash
MODAL_KEEP_WARM=1 modal deploy modal_app.py
```

This continuously incurs H200 charges. To use another supported GPU:

```bash
MODAL_GPU=H100 modal deploy modal_app.py
```

## Security

The default deployment is public and has no login. Before sharing the URL, add
`GRADIO_USERNAME` and `GRADIO_PASSWORD` to the function environment or attach a
Modal Secret containing those keys in `modal_app.py`. Do not expose an unprotected
GPU application to untrusted users.

## Data and large uploads

Persistent data is stored in the `dnhacks-mapanything-data` Modal Volume mounted
at `/data`. Inspect it with:

```bash
modal volume ls dnhacks-mapanything-data
modal volume get dnhacks-mapanything-data outputs/live-SESSION.glb ./twin.glb
```

Browser uploads still pass through Modal and Gradio request limits. If a very
large upload cannot finish reliably, upload it directly to the Volume with the
Modal CLI and add a server-side import workflow; the current UI does not scan
arbitrary Volume files automatically.

## Notes

- The first image build installs the CUDA/Python dependencies and can take time.
- The first reconstruction downloads and caches the MapAnything checkpoint.
- Modal web executions are capped at 24 hours, but a deployed endpoint can start
  a replacement container. Persistent data survives container replacement.
- Incremental clips require substantial scene overlap for ICP registration.
