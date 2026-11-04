/*
Expected compile failure with -preview=dip1000:
a PbfRelationIterable borrowing stack-local encoded bytes must not escape.
*/
module relation_iterable_input_escape;

import osm : PbfReader, PbfRelationIterable;

@safe PbfRelationIterable escapeRelationIterable()
{
    ubyte[16] local;
    PbfReader reader;
    return reader.relations(local[]);
}
