@RestResource(urlMapping='/twilio-sms-reply/*')
global with sharing class TwilioWebhookService {

    @HttpPost
    global static void handleIncomingSms() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        try {
            // Read parameters directly from the request
            String fromNumberRaw = req.params.get('From');
            String messageBody = req.params.get('Body');

            if (!String.isBlank(fromNumberRaw) && !String.isBlank(messageBody)) {
                
                // --- NORMALIZE PHONE NUMBER ---
                // Strip all non-digit characters to get a clean number for matching.
                String normalizedFromNumber = fromNumberRaw.replaceAll('[^0-9]', '');
                if (normalizedFromNumber.length() > 10) {
                    normalizedFromNumber = normalizedFromNumber.right(10);
                }

                // --- UPDATED QUERY ---
                // Find the booking and also retrieve the related Tank ID.
                List<Booking__c> recentBookings = [
                    SELECT Id, Contact__c, Tank__c 
                    FROM Booking__c 
                    WHERE PhoneRaw__c = :normalizedFromNumber AND Status__c = 'Closed'
                    ORDER BY End_Time__c DESC LIMIT 1
                ];

                if (!recentBookings.isEmpty()) {
                    Booking__c targetBooking = recentBookings[0];

                    // --- UPDATED NOTE CREATION ---
                    // Create the new Note record, now including the Tank lookup.
                    Note__c newNote = new Note__c(
                        Booking__c = targetBooking.Id,
                        Contact__c = targetBooking.Contact__c,
                        Tank__c = targetBooking.Tank__c, // <-- THIS LINE IS NEW
                        Notes__c = messageBody,
                        DateTime__c = System.now()
                    );
                    insert newNote;
                }
            }
            
            // --- ALWAYS SEND A VALID RESPONSE TO TWILIO ---
            res.addHeader('Content-Type', 'text/plain; charset=utf-8');
            res.statusCode = 200; // Acknowledge receipt with "OK"
            res.responseBody = Blob.valueOf('Thank you');

        } catch (Exception e) {
            res.addHeader('Content-Type', 'text/plain; charset=utf-8');
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('An internal error occurred.');
            System.debug('Error in TwilioWebhookService: ' + e.getMessage());
        }
    }
}
