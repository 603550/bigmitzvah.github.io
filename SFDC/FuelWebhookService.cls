@RestResource(urlMapping='/FuelWebhook/*')
global without sharing class FuelWebhookService {

    @HttpPost
    global static void updatePrice() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        // 1. Get the key from your GASOLINE custom setting
        Gasoline__c gasCfg = Gasoline__c.getOrgDefaults();
        String sentKey = req.headers.get('x-api-key');
        
        // 2. Security Check against your specific field Webhook_Key__c
        if (gasCfg == null || String.isBlank(gasCfg.Webhook_Key__c) || sentKey != gasCfg.Webhook_Key__c) {
            res.statusCode = 401;
            res.responseBody = Blob.valueOf('{"status":"unauthorized"}');
            return;
        }

        try {
            Map<String, Object> json = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());
            Decimal price = (Decimal) json.get('price');

            // 3. Update using your exact field names: Gas_Price__c and Gas_Date__c
            if (price != null && price > 0) {
                gasCfg.Gas_Price__c = price;
                gasCfg.Gas_Date__c = System.today();
                upsert gasCfg;
            }

            res.statusCode = 200;
            res.responseBody = Blob.valueOf('{"status":"updated", "price": ' + price + '}');

        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"status":"error", "message":"' + e.getMessage() + '"}');
        }
    }
}
