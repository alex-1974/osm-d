/**
 * Compatibility import for the v0.1 `WayNodeView` name.
 *
 * New code should import `osm.view.node_ref` and use `NodeRefView`. A Way
 * contains references to Nodes, not embedded Node objects.
 */
module osm.view.way_node;

public import osm.view.node_ref : NodeRefView;

/// v0.1 compatibility alias. Prefer NodeRefView.
alias WayNodeView = NodeRefView;
