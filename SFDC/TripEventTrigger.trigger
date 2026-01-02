trigger TripEventTrigger on Trip_Event__c (after insert, after update) {

    Set<Id> ids = new Set<Id>();

    for (Trip_Event__c e : Trigger.new) {
        // only queue work when not processed
        if (e.Processed__c == false) {
            ids.add(e.Id);
        }
    }

    if (!ids.isEmpty()) {
        System.enqueueJob(new TripEventProcessor(ids));
    }
}
