public with sharing class TripEventHandler {

    public static void process(List<Id> eventIds) {
        if (eventIds == null || eventIds.isEmpty()) return;

        List<Trip_Event__c> events = [
            SELECT Id, eventType__c, transactionId__c, VIN__c, imei__c, timestamp__c,
                   odometer__c, fuelConsumed__c,
                   Trip_KM__c, Trip_Time__c, Idle_Time__c, Max_Speed__c, Avg_Speed__c,
                   Hard_Brakes__c, Hard_Accel__c
            FROM Trip_Event__c
            WHERE Id IN :eventIds
        ];
        if (events.isEmpty()) return;

        List<Trip_Event__c> starts  = new List<Trip_Event__c>();
        List<Trip_Event__c> ends    = new List<Trip_Event__c>();
        List<Trip_Event__c> metrics = new List<Trip_Event__c>();

        Set<String> vins = new Set<String>();
        Set<String> txns = new Set<String>();

        for (Trip_Event__c e : events) {
            if (!String.isBlank(e.VIN__c)) vins.add(e.VIN__c);
            if (!String.isBlank(e.transactionId__c)) txns.add(e.transactionId__c);

            if (e.eventType__c == 'tripStart') starts.add(e);
            else if (e.eventType__c == 'tripEnd') ends.add(e);
            else if (e.eventType__c == 'tripMetrics') metrics.add(e);
        }

        if (!starts.isEmpty())  handleStarts(starts, vins);
        if (!metrics.isEmpty()) handleMetrics(metrics, txns);
        if (!ends.isEmpty())    handleEnds(ends, txns);
    }

    // --------------------------
    // START: upsert Trip__c by Transaction__c (External ID Unique)
    // --------------------------
    private static void handleStarts(List<Trip_Event__c> starts, Set<String> vins) {
        if (vins == null || vins.isEmpty()) return;

        Map<String, Booking__c> bookingByVin = new Map<String, Booking__c>();
        for (Booking__c b : [
            SELECT Id, Contact__c, Tank__c, Tank__r.VIN__c, Tank__r.KM__c
            FROM Booking__c
            WHERE Active__c = TRUE
              AND Tank__c != NULL
              AND Tank__r.VIN__c IN :vins
        ]) {
            if (b.Tank__r != null && !String.isBlank(b.Tank__r.VIN__c)) {
                bookingByVin.put(b.Tank__r.VIN__c, b);
            }
        }

        List<Trip__c> toUpsert = new List<Trip__c>();

        for (Trip_Event__c e : starts) {
            if (String.isBlank(e.transactionId__c) || String.isBlank(e.VIN__c)) continue;

            Booking__c b = bookingByVin.get(e.VIN__c);
            if (b == null) continue;

            Trip__c t = new Trip__c();
            t.Transaction__c = e.transactionId__c;   // UNIQUE External ID on Trip__c
            t.VIN__c         = e.VIN__c;
            t.Booking__c     = b.Id;
            t.Contact__c     = b.Contact__c;
            t.Tank__c        = b.Tank__c;
            t.Start_Time__c  = e.timestamp__c;
            t.KM_Start__c    = (b.Tank__r != null) ? b.Tank__r.KM__c : null;
            t.Active__c      = TRUE;

            toUpsert.add(t);
        }

        if (!toUpsert.isEmpty()) {
            upsert toUpsert Transaction__c;
        }
    }

    // --------------------------
    // METRICS: update Trip by Transaction__c
    // --------------------------
    private static void handleMetrics(List<Trip_Event__c> metrics, Set<String> txns) {
        if (txns == null || txns.isEmpty()) return;

        Map<String, Trip__c> tripByTxn = new Map<String, Trip__c>();
        for (Trip__c t : [
            SELECT Id, Transaction__c
            FROM Trip__c
            WHERE Transaction__c IN :txns
            ORDER BY Active__c DESC, CreatedDate DESC
        ]) {
            if (!tripByTxn.containsKey(t.Transaction__c)) tripByTxn.put(t.Transaction__c, t);
        }

        List<Trip__c> updates = new List<Trip__c>();

        for (Trip_Event__c e : metrics) {
            if (String.isBlank(e.transactionId__c)) continue;

            Trip__c t = tripByTxn.get(e.transactionId__c);
            if (t == null) continue;

            updates.add(new Trip__c(
                Id            = t.Id,
                Trip_KM__c    = e.Trip_KM__c,
                Trip_Time__c  = e.Trip_Time__c,
                Idle_Time__c  = e.Idle_Time__c,
                Max_Speed__c  = e.Max_Speed__c,
                Avg_Speed__c  = e.Avg_Speed__c,
                Hard_Brakes__c = e.Hard_Brakes__c,
                Hard_Accel__c  = e.Hard_Accel__c,
                Timestamp__c  = e.timestamp__c
            ));
        }

        if (!updates.isEmpty()) update updates;
    }

    // --------------------------
    // END: close Trip + update tank KM
    // --------------------------
    private static void handleEnds(List<Trip_Event__c> ends, Set<String> txns) {
        if (txns == null || txns.isEmpty()) return;

        Map<String, Trip_Event__c> endByTxn = new Map<String, Trip_Event__c>();
        for (Trip_Event__c e : ends) {
            if (!String.isBlank(e.transactionId__c)) endByTxn.put(e.transactionId__c, e);
        }
        if (endByTxn.isEmpty()) return;

        List<Trip__c> trips = [
            SELECT Id, Transaction__c, Tank__c, KM_Start__c, Active__c
            FROM Trip__c
            WHERE Transaction__c IN :txns
            ORDER BY Active__c DESC, CreatedDate DESC
        ];

        Map<String, Trip__c> bestTripByTxn = new Map<String, Trip__c>();
        for (Trip__c t : trips) {
            if (!bestTripByTxn.containsKey(t.Transaction__c)) bestTripByTxn.put(t.Transaction__c, t);
        }

        List<Trip__c> tripUpdates = new List<Trip__c>();
        Map<Id, Tanks__c> tankUpdates = new Map<Id, Tanks__c>();

        for (String txn : bestTripByTxn.keySet()) {
            Trip__c t = bestTripByTxn.get(txn);
            Trip_Event__c e = endByTxn.get(txn);
            if (t == null || e == null) continue;
            if (e.odometer__c == null) continue;

            // Guardrail: do not roll back odometer vs start
            if (t.KM_Start__c != null && e.odometer__c < t.KM_Start__c) continue;

            tripUpdates.add(new Trip__c(
                Id            = t.Id,
                End_Time__c   = e.timestamp__c,
                KM_End__c     = e.odometer__c,
                Total_Fuel__c = e.fuelConsumed__c,
                Active__c     = FALSE
            ));

            if (t.Tank__c != null) {
                tankUpdates.put(t.Tank__c, new Tanks__c(Id = t.Tank__c, KM__c = e.odometer__c));
            }
        }

        if (!tripUpdates.isEmpty()) update tripUpdates;
        if (!tankUpdates.isEmpty()) update tankUpdates.values();
    }
}
