/*
Expected compile failure with -preview=dip1000:
a WireCursor borrowing stack-local bytes must not escape the local lifetime.
*/
module wire_cursor_escape;

import osm.wire.cursor : WireCursor;

@safe WireCursor escapeCursor()
{
    ubyte[16] local;
    return WireCursor(local[]);
}
