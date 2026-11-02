/*
Expected compile failure with -preview=dip1000:
the callback-scoped RelationView reference must not escape a foreach body.
*/
module relation_foreach_view_escape;

import osm : PbfRelationIterable, RelationView;

RelationView* escaped;

@safe void escapeRelationView(PbfRelationIterable relations)
{
    foreach (scope ref RelationView relation; relations)
    {
        escaped = &relation;
        break;
    }
}
