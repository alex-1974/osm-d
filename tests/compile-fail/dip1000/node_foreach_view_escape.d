/*
Expected compile failure with -preview=dip1000:
the callback-scoped semantic NodeView must not escape a foreach body.
*/
module node_foreach_view_escape;

import osm :
    NodeView,
    PbfNodeIterable;

NodeView* escaped;

@safe void escapeNodeView(PbfNodeIterable nodes)
{
    foreach (scope ref NodeView node; nodes)
    {
        escaped = &node;
        break;
    }
}
