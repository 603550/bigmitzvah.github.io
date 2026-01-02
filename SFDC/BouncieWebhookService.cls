@RestResource(urlMapping='/BouncieWebhook/*')
global without sharing class BouncieWebhookService {

    private static final Decimal MILES_TO_KM   = 1.609344;
    private static final Decimal MPH_TO_KMH    = 1.609344;
    private static final Decimal GAL_TO_LITERS = 3.78541;
    private static final Decimal SECONDS_TO_MINUTES = 1.0 / 60.0;

    @HttpPost
    global static void handleWebhook() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        // --- AUTHENTICATION ---
        String key = req.headers.get('x-bouncie-authorization');
        if (String.isBlank(key)) key = req.headers.get('x-api-key');
        if (String.isBlank(key)) key = req.headers.get('Authorization');

        Bouncie_Settings__c cfg = Bouncie_Settings__c.getOrgDefaults();
        if (cfg == null || String.isBlank(cfg.Bouncie_Webhook_Key__c) || key != cfg.Bouncie_Webhook_Key__c) {
            res.statusCode = 200; // Return 200 to Bouncie to avoid retries on bad auth
            res.responseBody = Blob.valueOf('{"status":"ignored"}');
            return;
        }

        try {
            String raw = (req.requestBody == null) ? '' : req.requestBody.toString();
            Map<String,Object> root = (Map<String,Object>) JSON.deserializeUntyped(raw);
            Map<String,Object> p = root.containsKey('payload') ? (Map<String,Object>) root.get('payload') : root;

            String eventType = (p.get('eventType') == null) ? null : String.valueOf(p.get('eventType'));
            String vin       = (p.get('vin') == null) ? null : String.valueOf(p.get('vin'));
            String txn       = (p.get('transactionId') == null) ? null : String.valueOf(p.get('transactionId'));

            // =================================================================================
            // LIVE TRACKING LOGIC (tripData)
            // =================================================================================
            if (eventType == 'tripData') {
                List<Object> dataList = (List<Object>) p.get('data');
                
                if (dataList != null && !dataList.isEmpty() && vin != null) {
                    // 1. WHICH GPS? Using the VERY LAST point (most recent)
                    Map<String,Object> latestPoint = (Map<String,Object>) dataList[dataList.size() - 1];
                    Map<String,Object> gps = (Map<String,Object>) latestPoint.get('gps');
                    
                    Double lat = (gps != null) ? (Double) gps.get('lat') : null;
                    Double lon = (gps != null) ? (Double) gps.get('lon') : null;
                    
                    // 2. EXTRACT FUEL: Scan the whole list for any 'fuelLevelInput'
                    Decimal foundFuel = null;
                    for (Object obj : dataList) {
                        Map<String,Object> pt = (Map<String,Object>) obj;
                        if (pt.containsKey('fuelLevelInput')) {
                            foundFuel = Decimal.valueOf(String.valueOf(pt.get('fuelLevelInput')));
                            // Note: we don't break, so we get the most recent fuel in this packet
                        }
                    }

                    // 3. GET TIMESTAMP: From the latest GPS point
                    Datetime liveTimestamp = System.now();
                    if (latestPoint.get('timestamp') != null) {
                        liveTimestamp = (Datetime) JSON.deserialize('"' + String.valueOf(latestPoint.get('timestamp')) + '"', Datetime.class);
                    }

                    // 4. UPDATE TANK
                    List<Tanks__c> tankToUpdate = [SELECT Id FROM Tanks__c WHERE VIN__c = :vin LIMIT 1];
                    if (!tankToUpdate.isEmpty()) {
                        Tanks__c t = tankToUpdate[0];
                        if (lat != null && lon != null) {
                            t.Location__Latitude__s = lat;
                            t.Location__Longitude__s = lon;
                        }
                        t.Last_Use__c = liveTimestamp; // Syncing to your consolidated field
                        
                        if (foundFuel != null) {
                            t.Fuel_Level__c = foundFuel;
                        }
                        update t;
                    }
                }
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ok", "action":"live_update"}');
                return; 
            }

            // =================================================================================
            // HISTORICAL EVENTS (tripStart, tripEnd, tripMetrics)
            // =================================================================================
            Map<String,Object> body;
            if (eventType == 'tripStart')      body = (Map<String,Object>) p.get('start');
            else if (eventType == 'tripEnd')   body = (Map<String,Object>) p.get('end');
            else if (eventType == 'tripMetrics') body = (Map<String,Object>) p.get('metrics');

            if (body == null) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ignored"}');
                return;
            }

            Datetime ts = System.now();
            if (body.get('timestamp') != null) {
                ts = (Datetime) JSON.deserialize('"' + String.valueOf(body.get('timestamp')) + '"', Datetime.class);
            }

            String tsKey = String.valueOf(ts.getTime() / 1000);
            String eventKey = txn + '|' + eventType + '|' + tsKey;

            Trip_Event__c ev = new Trip_Event__c();
            ev.Transaction__c = txn;
            ev.Event_Key__c   = eventKey;
            ev.eventType__c   = eventType;
            ev.VIN__c         = vin;
            ev.timestamp__c   = ts;
            ev.Processed__c   = false;

            if (body.get('odometer') != null) ev.odometer__c = Decimal.valueOf(String.valueOf(body.get('odometer'))) * MILES_TO_KM;
            if (body.get('fuelConsumed') != null) ev.fuelConsumed__c = Decimal.valueOf(String.valueOf(body.get('fuelConsumed'))) * GAL_TO_LITERS;

            if (eventType == 'tripMetrics') {
                if (body.get('tripDistance') != null) ev.Trip_KM__c = Decimal.valueOf(String.valueOf(body.get('tripDistance'))) * MILES_TO_KM;
                if (body.get('tripTime') != null)     ev.Trip_Time__c = (Decimal.valueOf(String.valueOf(body.get('tripTime'))) * SECONDS_TO_MINUTES).setScale(1);
                if (body.get('totalIdlingTime') != null) ev.Idle_Time__c = (Decimal.valueOf(String.valueOf(body.get('totalIdlingTime'))) * SECONDS_TO_MINUTES).setScale(1);
                if (body.get('maxSpeed') != null)     ev.Max_Speed__c = (Decimal.valueOf(String.valueOf(body.get('maxSpeed'))) * MPH_TO_KMH).setScale(0);
                if (body.get('averageDriveSpeed') != null) ev.Avg_Speed__c = (Decimal.valueOf(String.valueOf(body.get('averageDriveSpeed'))) * MPH_TO_KMH).setScale(0);
                if (body.get('hardBrakingCounts') != null) ev.Hard_Brakes__c = Integer.valueOf(String.valueOf(body.get('hardBrakingCounts')));
                if (body.get('hardAccelerationCounts') != null) ev.Hard_Accel__c = Integer.valueOf(String.valueOf(body.get('hardAccelerationCounts')));
            }

            upsert ev Event_Key__c;

        } catch (Exception e) {
            System.debug('Bouncie Error: ' + e.getMessage());
        }
        res.statusCode = 200;
        res.responseBody = Blob.valueOf('{"status":"ok"}');
    }
}
