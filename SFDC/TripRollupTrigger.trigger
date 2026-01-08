trigger TripRollupTrigger on Trip__c (after insert, after update, after delete, after undelete) {
    
    // 1. Collect Booking IDs involved in this transaction
    Set<Id> bookingIds = new Set<Id>();

    if (Trigger.isInsert || Trigger.isUndelete) {
        for (Trip__c t : Trigger.new) {
            if (t.Booking__c != null) bookingIds.add(t.Booking__c);
        }
    }
    
    if (Trigger.isUpdate) {
        for (Trip__c t : Trigger.new) {
            if (t.Booking__c != null) bookingIds.add(t.Booking__c);
            // Handle reparenting (if a trip is moved to a different booking)
            if (Trigger.oldMap.get(t.Id).Booking__c != null && Trigger.oldMap.get(t.Id).Booking__c != t.Booking__c) {
                bookingIds.add(Trigger.oldMap.get(t.Id).Booking__c);
            }
        }
    }
    
    if (Trigger.isDelete) {
        for (Trip__c t : Trigger.old) {
            if (t.Booking__c != null) bookingIds.add(t.Booking__c);
        }
    }

    if (bookingIds.isEmpty()) return;

    // 2. Initialize Bookings to Zero
    // This ensures that if you delete the last trip, the Booking resets to 0 instead of staying stale.
    Map<Id, Booking__c> bookingsToUpdate = new Map<Id, Booking__c>();
    for (Id bId : bookingIds) {
        bookingsToUpdate.put(bId, new Booking__c(
            Id = bId,
            Total_KM__c = 0,
            Total_Time__c = 0,
            Total_Fuel__c = 0,    
            Total_Trips__c = 0,
            Total_Flags__c = 0,
            Flag__c = false       // Default to clean/unflagged
        ));
    }

    // 3. Aggregate Query 1: Standard Sums & Counts
    for (AggregateResult ar : [
        SELECT Booking__c,
               SUM(Trip_KM__c) totalDist,
               SUM(Trip_Time__c) totalTime,
               SUM(Total_Fuel__c) totalFuel,
               COUNT(Id) totalCount
        FROM Trip__c
        WHERE Booking__c IN :bookingIds
        GROUP BY Booking__c
    ]) {
        Id bId = (Id)ar.get('Booking__c');
        Booking__c b = bookingsToUpdate.get(bId);
        
        b.Total_KM__c = (Decimal)ar.get('totalDist');
        b.Total_Time__c = (Decimal)ar.get('totalTime');
        b.Total_Fuel__c = (Decimal)ar.get('totalFuel'); 
        b.Total_Trips__c = (Decimal)ar.get('totalCount');
    }

    // 4. Aggregate Query 2: Safety Flags
    for (AggregateResult ar : [
        SELECT Booking__c, COUNT(Id) flagCount
        FROM Trip__c
        WHERE Booking__c IN :bookingIds 
        AND Flag__c = TRUE
        GROUP BY Booking__c
    ]) {
        Id bId = (Id)ar.get('Booking__c');
        Booking__c b = bookingsToUpdate.get(bId);
        
        Decimal count = (Decimal)ar.get('flagCount');
        b.Total_Flags__c = count;
        
        if (count > 0) {
            b.Flag__c = true;
        }
    }

    // 5. Save Changes
    if (!bookingsToUpdate.isEmpty()) {
        update bookingsToUpdate.values();
    }
}
