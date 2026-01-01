public with sharing class TripEventProcessor implements Queueable {

    private final List<Id> eventIds;

    public TripEventProcessor(List<Id> eventIds) {
        this.eventIds = (eventIds == null) ? new List<Id>() : eventIds;
    }

    public static void enqueue(List<Trip_Event__c> events) {
        if (events == null || events.isEmpty()) return;

        List<Id> ids = new List<Id>();
        for (Trip_Event__c e : events) if (e.Id != null) ids.add(e.Id);

        if (!ids.isEmpty()) System.enqueueJob(new TripEventProcessor(ids));
    }

    public void execute(QueueableContext context) {
        TripEventHandler.process(eventIds);
    }
}
