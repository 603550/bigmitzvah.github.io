trigger TripEventTrigger on Trip_Event__c (after insert, after update) {
    TripEventProcessor.enqueue(Trigger.newMap.keySet());
}
