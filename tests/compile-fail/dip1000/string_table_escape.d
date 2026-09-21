/*
Expected compile failure with -preview=dip1000:
a StringTableView borrowing stack-local raw/index storage must not escape.
*/
module string_table_escape;

import osm.io.pbf.string_table :
    StringRef,
    StringTableView;

@safe StringTableView escapeStringTable()
{
    ubyte[16] raw;
    StringRef[1] refs;

    StringTableView table;
    table.rawBlock = raw[];
    table.entries = refs[];
    return table;
}
