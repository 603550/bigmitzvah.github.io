@RestResource(urlMapping='/BouncieWebhook/*')
global without sharing class BouncieWebhookService {

    // Unit conversions
    private static final Decimal MILES_TO_KM   = 1.609344;
    private static final Decimal MPH_TO_KMH    = 1.609344;
    private static final Decimal GAL_TO_LITERS = 3.78541;
    private static final Decimal SECONDS_TO_MINUTES = 1.0 / 60.0;

    @HttpPost
    global static void handleWebhook() {

        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        // ALWAYS respond quickly
        res.addHeader('Content-Type', 'application/json');

        // ---- AUTH ----
        String key = req.headers.get('x-bouncie-authorization');
        if (String.isBlank(key)) key = req.headers.get('x-api-key');
        if (String.isBlank(key)) key = req.headers.get('Authorization');

        Bouncie_Settings__c cfg = Bouncie_Settings__c.getOrgDefaults();
        if (cfg == null || String.isBlank(cfg.Bouncie_Webhook_Key__c) || key != cfg.Bouncie_Webhook_Key__c) {
            res.statusCode = 200;
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

            if (String.isBlank(eventType) || String.isBlank(txn)) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ignored"}');
                return;
            }

            // =================================================================================
            // NEW: LIVE TRACKING LOGIC (tripData)
            // =================================================================================
            if (eventType == 'tripData') {
                List<Object> dataList = (List<Object>) p.get('data');
                
                // We only process the very last data point in the list (most recent)
                if (dataList != null && !dataList.isEmpty() && vin != null) {
                    Map<String,Object> latestPoint = (Map<String,Object>) dataList[dataList.size() - 1];
                    
                    // Extract GPS
                    Map<String,Object> gps = (Map<String,Object>) latestPoint.get('gps');
                    Double lat = (gps != null) ? (Double) gps.get('lat') : null;
                    Double lon = (gps != null) ? (Double) gps.get('lon') : null;
                    
                    // Extract Fuel
                    Object fuelObj = latestPoint.get('fuelLevelInput');
                    Decimal fuelLevel = (fuelObj != null) ? Decimal.valueOf(String.valueOf(fuelObj)) : null;

                    // Extract Timestamp
                    Datetime liveTimestamp = System.now();
                    if (latestPoint.get('timestamp') != null) {
                        liveTimestamp = safeParseIsoDatetime(String.valueOf(latestPoint.get('timestamp')), System.now());
                    }

                    // UPDATE TANK DIRECTLY
                    if (lat != null && lon != null) {
                        List<Tanks__c> tankToUpdate = [SELECT Id FROM Tanks__c WHERE VIN__c = :vin LIMIT 1];
                        if (!tankToUpdate.isEmpty()) {
                            Tanks__c t = tankToUpdate[0];
                            
                            // Map to your new fields
                            t.Location__Latitude__s = lat;
                            t.Location__Longitude__s = lon;
                            t.Timestamp__c = liveTimestamp;

                            if (fuelLevel != null) {
                                t.Fuel_Level__c = fuelLevel;
                            }
                            
                            update t;
                        }
                    }
                }

                // Stop here. Do not save history for live tracking.
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ok", "action":"live_update"}');
                return; 
            }
            // =================================================================================

            // ... EXISTING LOGIC FOR TRIP START / END / METRICS ...
            
            Map<String,Object> body;
            if (eventType == 'tripStart')      body = (Map<String,Object>) p.get('start');
            else if (eventType == 'tripEnd')   body = (Map<String,Object>) p.get('end');
            else if (eventType == 'tripMetrics') body = (Map<String,Object>) p.get('metrics');
            else body = null;

            Datetime ts = System.now();
            if (body != null && body.get('timestamp') != null) {
                ts = safeParseIsoDatetime(String.valueOf(body.get('timestamp')), System.now());
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

            if (body != null) {
                if (body.get('odometer') != null) {
                    ev.odometer__c = Decimal.valueOf(String.valueOf(body.get('odometer'))) * MILES_TO_KM;
                }
                if (body.get('fuelConsumed') != null) {
                    ev.fuelConsumed__c = Decimal.valueOf(String.valueOf(body.get('fuelConsumed'))) * GAL_TO_LITERS;
                }

                if (eventType == 'tripMetrics') {
                    if (body.get('tripDistance') != null) ev.Trip_KM__c = Decimal.valueOf(String.valueOf(body.get('tripDistance'))) * MILES_TO_KM;
                    if (body.get('tripTime') != null)     ev.Trip_Time__c = (Decimal.valueOf(String.valueOf(body.get('tripTime'))) * SECONDS_TO_MINUTES).setScale(1);
                    if (body.get('totalIdlingTime') != null) ev.Idle_Time__c = (Decimal.valueOf(String.valueOf(body.get('totalIdlingTime'))) * SECONDS_TO_MINUTES).setScale(1);
                    if (body.get('maxSpeed') != null)     ev.Max_Speed__c = (Decimal.valueOf(String.valueOf(body.get('maxSpeed'))) * MPH_TO_KMH).setScale(0);
                    if (body.get('averageDriveSpeed') != null) ev.Avg_Speed__c = (Decimal.valueOf(String.valueOf(body.get('averageDriveSpeed'))) * MPH_TO_KMH).setScale(0);
                    if (body.get('hardBrakingCounts') != null) ev.Hard_Brakes__c = Integer.valueOf(String.valueOf(body.get('hardBrakingCounts')));
                    if (body.get('hardAccelerationCounts') != null) ev.Hard_Accel__c = Integer.valueOf(String.valueOf(body.get('hardAccelerationCounts')));
                }
            }

            // DUPLICATE PROTECTION (Keep the higher Odometer)
            if (eventType == 'tripEnd' && ev.odometer__c != null) {
                List<Trip_Event__c> existingEvents = [SELECT Id, odometer__c FROM Trip_Event__c WHERE Event_Key__c = :eventKey LIMIT 1];
                if (!existingEvents.isEmpty()) {
                    Decimal oldOdo = existingEvents[0].odometer__c;
                    if (oldOdo != null && oldOdo > ev.odometer__c) {
                        ev.odometer__c = oldOdo;
                    }
                }
            }

            upsert ev Event_Key__c;

        } catch (Exception ignore) {}

        res.statusCode = 200;
        res.responseBody = Blob.valueOf('{"status":"ok"}');
    }

    private static Datetime safeParseIsoDatetime(String iso, Datetime fallback) {
        try {
            return (Datetime) JSON.deserialize('"' + iso + '"', Datetime.class);
        } catch (Exception e) {
            return fallback;
        }
    }
}
