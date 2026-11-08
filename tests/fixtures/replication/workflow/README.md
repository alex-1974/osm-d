# M19 replication workflow fixtures

These fixtures are authored specifically for the #152 end-to-end qualification.
They model ordinary OSM replication semantics without depending on the parser or
store implementation to construct the expected result.

The state sequence is 100 -> 104. State 101 and 102 deliberately carry the same
timestamp to demonstrate that sequence continuity, not wall-clock arithmetic,
controls progression.

The osmChange resources exercise:

- sequence 101: create plus Node/Way/Relation modification;
- sequence 102: two contiguous versions of one Node in reverse XML order;
- sequence 103: create, delete and parent-reference replacement;
- sequence 104: an exact already-known object version plus new authoritative
  Node/Relation versions;
- sequence 105 failure fixtures: one malformed osmChange document and one
  otherwise valid document that jumps Node 1 from version 5 to version 7.

The qualification runner converts the authored XML bytes to GZIP at runtime
with compression-d only to exercise the released compressed ingestion boundary.
Independent GZIP corruption/truncation behavior is already covered by the #151
fixture and compression-d's own v0.3.0 contract tests.

The expected final live snapshot after sequence 104 is:

```text
nodes=1@5,3@1,4@1
way=10@4[3,4]
relation=20@5[way:10,node:1]
```

Node 2 is an authoritative tombstone and therefore absent from live lookup.
Reverse parent indexes are checked after the reference-changing sequences.
