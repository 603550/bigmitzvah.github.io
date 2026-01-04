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
        res.addHeader('Content-Type', 'application/json');

        // --- AUTHENTICATION ---
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
            String imei      = (p.get('imei') == null) ? null : String.valueOf(p.get('imei'));

            if (String.isBlank(eventType) || String.isBlank(txn)) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ignored"}');
                return;
            }

            // =================================================================================
            // 1. LIVE TRACKING LOGIC (tripData) - RESTORED ROBUST VERSION
            // =================================================================================
            if (eventType == 'tripData') {
                List<Object> dataList = (List<Object>) p.get('data');
                if (dataList != null && !dataList.isEmpty() && vin != null) {
                    Map<String,Object> latestPoint = (Map<String,Object>) dataList[dataList.size() - 1];
                    Map<String,Object> gps = (Map<String,Object>) latestPoint.get('gps');
                    
                    Double lat = (gps != null) ? (Double) gps.get('lat') : null;
                    Double lon = (gps != null) ? (Double) gps.get('lon') : null;
                    
                    Decimal foundFuel = null;
                    for (Object obj : dataList) {
                        Map<String,Object> pt = (Map<String,Object>) obj;
                        if (pt.containsKey('fuelLevelInput')) {
                            foundFuel = Decimal.valueOf(String.valueOf(pt.get('fuelLevelInput')));
                        }
                    }

                    Datetime liveTimestamp = safeParseIsoDatetime(String.valueOf(latestPoint.get('timestamp')), System.now());

                    List<Tanks__c> tankList = [SELECT Id, Fuel_Limit__c FROM Tanks__c WHERE VIN__c = :vin LIMIT 1];
                    if (!tankList.isEmpty()) {
                        Tanks__c t = tankList[0];
                        if (lat != null && lon != null) {
                            t.Location__Latitude__s = lat;
                            t.Location__Longitude__s = lon;
                        }
                        t.Last_Use__c = liveTimestamp; 
                        if (foundFuel != null) {
                            t.Fuel_Level__c = foundFuel;
                            Decimal limitVal = (t.Fuel_Limit__c != null) ? t.Fuel_Limit__c : 15.0;
                            t.Fuel_Low__c = (foundFuel <= limitVal); 
                        }
                        update t;
                    }
                }
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ok", "action":"live_update"}');
                return; 
            }

            // =================================================================================
            // 2. HISTORICAL DATA HANDLING (tripStart, tripEnd, tripMetrics)
            // =================================================================================
            Map<String,Object> body;
            if (eventType == 'tripStart')      body = (Map<String,Object>) p.get('start');
            else if (eventType == 'tripEnd')    body = (Map<String,Object>) p.get('end');
            else if (eventType == 'tripMetrics') body = (Map<String,Object>) p.get('metrics');

            if (body == null) {
                res.statusCode = 200; res.responseBody = Blob.valueOf('{"status":"ok"}'); return;
            }

            Datetime ts = safeParseIsoDatetime(String.valueOf(body.get('timestamp')), System.now());
            Tanks__c currentTank = [SELECT Id, Location__Latitude__s, Location__Longitude__s FROM Tanks__c WHERE VIN__c = :vin LIMIT 1];

            // 2a. Update the Main Trip__c Record (GPS/Fuel Logic)
            List<Trip__c> existingTrips = [SELECT Id FROM Trip__c WHERE Transaction__c = :txn LIMIT 1];
            Trip__c targetTrip = (!existingTrips.isEmpty()) ? existingTrips[0] : new Trip__c(Transaction__c = txn, Tank__c = currentTank.Id);

            if (eventType == 'tripStart') {
                targetTrip.Location_Start__Latitude__s = currentTank.Location__Latitude__s;
                targetTrip.Location_Start__Longitude__s = currentTank.Location__Longitude__s;
                targetTrip.Start_Time__c = ts;
            } else if (eventType == 'tripEnd') {
                targetTrip.Location_Stop__Latitude__s = currentTank.Location__Latitude__s;
                targetTrip.Location_Stop__Longitude__s = currentTank.Location__Longitude__s;
                targetTrip.End_Time__c = ts;
                if (body.get('fuelConsumed') != null) {
                    targetTrip.Total_Fuel__c = (Decimal.valueOf(String.valueOf(body.get('fuelConsumed'))) * GAL_TO_LITERS).setScale(3);
                }
            } else if (eventType == 'tripMetrics') {
                targetTrip.Trip_KM__c = (Decimal.valueOf(String.valueOf(body.get('tripDistance'))) * MILES_TO_KM).setScale(1);
                targetTrip.Trip_Time__c = (Decimal.valueOf(String.valueOf(body.get('tripTime'))) * SECONDS_TO_MINUTES).setScale(1);
                targetTrip.Idle_Time__c = (Decimal.valueOf(String.valueOf(body.get('totalIdlingTime'))) * SECONDS_TO_MINUTES).setScale(1);
                targetTrip.Avg_Speed__c = (Decimal.valueOf(String.valueOf(body.get('averageDriveSpeed'))) * MPH_TO_KMH).setScale(0);
                targetTrip.Max_Speed__c = (Decimal.valueOf(String.valueOf(body.get('maxSpeed'))) * MPH_TO_KMH).setScale(0);
                targetTrip.Hard_Brakes__c = Integer.valueOf(String.valueOf(body.get('hardBrakingCounts')));
                targetTrip.Hard_Accel__c = Integer.valueOf(String.valueOf(body.get('hardAccelerationCounts')));
            }
            upsert targetTrip Transaction__c;

            // =================================================================================
            // 3. EVENT AUDIT LOGGING (With RESTORED Duplicate Odometer Protection)
            // =================================================================================
            String tsKey = String.valueOf(ts.getTime() / 1000);
            String eventKey = txn + '|' + eventType + '|' + tsKey;

            Trip_Event__c ev = new Trip_Event__c();
            ev.Transaction__c = txn;
            ev.VIN__c = vin;
            ev.imei__c = imei; 
            ev.eventType__c = eventType;
            ev.timestamp__c = ts;
            ev.Event_Key__c = eventKey;
            ev.Processed__c = false;

            if (body.get('odometer') != null) ev.odometer__c = Decimal.valueOf(String.valueOf(body.get('odometer'))) * MILES_TO_KM;
            if (body.get('fuelConsumed') != null) ev.fuelConsumed__c = (Decimal.valueOf(String.valueOf(body.get('fuelConsumed'))) * GAL_TO_LITERS).setScale(3);

            if (eventType == 'tripMetrics') {
                ev.Trip_KM__c = targetTrip.Trip_KM__c;
                ev.Trip_Time__c = targetTrip.Trip_Time__c;
                ev.Idle_Time__c = targetTrip.Idle_Time__c;
                ev.Avg_Speed__c = targetTrip.Avg_Speed__c;
                ev.Max_Speed__c = targetTrip.Max_Speed__c;
                ev.Hard_Brakes__c = targetTrip.Hard_Brakes__c;
                ev.Hard_Accel__c = targetTrip.Hard_Accel__c;
            }

            // RESTORED: ODOMETER PROTECTION (Keep the higher value if duplicate event arrives)
            if (eventType == 'tripEnd' && ev.odometer__c != null) {
                List<Trip_Event__c> existing = [SELECT Id, odometer__c FROM Trip_Event__c WHERE Event_Key__c = :eventKey LIMIT 1];
                if (!existing.isEmpty() && existing[0].odometer__c != null && existing[0].odometer__c > ev.odometer__c) {
                    ev.odometer__c = existing[0].odometer__c;
                }
            }

            upsert ev Event_Key__c;

        } catch (Exception e) {
            System.debug('Error processing Bouncie Webhook: ' + e.getMessage());
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf('{"status":"ok"}');
    }

    // RESTORED: HELPER METHOD
    private static Datetime safeParseIsoDatetime(String iso, Datetime fallback) {
        try {
            return (Datetime) JSON.deserialize('"' + iso + '"', Datetime.class);
        } catch (Exception e) {
            return fallback;
        }
    }
}
