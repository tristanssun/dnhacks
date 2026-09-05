# DNHacks V2 Modal Package

The Modal-ready package is available as:

`DNHacks_V2_Modal.zip`

## Included features

- `modal_app.py` with H200/H100 configuration
- Persistent Modal Volume storage
- Scale-to-zero or continuously warm operation
- Persistent model caches, uploads, sessions, and GLBs
- Configurable data paths
- Optional Gradio authentication support
- Complete deployment instructions in `MODAL.md`
- Existing Slurm support
- Vendored MapAnything source
- Incremental ICP stitching

## Basic deployment

```bash
unzip DNHacks_V2_Modal.zip
cd DNHacks
python -m pip install modal
modal setup
modal serve modal_app.py
```

## Persistent deployment

```bash
modal deploy modal_app.py
```

## Keep an H200 continuously allocated

```bash
MODAL_KEEP_WARM=1 modal deploy modal_app.py
```

Keeping an H200 continuously allocated incurs GPU charges even while the
application is idle. Without `MODAL_KEEP_WARM=1`, the public endpoint remains
deployed but the GPU can scale to zero and require a cold start on its next use.

## Validation status

The archive is approximately 15 MB and passed archive-integrity, Python syntax,
video-ingestion, and incremental-merge smoke tests. The actual Modal image build
and H200 reconstruction still need validation using a Modal account.
