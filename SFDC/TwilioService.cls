public class TwilioService {
    
    // --- METHOD 1: SEND SMS ---
    // @future(callout=true) is CRITICAL.
    // It allows this to run in the background so the Controller can save data first.
    @future(callout=true)
    public static void sendSms(String toPhone, String msg) {
        Twilio_Settings__c settings = Twilio_Settings__c.getOrgDefaults();
        
        // Safety check
        if (settings == null || settings.Account_SID__c == null || settings.Auth_Token__c == null) {
            System.debug('Twilio Settings missing.');
            return;
        }

        String accountSid = settings.Account_SID__c;
        String token = settings.Auth_Token__c;
        String fromPhone = settings.Twilio_Phone_Number__c;

        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://api.twilio.com/2010-04-01/Accounts/' + accountSid + '/Messages.json');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Basic ' + EncodingUtil.base64Encode(Blob.valueOf(accountSid + ':' + token)));
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');

        String body = 'To=' + EncodingUtil.urlEncode(toPhone, 'UTF-8') +
                      '&From=' + EncodingUtil.urlEncode(fromPhone, 'UTF-8') +
                      '&Body=' + EncodingUtil.urlEncode(msg, 'UTF-8');
        req.setBody(body);

        Http http = new Http();
        try {
            HttpResponse res = http.send(req);
            System.debug('Twilio Response: ' + res.getBody());
        } catch (Exception e) {
            System.debug('Twilio Error: ' + e.getMessage());
        }
    }

    // --- METHOD 2: UPDATE CHAT CONTEXT ---
    // This MUST be @future because "Twilio_Settings__c" is a Setup Object.
    // Updating a Setup Object and a Normal Object (Booking__c) in the same transaction
    // causes a "MIXED DML" error. @future separates them into two transactions.
    @future
    public static void updateChatContext(String driverPhone) {
        if (String.isBlank(driverPhone)) return;
        
        Twilio_Settings__c settings = Twilio_Settings__c.getOrgDefaults();
        if (settings == null) settings = new Twilio_Settings__c();
        
        settings.Last_Driver_Phone__c = driverPhone;
        upsert settings;
    }
}
