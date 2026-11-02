/*
Expected compile failure with -preview=dip1000:
a PbfNodeIterable borrowing stack-local encoded bytes must not escape.
*/
module node_iterable_input_escape;

import osm : PbfNodeIterable, PbfReader;

@safe PbfNodeIterable escapeNodeIterable()
{
    ubyte[16] local;
    PbfReader reader;
    return reader.nodes(local[]);
}
