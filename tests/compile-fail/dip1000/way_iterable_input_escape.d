/*
Expected compile failure with -preview=dip1000:
a PbfWayIterable borrowing stack-local encoded bytes must not escape.
*/
module way_iterable_input_escape;

import osm : PbfReader, PbfWayIterable;

@safe PbfWayIterable escapeWayIterable()
{
    ubyte[16] local;
    PbfReader reader;
    return reader.ways(local[]);
}
