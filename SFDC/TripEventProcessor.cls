public with sharing class TripEventProcessor implements Queueable {

    private List<Id> eventIds;

    public TripEventProcessor(List<Id> eventIds) {
        this.eventIds = (eventIds == null) ? new List<Id>() : eventIds;
    }

    public static void enqueue(Set<Id> ids) {
        if (ids == null || ids.isEmpty()) return;
        System.enqueueJob(new TripEventProcessor(new List<Id>(ids)));
    }

    public void execute(QueueableContext ctx) {
        TripEventHandler.process(eventIds);
    }
}
