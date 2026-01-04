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
                respondSilent(res); return;
            }

            // 1. Clean the Incoming Phone
            String digitsOnly = fromNumberRaw.replaceAll('[^0-9]', '');
            String last4 = (digitsOnly.length() >= 4) ? digitsOnly.right(4) : digitsOnly;
            String full10 = (digitsOnly.length() > 10) ? digitsOnly.right(10) : digitsOnly;
            String cleanIncoming = (digitsOnly.length() > 10) ? digitsOnly.right(10) : digitsOnly;

            // 2. CHECK: Is this from an ADMIN?
            // UPDATED: Querying FirstName
            List<Contact> admins = [
                SELECT Id, FirstName, MobilePhone 
                FROM Contact 
                WHERE Admin__c = TRUE 
                AND (MobilePhone LIKE :('%' + last4) OR MobilePhone LIKE :('%' + full10))
                LIMIT 1
            ];
            
            if (!admins.isEmpty()) {
                Contact c = admins[0];
                String adminClean = c.MobilePhone.replaceAll('[^0-9]', '');
                
                // Strict match check
                if (adminClean.endsWith(last4)) {
                    // UPDATED: Pass the specific Admin's First Name
                    String adminName = (c.FirstName != null) ? c.FirstName : 'Admin';
                    handleAdminReply(messageBody, adminName);
                } else {
                    handleDriverMessage(last4, messageBody, cleanIncoming);
                }
            } else {
                handleDriverMessage(last4, messageBody, cleanIncoming);
            }

            respondSilent(res);

        } catch (Exception e) {
            System.debug('Error: ' + e.getMessage());
            res.statusCode = 500;
        }
    }

    // --- HELPER: Handle Driver -> Admin ---
    private static void handleDriverMessage(String phoneLast4, String body, String fullIncomingNumber) {
        
        // 1. Find Booking
        List<Booking__c> bookings = [
            SELECT Id, Contact__r.FirstName, Contact__r.MobilePhone, Tank__r.Name, Active__c, Status__c, Contact__c, Tank__c
            FROM Booking__c 
            WHERE Contact__r.MobilePhone LIKE :('%' + phoneLast4) 
            ORDER BY CreatedDate DESC LIMIT 1
        ];

        // Scenario 1: Unknown Number
        if (bookings.isEmpty()) {
            String autoMsg = 'Thank you for contacting BigMitzvah.org, this phone number is not monitored. Please email info@BigMitzvah.org for more information. Thank you and have a nice day.';
            TwilioService.sendSms(fullIncomingNumber, autoMsg); 
            return; 
        }

        // Scenario 2: Driver Found
        Booking__c booking = bookings[0];
        Boolean isActive = (booking.Active__c == true);
        String noteType = isActive ? 'Message' : 'Feedback';

        // 2. Always Save Note
        Note__c newNote = new Note__c(
            Booking__c = booking.Id,
            Contact__c = booking.Contact__c,
            Tank__c = booking.Tank__c,
            Notes__c = body,
            Type__c = noteType,
            DateTime__c = System.now()
        );
        insert newNote;

        // 3. Conditional Forwarding
        if (isActive) {
            String firstName = (booking.Contact__r.FirstName != null) ? booking.Contact__r.FirstName : 'Driver';
            String driverFullPhone = booking.Contact__r.MobilePhone; 

            Twilio_Settings__c settings = Twilio_Settings__c.getOrgDefaults();
            if (settings == null) settings = new Twilio_Settings__c();
            settings.Last_Driver_Phone__c = driverFullPhone; 
            upsert settings;

            String forwardMsg = '[' + firstName + ']: ' + body;
            
            List<Contact> allAdmins = [SELECT MobilePhone FROM Contact WHERE Admin__c = TRUE AND MobilePhone != null];
            for (Contact a : allAdmins) {
                TwilioService.sendSms(a.MobilePhone, forwardMsg);
            }
        }
    }

    // --- HELPER: Handle Admin -> Driver ---
    // UPDATED: Now accepts 'adminName'
    private static void handleAdminReply(String body, String adminName) {
        Twilio_Settings__c settings = Twilio_Settings__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Last_Driver_Phone__c)) return;

        String targetDriverPhone = settings.Last_Driver_Phone__c;
        
        // UPDATED: Uses the actual First Name (e.g., "[David]: ...")
        String replyMsg = '[' + adminName + ']: ' + body;

        // 1. Send SMS
        TwilioService.sendSms(targetDriverPhone, replyMsg);

        // 2. Save Admin Note
        String targetLast4 = targetDriverPhone.replaceAll('[^0-9]', '');
        if (targetLast4.length() > 4) targetLast4 = targetLast4.right(4);

        List<Booking__c> bookings = [
            SELECT Id, Contact__c, Tank__c
            FROM Booking__c 
            WHERE Contact__r.MobilePhone LIKE :('%' + targetLast4) 
            ORDER BY CreatedDate DESC LIMIT 1
        ];

        if (!bookings.isEmpty()) {
            Note__c newNote = new Note__c(
                Booking__c = bookings[0].Id,
                Contact__c = bookings[0].Contact__c,
                Tank__c = bookings[0].Tank__c,
                Notes__c = replyMsg,
                Type__c = 'Message',
                DateTime__c = System.now()
            );
            insert newNote;
        }
    }

    private static void respondSilent(RestResponse res) {
        res.addHeader('Content-Type', 'text/xml');
        res.statusCode = 200;
        res.responseBody = Blob.valueOf('<Response></Response>');
    }
}
