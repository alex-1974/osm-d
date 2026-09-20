/*
Expected compile failure with -preview=dip1000:
a BlobHeaderView borrowing stack-local encoded bytes must not escape.
*/
module blob_header_escape;

import osm.io.pbf.blob_header :
    BlobHeaderView,
    decodeBlobHeader;
import osm.io.pbf.error : PbfStatus;

@safe BlobHeaderView escapeBlobHeader()
{
    ubyte[16] local;
    BlobHeaderView view;
    PbfStatus status;

    decodeBlobHeader(local[], view, status);
    return view;
}
