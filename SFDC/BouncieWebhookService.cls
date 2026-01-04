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
            // 1. LIVE TRACKING LOGIC (tripData)
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

                    Datetime liveTimestamp = System.now();
                    if (latestPoint.get('timestamp') != null) {
                        liveTimestamp = (Datetime) JSON.deserialize('"' + String.valueOf(latestPoint.get('timestamp')) + '"', Datetime.class);
                    }

                    List<Tanks__c> tankToUpdate = [SELECT Id, Fuel_Limit__c FROM Tanks__c WHERE VIN__c = :vin LIMIT 1];
                    if (!tankToUpdate.isEmpty()) {
                        Tanks__c t = tankToUpdate[0];
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
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ok"}');
                return;
            }

            // --- LOCATION & FUEL SNAPSHOTS ---
            Tanks__c currentTank = [SELECT Id, Fuel_Limit__c, Location__Latitude__s, Location__Longitude__s FROM Tanks__c WHERE VIN__c = :vin LIMIT 1];
            
            if (eventType == 'tripStart') {
                Trip__c newTrip = new Trip__c(
                    Tank__c = currentTank.Id,
                    Transaction__c = txn,
                    Start_Time__c = System.now(),
                    Location_Start__Latitude__s = currentTank.Location__Latitude__s,
                    Location_Start__Longitude__s = currentTank.Location__Longitude__s
                );
                insert newTrip;
            } else if (eventType == 'tripEnd') {
                // Update Tank with final engine-off data
                if (body.containsKey('fuelLevelInput')) {
                    currentTank.Fuel_Level__c = Decimal.valueOf(String.valueOf(body.get('fuelLevelInput')));
                    Decimal limitVal = (currentTank.Fuel_Limit__c != null) ? currentTank.Fuel_Limit__c : 15.0;
                    currentTank.Fuel_Low__c = (currentTank.Fuel_Level__c <= limitVal);
                }
                Map<String,Object> endGps = (Map<String,Object>) body.get('gps');
                if (endGps != null) {
                    currentTank.Location__Latitude__s = (Double) endGps.get('lat');
                    currentTank.Location__Longitude__s = (Double) endGps.get('lon');
                }
                update currentTank;

                // Update Trip with Stop Location and Fuel Burned
                List<Trip__c> existingTrips = [SELECT Id FROM Trip__c WHERE Transaction__c = :txn LIMIT 1];
                if (!existingTrips.isEmpty()) {
                    existingTrips[0].Location_Stop__Latitude__s = currentTank.Location__Latitude__s;
                    existingTrips[0].Location_Stop__Longitude__s = currentTank.Location__Longitude__s;
                    if (body.get('fuelConsumed') != null) {
                        existingTrips[0].Total_Fuel__c = Decimal.valueOf(String.valueOf(body.get('fuelConsumed'))) * GAL_TO_LITERS;
                    }
                    update existingTrips[0];
                }
            }

            // --- LEGACY EVENT LOGGING ---
            Datetime ts = System.now();
            if (body.get('timestamp') != null) {
                ts = (Datetime) JSON.deserialize('"' + String.valueOf(body.get('timestamp')) + '"', Datetime.class);
            }

            Trip_Event__c ev = new Trip_Event__c();
            ev.Transaction__c = txn;
            ev.Event_Key__c   = txn + '|' + eventType + '|' + (ts.getTime() / 1000);
            ev.eventType__c   = eventType;
            ev.VIN__c         = vin;
            ev.timestamp__c   = ts;
            ev.Processed__c   = false;

            if (body.get('odometer') != null) ev.odometer__c = Decimal.valueOf(String.valueOf(body.get('odometer'))) * MILES_TO_KM;
            if (body.get('fuelConsumed') != null) ev.fuelConsumed__c = Decimal.valueOf(String.valueOf(body.get('fuelConsumed'))) * GAL_TO_LITERS;

            if (eventType == 'tripMetrics') {
                if (body.get('tripDistance') != null) ev.Trip_KM__c = Decimal.valueOf(String.valueOf(body.get('tripDistance'))) * MILES_TO_KM;
                if (body.get('tripTime') != null)     ev.Trip_Time__c = (Decimal.valueOf(String.valueOf(body.get('tripTime'))) * SECONDS_TO_MINUTES).setScale(1);
                if (body.get('maxSpeed') != null)     ev.Max_Speed__c = (Decimal.valueOf(String.valueOf(body.get('maxSpeed'))) * MPH_TO_KMH).setScale(0);
            }
            upsert ev Event_Key__c;

        } catch (Exception e) {
            System.debug('Error processing Bouncie Webhook: ' + e.getMessage());
        }
        res.statusCode = 200;
        res.responseBody = Blob.valueOf('{"status":"ok"}');
    }
}
