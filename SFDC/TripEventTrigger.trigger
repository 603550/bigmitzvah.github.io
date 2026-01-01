trigger TripEventTrigger on Trip_Event__c (after insert) {
    TripEventProcessor.enqueue(Trigger.new);
}
