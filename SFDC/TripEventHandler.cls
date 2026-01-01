public with sharing class TripEventHandler {

    public static void process(List<Id> eventIds) {
        if (eventIds == null || eventIds.isEmpty()) return;

        List<Trip_Event__c> events = [
            SELECT Id, Processed__c, eventType__c, transactionId__c, VIN__c, imei__c, timestamp__c,
                   odometer__c, fuelConsumed__c,
                   Trip_KM__c, Trip_Time__c, Idle_Time__c, Max_Speed__c, Avg_Speed__c,
                   Hard_Brakes__c, Hard_Accel__c
            FROM Trip_Event__c
            WHERE Id IN :eventIds
        ];

        // Only work unprocessed
        List<Trip_Event__c> work = new List<Trip_Event__c>();
        for (Trip_Event__c e : events) if (e.Processed__c != true) work.add(e);
        if (work.isEmpty()) return;

        List<Trip_Event__c> starts  = new List<Trip_Event__c>();
        List<Trip_Event__c> ends    = new List<Trip_Event__c>();
        List<Trip_Event__c> metrics = new List<Trip_Event__c>();

        for (Trip_Event__c e : work) {
            if (e.eventType__c == 'tripStart') starts.add(e);
            else if (e.eventType__c == 'tripEnd') ends.add(e);
            else if (e.eventType__c == 'tripMetrics') metrics.add(e);
        }

        if (!starts.isEmpty())  handleStarts(starts);
        if (!metrics.isEmpty()) handleMetrics(metrics);
        if (!ends.isEmpty())    handleEnds(ends);

        // Mark processed (bulk)
        List<Trip_Event__c> done = new List<Trip_Event__c>();
        for (Trip_Event__c e : work) done.add(new Trip_Event__c(Id = e.Id, Processed__c = true));
        update done;
    }

    // ---------------- START ----------------
    private static void handleStarts(List<Trip_Event__c> events) {
        Set<String> vins = new Set<String>();
        for (Trip_Event__c e : events) if (!String.isBlank(e.VIN__c)) vins.add(e.VIN__c);
        if (vins.isEmpty()) return;

        Map<String, Booking__c> bookingByVin = new Map<String, Booking__c>();
        for (Booking__c b : [
            SELECT Id, Contact__c, Tank__c, Tank__r.VIN__c, Tank__r.KM__c
            FROM Booking__c
            WHERE Active__c = TRUE
              AND Tank__r.VIN__c IN :vins
        ]) {
            if (b.Tank__r != null && !String.isBlank(b.Tank__r.VIN__c)) {
                bookingByVin.put(b.Tank__r.VIN__c, b);
            }
        }

        List<Trip__c> upserts = new List<Trip__c>();

        for (Trip_Event__c e : events) {
            if (String.isBlank(e.transactionId__c) || String.isBlank(e.VIN__c)) continue;

            Booking__c b = bookingByVin.get(e.VIN__c);
            if (b == null) continue;

            // Prefer odometer from event if present; otherwise tank KM
            Decimal kmStart = (e.odometer__c != null) ? e.odometer__c : (b.Tank__r != null ? b.Tank__r.KM__c : null);

            upserts.add(new Trip__c(
                Transaction__c = e.transactionId__c,
                VIN__c         = e.VIN__c,
                Booking__c     = b.Id,
                Contact__c     = b.Contact__c,
                Tank__c        = b.Tank__c,
                Start_Time__c  = e.timestamp__c,
                KM_Start__c    = kmStart,
                Active__c      = true,
                Timestamp__c   = e.timestamp__c
            ));
        }

        if (!upserts.isEmpty()) upsert upserts Transaction__c;
    }

    // ---------------- END ----------------
    private static void handleEnds(List<Trip_Event__c> events) {
        Set<String> txns = new Set<String>();
        for (Trip_Event__c e : events) if (!String.isBlank(e.transactionId__c)) txns.add(e.transactionId__c);
        if (txns.isEmpty()) return;

        Map<String, Trip_Event__c> endByTxn = new Map<String, Trip_Event__c>();
        for (Trip_Event__c e : events) if (!String.isBlank(e.transactionId__c)) endByTxn.put(e.transactionId__c, e);

        List<Trip__c> trips = [
            SELECT Id, Transaction__c, Tank__c, KM_Start__c
            FROM Trip__c
            WHERE Transaction__c IN :txns
            ORDER BY Active__c DESC, CreatedDate DESC
        ];

        // Choose most relevant trip per txn (prefer active)
        Map<String, Trip__c> tripByTxn = new Map<String, Trip__c>();
        for (Trip__c t : trips) if (!tripByTxn.containsKey(t.Transaction__c)) tripByTxn.put(t.Transaction__c, t);

        List<Trip__c> tripUpdates = new List<Trip__c>();
        Map<Id, Tanks__c> tankUpdates = new Map<Id, Tanks__c>();

        for (String txn : tripByTxn.keySet()) {
            Trip__c t = tripByTxn.get(txn);
            Trip_Event__c e = endByTxn.get(txn);
            if (t == null || e == null) continue;

            if (e.odometer__c == null) continue;

            // Guardrail: never roll back odometer
            if (t.KM_Start__c != null && e.odometer__c < t.KM_Start__c) continue;

            Trip__c upd = new Trip__c(
                Id = t.Id,
                End_Time__c   = e.timestamp__c,
                KM_End__c     = e.odometer__c,
                Total_Fuel__c = e.fuelConsumed__c,
                Active__c     = false,
                Timestamp__c  = e.timestamp__c
            );
            tripUpdates.add(upd);

            if (t.Tank__c != null) {
                tankUpdates.put(t.Tank__c, new Tanks__c(
                    Id = t.Tank__c,
                    KM__c = e.odometer__c
                ));
            }
        }

        if (!tripUpdates.isEmpty()) update tripUpdates;
        if (!tankUpdates.isEmpty()) update tankUpdates.values();
    }

    // ---------------- METRICS ----------------
    private static void handleMetrics(List<Trip_Event__c> events) {
        Set<String> txns = new Set<String>();
        for (Trip_Event__c e : events) if (!String.isBlank(e.transactionId__c)) txns.add(e.transactionId__c);
        if (txns.isEmpty()) return;

        List<Trip__c> trips = [
            SELECT Id, Transaction__c
            FROM Trip__c
            WHERE Transaction__c IN :txns
            ORDER BY Active__c DESC, CreatedDate DESC
        ];

        Map<String, Trip__c> tripByTxn = new Map<String, Trip__c>();
        for (Trip__c t : trips) if (!tripByTxn.containsKey(t.Transaction__c)) tripByTxn.put(t.Transaction__c, t);

        List<Trip__c> updates = new List<Trip__c>();

        for (Trip_Event__c e : events) {
            Trip__c t = tripByTxn.get(e.transactionId__c);
            if (t == null) showIgnore(e, 'no trip found'); // optional debug hook
            if (t == null) continue;

            updates.add(new Trip__c(
                Id = t.Id,
                Trip_KM__c      = e.Trip_KM__c,
                Trip_Time__c    = e.Trip_Time__c,
                Idle_Time__c    = e.Idle_Time__c,
                Max_Speed__c    = e.Max_Speed__c,
                Avg_Speed__c    = e.Avg_Speed__c,
                Hard_Brakes__c  = e.Hard_Brakes__c,
                Hard_Accel__c   = e.Hard_Accel__c,
                Timestamp__c    = e.timestamp__c
            ));
        }

        if (!updates.isEmpty()) update updates;
    }

    // Keep logs quiet unless you explicitly want them
    private static void showIgnore(Trip_Event__c e, String reason) {
        // System.debug('TripEventHandler ignore: ' + reason + ' eventId=' + e.Id);
    }
}
