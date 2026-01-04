@RestResource(urlMapping='/twilio-sms-reply/*')
global without sharing class TwilioWebhookService {

    @HttpPost
    global static void handleIncomingSms() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        
        try {
            String fromNumberRaw = req.params.get('From');
            String messageBody = req.params.get('Body');
            
            if (String.isBlank(fromNumberRaw) || String.isBlank(messageBody)) {
                respondOK(res); return;
            }

            // 1. Normalize Phone
            String incomingPhone = fromNumberRaw.replaceAll('[^0-9]', '');
            if (incomingPhone.length() > 10) incomingPhone = incomingPhone.right(10);

            // 2. CHECK: Is this from an ADMIN?
            List<Contact> admins = [SELECT Id, Name FROM Contact WHERE MobilePhone LIKE :('%' + incomingPhone) AND Admin__c = TRUE LIMIT 1];
            
            if (!admins.isEmpty()) {
                handleAdminReply(messageBody);
            } else {
                handleDriverMessage(incomingPhone, messageBody);
            }

            respondOK(res);

        } catch (Exception e) {
            System.debug('Error: ' + e.getMessage());
            res.statusCode = 500;
        }
    }

    // --- HELPER: Handle Driver -> Admin ---
    private static void handleDriverMessage(String driverPhone, String body) {
        
        // 1. Fetch the MOST RECENT booking (Active or Closed)
        List<Booking__c> bookings = [
            SELECT Id, Contact__r.Name, Tank__r.Name, Status__c, Contact__c, Tank__c
            FROM Booking__c 
            WHERE Contact__r.MobilePhone LIKE :('%' + driverPhone) 
            ORDER BY CreatedDate DESC LIMIT 1
        ];

        String driverName = (!bookings.isEmpty()) ? bookings[0].Contact__r.Name : 'Unknown Driver';

        // 2. Update Chat State (Using Twilio_Settings__c now)
        Twilio_Settings__c settings = Twilio_Settings__c.getOrgDefaults();
        if (settings == null) settings = new Twilio_Settings__c();
        settings.Last_Driver_Phone__c = driverPhone;
        upsert settings;

        // 3. Forward to Admins: "[David]: Where are the keys?"
        String forwardMsg = '[' + driverName + ']: ' + body;
        
        List<Contact> admins = [SELECT MobilePhone FROM Contact WHERE Admin__c = TRUE AND MobilePhone != null];
        for (Contact a : admins) {
            TwilioService.sendSms(a.MobilePhone, forwardMsg);
        }

        // 4. ALWAYS SAVE THE NOTE
        if (!bookings.isEmpty()) {
            Note__c newNote = new Note__c(
                Booking__c = bookings[0].Id,
                Contact__c = bookings[0].Contact__c,
                Tank__c = bookings[0].Tank__c,
                Notes__c = body,
                DateTime__c = System.now()
            );
            insert newNote;
        }
    }

    // --- HELPER: Handle Admin -> Driver ---
    private static void handleAdminReply(String body) {
        Twilio_Settings__c settings = Twilio_Settings__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Last_Driver_Phone__c)) return;

        String targetDriverPhone = settings.Last_Driver_Phone__c;
        String replyMsg = 'BigMitzvah: ' + body;

        TwilioService.sendSms(targetDriverPhone, replyMsg);
    }

    private static void respondOK(RestResponse res) {
        res.addHeader('Content-Type', 'text/plain');
        res.statusCode = 200;
        res.responseBody = Blob.valueOf('OK');
    }
}
