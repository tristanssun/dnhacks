# Reconstruction and Live-Stitching Status

## Existing GLB files

The smaller GLB is:

- File: `outputs/reconstruction-3f313164365b.glb`
- Exact size: 10,080,868 bytes (about 9.6 MiB)
- Input: 5 sampled frames
- Contents: 629,989 colored points and no mesh faces

The larger GLB is:

- File: `outputs/reconstruction-30f4b03778ed.glb`
- Exact size: 65,939,220 bytes (about 62.9 MiB)
- Input: 31 sampled frames
- Contents: 4,121,136 colored points and no mesh faces

The smaller file is a lower-density point-cloud reconstruction produced from
fewer frames. It predates the latest live-stitching changes and was not created
or modified by that work.

## Current latency

The UI checks for new clips every 10 seconds. This does **not** guarantee a
completed reconstruction every 10 seconds.

End-to-end update latency is approximately:

```text
up to 10 seconds waiting for the next check
+ video upload time
+ frame extraction
+ MapAnything inference
+ GLB generation and browser loading
```

The existing logs do not contain sufficient timing data for a reliable
MapAnything inference benchmark. Frame extraction took approximately 45 seconds
for a later 91-frame attempt, which ultimately ended with a bus error. A proper
end-to-end latency measurement requires running the updated service on the H200.

## Ten-second stitching implementation

The ten-second update feature was implemented and smoke-tested before permission
was requested to submit the six-hour Slurm job. That submission was interrupted,
so no new reconstruction was produced and there is no confirmed new running job.

The implementation currently:

- accepts successive overlapping video clips;
- checks for additions every 10 seconds;
- reconstructs only newly added clips;
- aligns each overlapping increment to the existing twin with similarity ICP;
- appends aligned points without reprocessing previous clips;
- prevents overlapping GPU reconstructions;
- atomically replaces the session's GLB; and
- preserves the original one-shot UI in a separate tab.

This is incremental clip-based reconstruction, not true real-time webcam SLAM.
Similarity ICP requires substantial scene overlap and can accumulate alignment
drift over many updates.
The code passed syntax and CPU ingestion/update tests, but the new path has not
yet been validated end-to-end on an H200 because the Slurm submission did not
complete.
