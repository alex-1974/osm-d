/*
Expected compile failure with -preview=dip1000:
the callback-scoped WayView reference must not escape a foreach body.
*/
module way_foreach_view_escape;

import osm : PbfWayIterable, WayView;

WayView* escaped;

@safe void escapeWayView(PbfWayIterable ways)
{
    foreach (scope ref WayView way; ways)
    {
        escaped = &way;
        break;
    }
}
