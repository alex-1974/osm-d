# Compact store benchmarks

The M6 store benchmark contract is defined in
`../../docs/design/compact-store-contract.md` and ADR 0021.

The primary decision workload is the pinned `bremen-260901` Geofabrik
snapshot. Monaco/Liechtenstein are fast development workloads; Austria is a
later stress workload.

#62 will add executable reference/candidate configurations here. Benchmark code
must implement equivalent store capabilities before memory/performance ratios
are compared; an unindexed `OwnedDataset` is not an acceptable baseline for a
store that includes primary and parent indexes.

Required workload families are:

- build;
- typed primary lookup;
- parent lookup;
- full semantic traversal;
- deterministic 10,000-operation edit batch;
- local-ID remap.

The benchmark runner must use the repository's existing pinned dataset manifest
and general reproducibility rules. Large PBF inputs and result files remain
ignored and are never committed.
