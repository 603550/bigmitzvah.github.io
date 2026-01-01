@RestResource(urlMapping='/BouncieWebhook/*')
global WITHOUT SHARING class BouncieWebhookService {

    private static final Decimal MILES_TO_KM        = 1.609344;
    private static final Decimal MPH_TO_KMH         = 1.609344;
    private static final Decimal GAL_TO_LITERS      = 3.78541;
    private static final Decimal SECONDS_TO_MINUTES = 1.0 / 60.0;

    private static final Integer MAX_EVENT_AGE_MINUTES = 10;

    @HttpPost
    global static void handleWebhook() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        // --- SECURITY (only case we return non-200) ---
        String apiKey = req.headers.get('x-bouncie-authorization');
        if (String.isBlank(apiKey)) apiKey = req.headers.get('x-api-key');
        if (String.isBlank(apiKey)) apiKey = req.headers.get('Authorization');

        Bouncie_Settings__c settings = Bouncie_Settings__c.getOrgDefaults();
        String expectedKey = (settings != null) ? settings.Bouncie_Webhook_Key__c : null;

        if (String.isBlank(apiKey) || String.isBlank(expectedKey) || apiKey != expectedKey) {
            res.statusCode = 401;
            res.responseBody = Blob.valueOf('{"status":"unauthorized"}');
            return;
        }

        // From here on: always 200 to minimise retries
        try {
            String rawBody = (req.requestBody == null) ? '' : req.requestBody.toString();
            if (String.isBlank(rawBody)) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ignored","reason":"empty body"}');
                return;
            }

            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
            Map<String, Object> data = root.containsKey('payload')
                ? (Map<String, Object>) root.get('payload')
                : root;

            String eventType     = (data.get('eventType') == null) ? null : String.valueOf(data.get('eventType'));
            String transactionId = (data.get('transactionId') == null) ? null : String.valueOf(data.get('transactionId'));
            String vin           = (data.get('vin') == null) ? null : String.valueOf(data.get('vin'));
            String imei          = (data.get('imei') == null) ? null : String.valueOf(data.get('imei'));

            Map<String, Object> subMap;
            if (eventType == 'tripStart') subMap = (Map<String, Object>) data.get('start');
            else if (eventType == 'tripEnd') subMap = (Map<String, Object>) data.get('end');
            else if (eventType == 'tripMetrics') subMap = (Map<String, Object>) data.get('metrics');
            else subMap = null;

            Datetime eventTime;
            if (subMap != null && subMap.get('timestamp') != null) {
                eventTime = (Datetime) JSON.deserialize('"' + String.valueOf(subMap.get('timestamp')) + '"', Datetime.class);
            } else {
                eventTime = System.now();
            }

            // Ignore old events (>10 minutes)
            Long ageMs = System.now().getTime() - eventTime.getTime();
            Long maxMs = (Long) MAX_EVENT_AGE_MINUTES * 60L * 1000L;
            if (ageMs > maxMs) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ignored","reason":"stale timestamp"}');
                return;
            }

            if (String.isBlank(eventType) || String.isBlank(transactionId)) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ignored","reason":"missing eventType/transactionId"}');
                return;
            }

            // Dedupe key: txn + type + timestamp-to-second (stable, prevents double inserts)
            String iso = eventTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            String eventKey = transactionId + '|' + eventType + '|' + iso;

            Trip_Event__c ev = new Trip_Event__c();
            ev.Event_Key__c     = eventKey;        // External ID UNIQUE (upsert target)
            ev.Transaction__c   = transactionId;   // External ID (not unique) (optional but fine)
            ev.transactionId__c = transactionId;
            ev.eventType__c     = eventType;
            ev.VIN__c           = vin;
            ev.imei__c          = imei;
            ev.timestamp__c     = eventTime;

            if (subMap != null) {
                if ((eventType == 'tripStart' || eventType == 'tripEnd') && subMap.get('odometer') != null) {
                    ev.odometer__c = (Decimal.valueOf(String.valueOf(subMap.get('odometer'))) * MILES_TO_KM).setScale(0);
                }

                if (eventType == 'tripEnd' && subMap.get('fuelConsumed') != null) {
                    ev.fuelConsumed__c = (Decimal.valueOf(String.valueOf(subMap.get('fuelConsumed'))) * GAL_TO_LITERS).setScale(1);
                }

                if (eventType == 'tripMetrics') {
                    if (subMap.get('tripDistance') != null) {
                        ev.Trip_KM__c = (Decimal.valueOf(String.valueOf(subMap.get('tripDistance'))) * MILES_TO_KM).setScale(1);
                    }
                    if (subMap.get('tripTime') != null) {
                        ev.Trip_Time__c = (Decimal.valueOf(String.valueOf(subMap.get('tripTime'))) * SECONDS_TO_MINUTES).setScale(1);
                    }
                    if (subMap.get('totalIdlingTime') != null) {
                        ev.Idle_Time__c = (Decimal.valueOf(String.valueOf(subMap.get('totalIdlingTime'))) * SECONDS_TO_MINUTES).setScale(1);
                    }
                    if (subMap.get('maxSpeed') != null) {
                        ev.Max_Speed__c = (Decimal.valueOf(String.valueOf(subMap.get('maxSpeed'))) * MPH_TO_KMH).setScale(0);
                    }
                    if (subMap.get('averageDriveSpeed') != null) {
                        ev.Avg_Speed__c = (Decimal.valueOf(String.valueOf(subMap.get('averageDriveSpeed'))) * MPH_TO_KMH).setScale(0);
                    }
                    if (subMap.get('hardBrakingCounts') != null) {
                        ev.Hard_Brakes__c = Integer.valueOf(String.valueOf(subMap.get('hardBrakingCounts')));
                    }
                    if (subMap.get('hardAccelerationCounts') != null) {
                        ev.Hard_Accel__c = Integer.valueOf(String.valueOf(subMap.get('hardAccelerationCounts')));
                    }
                }
            }

            upsert ev Event_Key__c;

            res.statusCode = 200;
            res.responseBody = Blob.valueOf('{"status":"ok"}');

        } catch (Exception ex) {
            System.debug('BOUNCIE ERROR => ' + ex.getMessage() + ' | ' + ex.getStackTraceString());
            res.statusCode = 200;
            res.responseBody = Blob.valueOf('{"status":"ignored","reason":"exception"}');
        }
    }
}
