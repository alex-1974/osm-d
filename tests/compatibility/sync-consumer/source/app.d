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
        auto nodeVersion = HistoricalNodeVersion.fromOwned(node);
        auto wayVersion = HistoricalWayVersion.fromOwned(way);
        auto relationVersion =
            HistoricalRelationVersion.fromOwned(relation);

        NodeHistory.create(
            [nodeVersion],
            HistoryCoverage.partial,
            nodeHistory,
            historyStatus);
        WayHistory.create(
            [wayVersion],
            HistoryCoverage.partial,
            wayHistory,
            historyStatus);
        RelationHistory.create(
            [relationVersion],
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
