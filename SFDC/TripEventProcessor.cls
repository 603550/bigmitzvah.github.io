public without sharing class TripEventProcessor implements Queueable {

    private Set<Id> eventIds;

    public TripEventProcessor(Set<Id> ids) {
        this.eventIds = (ids == null) ? new Set<Id>() : ids;
    }

    public void execute(QueueableContext qc) {
        TripEventService.process(eventIds);
    }
}
