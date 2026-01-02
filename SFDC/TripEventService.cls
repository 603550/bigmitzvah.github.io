public without sharing class TripEventService {

    public static void process(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) return;

        // Pull unprocessed events
        List<Trip_Event__c> evs = [
            SELECT Id,
                   Transaction__c,
                   Event_Key__c,
                   eventType__c,
                   VIN__c,
                   timestamp__c,
                   odometer__c,
                   fuelConsumed__c,
                   Trip_KM__c, Trip_Time__c, Idle_Time__c, Max_Speed__c, Avg_Speed__c, Hard_Brakes__c, Hard_Accel__c,
                   Processed__c
            FROM Trip_Event__c
            WHERE Id IN :ids
              AND Processed__c = FALSE
        ];
        if (evs.isEmpty()) return;

        // Group events by transactionId
        Map<String, List<Trip_Event__c>> byTxn = new Map<String, List<Trip_Event__c>>();
        Set<String> txns = new Set<String>();
        Set<String> vins = new Set<String>();

        for (Trip_Event__c e : evs) {
            if (String.isBlank(e.Transaction__c)) continue;
            txns.add(e.Transaction__c);
            if (!String.isBlank(e.VIN__c)) vins.add(e.VIN__c);

            if (!byTxn.containsKey(e.Transaction__c)) {
                byTxn.put(e.Transaction__c, new List<Trip_Event__c>());
            }
            byTxn.get(e.Transaction__c).add(e);
        }

        if (byTxn.isEmpty()) {
            for (Trip_Event__c e : evs) e.Processed__c = true;
            update evs;
            return;
        }

        // VIN -> Tank
        Map<String, Tanks__c> tankByVin = new Map<String, Tanks__c>();
        if (!vins.isEmpty()) {
            for (Tanks__c t : [
                SELECT Id, VIN__c, KM__c
                FROM Tanks__c
                WHERE VIN__c IN :vins
            ]) {
                tankByVin.put(t.VIN__c, t);
            }
        }

        // Tank -> (Active booking) and (Admin booking)
        Map<Id, Booking__c> activeBookingByTank = new Map<Id, Booking__c>();
        Map<Id, Booking__c> adminBookingByTank  = new Map<Id, Booking__c>();

        Set<Id> tankIds = new Set<Id>();
        for (Tanks__c t : tankByVin.values()) tankIds.add(t.Id);

        if (!tankIds.isEmpty()) {
            for (Booking__c b : [
                SELECT Id, Tank__c, Contact__c, Active__c, ADMIN__c
                FROM Booking__c
                WHERE Tank__c IN :tankIds
            ]) {
                if (b.Active__c == true && !activeBookingByTank.containsKey(b.Tank__c)) {
                    activeBookingByTank.put(b.Tank__c, b);
                }
                if (b.ADMIN__c == true && !adminBookingByTank.containsKey(b.Tank__c)) {
                    adminBookingByTank.put(b.Tank__c, b);
                }
            }
        }

        // Existing trips by transaction
        Map<String, Trip__c> tripByTxn = new Map<String, Trip__c>();
        for (Trip__c t : [
            SELECT Id, Transaction__c, Active__c,
                   VIN__c, Tank__c, Booking__c, Contact__c,
                   Start_Time__c, End_Time__c, KM_Start__c, KM_End__c,
                   Trip_KM__c, Trip_Time__c, Idle_Time__c, Max_Speed__c, Avg_Speed__c, Hard_Brakes__c, Hard_Accel__c, Timestamp__c,
                   Total_Fuel__c
            FROM Trip__c
            WHERE Transaction__c IN :txns
        ]) {
            tripByTxn.put(t.Transaction__c, t);
        }

        List<Trip__c> tripUpserts = new List<Trip__c>();

        // Tank updates (final DML)
        Map<Id, Decimal> tankKmUpdates = new Map<Id, Decimal>();

        for (String txn : byTxn.keySet()) {

            List<Trip_Event__c> txnEvents = byTxn.get(txn);
            // FIXED: Using the corrected comparator
            txnEvents.sort(new TripEventTimestampComparator());

            // Determine VIN (first non-blank VIN in this txn)
            String vin = null;
            for (Trip_Event__c e : txnEvents) {
                if (!String.isBlank(e.VIN__c)) { vin = e.VIN__c; break; }
            }

            Tanks__c tank = (vin != null) ? tankByVin.get(vin) : null;

            Booking__c booking = null;
            if (tank != null) {
                booking = activeBookingByTank.containsKey(tank.Id)
                    ? activeBookingByTank.get(tank.Id)
                    : adminBookingByTank.get(tank.Id);
            }

            Trip__c trip = tripByTxn.containsKey(txn) ? tripByTxn.get(txn) : new Trip__c();

            // CRITICAL: always set Transaction__c so upsert never fails
            trip.Transaction__c = txn;

            // Attach VIN/Tank/Booking/Contact
            trip.VIN__c = vin;
            if (tank != null) trip.Tank__c = tank.Id;

            if (booking != null) {
                trip.Booking__c = booking.Id;
                trip.Contact__c = booking.Contact__c;
            }

            // Apply event updates in chronological order
            for (Trip_Event__c e : txnEvents) {

                if (e.eventType__c == 'tripStart') {
                    trip.Start_Time__c = e.timestamp__c;
                    trip.Active__c     = true;

                    // FEATURE: tripStart reads Tank.KM__c for KM_Start__c
                    if (tank != null) {
                        trip.KM_Start__c = tank.KM__c;
                    }
                }
                else if (e.eventType__c == 'tripEnd') {
                    trip.End_Time__c = e.timestamp__c;
                    trip.Active__c   = false;

                    if (e.odometer__c != null) {
                        trip.KM_End__c = e.odometer__c;
                    }

                    if (e.fuelConsumed__c != null) {
                        trip.Total_Fuel__c = e.fuelConsumed__c;
                    }

                    // FEATURE: tripEnd writes odometer__c to Tank.KM__c
                    if (tank != null && e.odometer__c != null) {
                        Decimal incoming = e.odometer__c;
                        Decimal current  = tank.KM__c;

                        // Only move forward (or initialise)
                        if (current == null || incoming >= current) {
                            tankKmUpdates.put(tank.Id, incoming);
                            tank.KM__c = incoming; // IMPORTANT: affects subsequent tripStart in this same execution
                        }
                    }
                }
                else if (e.eventType__c == 'tripMetrics') {
                    trip.Trip_KM__c      = e.Trip_KM__c;
                    trip.Trip_Time__c    = e.Trip_Time__c;
                    trip.Idle_Time__c    = e.Idle_Time__c;
                    trip.Max_Speed__c    = e.Max_Speed__c;
                    trip.Avg_Speed__c    = e.Avg_Speed__c;
                    trip.Hard_Brakes__c  = e.Hard_Brakes__c;
                    trip.Hard_Accel__c   = e.Hard_Accel__c;
                    trip.Timestamp__c    = e.timestamp__c;
                }
            }

            tripUpserts.add(trip);
        }

        if (!tripUpserts.isEmpty()) {
            upsert tripUpserts Transaction__c;
        }

        // Apply Tank KM updates
        if (!tankKmUpdates.isEmpty()) {
            List<Tanks__c> tankDml = new List<Tanks__c>();
            for (Id tankId : tankKmUpdates.keySet()) {
                tankDml.add(new Tanks__c(
                    Id = tankId,
                    KM__c = tankKmUpdates.get(tankId)
                ));
            }
            update tankDml;
        }

        // Mark processed
        for (Trip_Event__c e : evs) e.Processed__c = true;
        update evs;
    }

    // -------------------------------------------------------------------------
    // FIXED COMPARATOR - Do not change this back to the "Object" version
    // -------------------------------------------------------------------------
    public class TripEventTimestampComparator implements System.Comparator<Trip_Event__c> {
        
        public Integer compare(Trip_Event__c a, Trip_Event__c b) {
            Datetime ta = a.timestamp__c;
            Datetime tb = b.timestamp__c;

            if (ta == null && tb == null) return 0;
            if (ta == null) return 1;
            if (tb == null) return -1;

            Long la = ta.getTime();
            Long lb = tb.getTime();
            
            if (la == lb) return 0;
            return (la < lb) ? -1 : 1;
        }
    }
}
