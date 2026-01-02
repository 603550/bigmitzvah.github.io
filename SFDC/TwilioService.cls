public with sharing class TwilioService {

    /**
     * @description Sends an SMS message using Twilio. Marked as @future(callout=true) 
     * to allow it to be called from triggers or other methods that don't permit direct callouts.
     * @param phoneNumber The destination phone number.
     * @param messageBody The text of the message to send.
     */
    @future(callout=true)
    public static void sendSms(String phoneNumber, String messageBody) {
        // Get credentials securely from Custom Settings
        Twilio_Settings__c settings = Twilio_Settings__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Account_SID__c) || String.isBlank(settings.Auth_Token__c) || String.isBlank(settings.Twilio_Phone_Number__c)) {
            System.debug('ERROR: Twilio settings are incomplete in Custom Settings.');
            return;
        }

        String accountSid = settings.Account_SID__c;
        String authToken = settings.Auth_Token__c;
        String fromNumber = settings.Twilio_Phone_Number__c;

        // Construct the Twilio API endpoint
        String endpoint = 'https://api.twilio.com/2010-04-01/Accounts/' + accountSid + '/Messages.json';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        
        // Set the required authentication header
        String authHeader = 'Basic ' + EncodingUtil.base64Encode(Blob.valueOf(accountSid + ':' + authToken));
        req.setHeader('Authorization', authHeader);
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');

        // Construct the request body
        String body = 'To=' + EncodingUtil.urlEncode(phoneNumber, 'UTF-8') +
                      '&From=' + EncodingUtil.urlEncode(fromNumber, 'UTF-8') +
                      '&Body=' + EncodingUtil.urlEncode(messageBody, 'UTF-8');
        req.setBody(body);

        Http http = new Http();
        try {
            HttpResponse res = http.send(req);
            System.debug('Twilio Response Status Code: ' + res.getStatusCode());
            System.debug('Twilio Response Body: ' + res.getBody());
        } catch (Exception e) {
            System.debug('Twilio Callout Failed: ' + e.getMessage());
        }
    }
}
