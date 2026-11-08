# M19 replication fixtures

These fixtures are independently authored for osm-d qualification. They model
the semantic subset of official-style replication `state.txt` files admitted
by ADR 0034 and are not copied from a live OpenStreetMap feed.

They intentionally separate required continuation fields from historical
generator-internal fields so #150 can verify that the parser does not turn
Osmosis implementation details into stable public API.

Files:

- `state-minimal.txt` — required sequence/timestamp only;
- `state-extra-generator-fields.txt` — required fields plus ignorable
  historical transaction fields;
- `state-duplicate-sequence.txt` — invalid duplicate required field;
- `state-malformed-timestamp.txt` — invalid timestamp;
- `state-next.txt` — consecutive state for continuity qualification;
- `state-gap.txt` — deliberate sequence gap.

Timestamp values use escaped colons because that is the conventional replication
state-file representation documented for OpenStreetMap feeds.
