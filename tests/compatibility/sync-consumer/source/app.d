module app;

import osm.store : OsmStore;
import osm.sync;
import osm.model.owned :
    OwnedNode,
    OwnedRelation,
    OwnedWay;

@safe void main()
{
    NodeHistory nodeHistory;
    WayHistory wayHistory;
    RelationHistory relationHistory;
    HistoryStatus historyStatus;

    OwnedNode node;
    OwnedWay way;
    OwnedRelation relation;

    if (false)
    {
        NodeHistory.create(
            [node],
            HistoryCoverage.partial,
            nodeHistory,
            historyStatus);
        WayHistory.create(
            [way],
            HistoryCoverage.partial,
            wayHistory,
            historyStatus);
        RelationHistory.create(
            [relation],
            HistoryCoverage.partial,
            relationHistory,
            historyStatus);

        auto nodeReport = classifyConflict(
            NodeState.present(node),
            NodeState.present(node),
            NodeState.present(node));
        assert(!nodeReport.requiresResolution);

        AuthoritativeBatch batch;
        ReconcileResult result;
        ReconcileStatus status;
        reconcileAuthoritative(new OsmStore(), batch, result, status);
    }
}
