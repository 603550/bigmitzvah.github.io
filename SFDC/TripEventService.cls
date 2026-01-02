public without sharing class TripEventService {

    public static void process(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) return;

        // 1. Query Unprocessed Events
        List<Trip_Event__c> evs = [
            SELECT Id, Transaction__c, Event_Key__c, eventType__c, VIN__c, timestamp__c,
                   odometer__c, fuelConsumed__c, Trip_KM__c, Trip_Time__c, Idle_Time__c, 
                   Max_Speed__c, Avg_Speed__c, Hard_Brakes__c, Hard_Accel__c, Processed__c
            FROM Trip_Event__c
            WHERE Id IN :ids AND Processed__c = FALSE
        ];
        if (evs.isEmpty()) return;

        // 2. Group by Transaction
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

        // 3. Load Context (Tanks, Bookings, Existing Trips)
        Map<String, Tanks__c> tankByVin = new Map<String, Tanks__c>();
        if (!vins.isEmpty()) {
            for (Tanks__c t : [SELECT Id, VIN__c, KM__c FROM Tanks__c WHERE VIN__c IN :vins]) {
                tankByVin.put(t.VIN__c, t);
            }
        }

        Map<Id, Booking__c> activeBookingByTank = new Map<Id, Booking__c>();
        Map<Id, Booking__c> adminBookingByTank  = new Map<Id, Booking__c>();
        Set<Id> tankIds = new Set<Id>();
        for (Tanks__c t : tankByVin.values()) tankIds.add(t.Id);

        if (!tankIds.isEmpty()) {
            for (Booking__c b : [
                SELECT Id, Tank__c, Contact__c, Active__c, ADMIN__c
                FROM Booking__c
                WHERE Tank__c IN :tankIds
                ORDER BY CreatedDate DESC
            ]) {
                if (b.ADMIN__c == true) {
                    if (!adminBookingByTank.containsKey(b.Tank__c)) adminBookingByTank.put(b.Tank__c, b);
                } 
                else if (b.Active__c == true) {
                    if (!activeBookingByTank.containsKey(b.Tank__c)) activeBookingByTank.put(b.Tank__c, b);
                }
            }
        }

        Map<String, Trip__c> tripByTxn = new Map<String, Trip__c>();
        for (Trip__c t : [
            SELECT Id, Transaction__c, Active__c, VIN__c, Tank__c, Booking__c, Contact__c,
                   Start_Time__c, End_Time__c, KM_Start__c, KM_End__c, Total_Fuel__c,
                   flag__c // Load existing flag status
            FROM Trip__c
            WHERE Transaction__c IN :txns
        ]) {
            tripByTxn.put(t.Transaction__c, t);
        }

        // 4. Processing Loop
        List<Trip__c> tripUpserts = new List<Trip__c>();
        Map<Id, Decimal> tankKmUpdates = new Map<Id, Decimal>();

        for (String txn : byTxn.keySet()) {
            List<Trip_Event__c> txnEvents = byTxn.get(txn);
            txnEvents.sort(new TripEventTimestampComparator());

            String vin = null;
            for (Trip_Event__c e : txnEvents) { if (!String.isBlank(e.VIN__c)) { vin = e.VIN__c; break; } }
            Tanks__c tank = (vin != null) ? tankByVin.get(vin) : null;

            Booking__c booking = null;
            if (tank != null) {
                if (activeBookingByTank.containsKey(tank.Id)) booking = activeBookingByTank.get(tank.Id);
                else if (adminBookingByTank.containsKey(tank.Id)) booking = adminBookingByTank.get(tank.Id);
            }

            Trip__c trip = tripByTxn.get(txn);

            // Permissive Init
            if (trip == null) {
                Boolean hasSig = false;
                for (Trip_Event__c e : txnEvents) {
                    if (e.eventType__c == 'tripStart' || e.eventType__c == 'tripEnd') { hasSig = true; break; }
                }
                if (hasSig) trip = new Trip__c(Transaction__c = txn, flag__c = false);
            }

            if (trip == null) continue;

            // Update Header
            trip.VIN__c = vin;
            if (tank != null) trip.Tank__c = tank.Id;
            if (booking != null) {
                trip.Booking__c = booking.Id;
                trip.Contact__c = booking.Contact__c;
            }

            // Apply Events
            for (Trip_Event__c e : txnEvents) {
                
                // ---------------------------------------------------------
                // SAFETY FLAGGING LOGIC
                // ---------------------------------------------------------
                // Check Max Speed (>130 KM/h)
                if (e.Max_Speed__c != null && e.Max_Speed__c > 130) {
                    trip.flag__c = true;
                }
                // Check Hard Brakes (>0)
                if (e.Hard_Brakes__c != null && e.Hard_Brakes__c > 0) {
                    trip.flag__c = true;
                }
                // Check Hard Acceleration (>0)
                if (e.Hard_Accel__c != null && e.Hard_Accel__c > 0) {
                    trip.flag__c = true;
                }
                // Check Idle Time (> 60 minutes)
                // Note: Bouncie sends Idle Time in MINUTES usually, or if you converted to minutes in webhook
                // Assuming your field stores MINUTES:
                if (e.Idle_Time__c != null && e.Idle_Time__c > 60) {
                    trip.flag__c = true;
                }

                if (e.eventType__c == 'tripStart') {
                    trip.Start_Time__c = e.timestamp__c;
                    if (trip.End_Time__c == null) trip.Active__c = true;
                    if (tank != null) trip.KM_Start__c = tank.KM__c;
                }
                else if (e.eventType__c == 'tripEnd') {
                    trip.End_Time__c = e.timestamp__c;
                    trip.Active__c   = false;
                    
                    if (e.odometer__c != null) trip.KM_End__c = e.odometer__c;
                    if (e.fuelConsumed__c != null) trip.Total_Fuel__c = e.fuelConsumed__c;

                    if (tank != null && e.odometer__c != null) {
                        Decimal inc = e.odometer__c;
                        Decimal cur = tank.KM__c;
                        if (cur == null || inc >= cur) {
                            tankKmUpdates.put(tank.Id, inc);
                            tank.KM__c = inc;
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

        // 5. Commit (Partial Success Enabled)
        if (!tripUpserts.isEmpty()) Database.upsert(tripUpserts, Trip__c.Transaction__c, false);
        
        if (!tankKmUpdates.isEmpty()) {
            List<Tanks__c> tUp = new List<Tanks__c>();
            for(Id i : tankKmUpdates.keySet()) tUp.add(new Tanks__c(Id=i, KM__c=tankKmUpdates.get(i)));
            Database.update(tUp, false);
        }

        // 6. Mark Processed
        for (Trip_Event__c e : evs) e.Processed__c = true;
        update evs;
    }

    public class TripEventTimestampComparator implements System.Comparator<Trip_Event__c> {
        public Integer compare(Trip_Event__c a, Trip_Event__c b) {
            Datetime ta = a.timestamp__c, tb = b.timestamp__c;
            if (ta == null && tb == null) return 0;
            if (ta == null) return 1; if (tb == null) return -1;
            Long la = ta.getTime(), lb = tb.getTime();
            return (la == lb) ? 0 : (la < lb ? -1 : 1);
        }
    }
}
