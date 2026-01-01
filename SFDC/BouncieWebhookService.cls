@RestResource(urlMapping='/BouncieWebhook/*')
global without sharing class BouncieWebhookService {

    // Unit conversions
    private static final Decimal MILES_TO_KM   = 1.609344;
    private static final Decimal MPH_TO_KMH    = 1.609344;
    private static final Decimal GAL_TO_LITERS = 3.78541;
    private static final Decimal SECONDS_TO_MINUTES = 1.0 / 60.0;

    // Ignore events older than this (minutes)
    private static final Integer MAX_EVENT_AGE_MIN = 10;

    @HttpPost
    global static void handleWebhook() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        // Always respond quickly; only 401 for bad key.
        if (!isAuthorized(req)) {
            res.statusCode = 401;
            res.responseBody = Blob.valueOf('{"status":"unauthorized"}');
            return;
        }

        try {
            String rawBody = (req.requestBody == null) ? '' : req.requestBody.toString();
            if (String.isBlank(rawBody)) {
                // Do not trigger retries for empty bodies; just accept.
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ok","note":"empty body"}');
                return;
            }

            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
            Map<String, Object> data = (root != null && root.containsKey('payload'))
                ? (Map<String, Object>) root.get('payload')
                : root;

            if (data == null) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ok","note":"no payload"}');
                return;
            }

            String eventType     = getString(data, 'eventType');
            String transactionId = getString(data, 'transactionId');
            String vin           = getString(data, 'vin');
            String imei          = getString(data, 'imei');

            // Missing core identifiers -> accept but do nothing (prevents retries).
            if (String.isBlank(eventType) || String.isBlank(transactionId)) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ok","note":"missing eventType/transactionId"}');
                return;
            }

            // Pull sub-object by type
            Map<String, Object> subMap;
            if (eventType == 'tripStart')       subMap = (Map<String, Object>) data.get('start');
            else if (eventType == 'tripEnd')    subMap = (Map<String, Object>) data.get('end');
            else if (eventType == 'tripMetrics')subMap = (Map<String, Object>) data.get('metrics');
            else                                subMap = null;

            Datetime eventTime = extractTimestamp(subMap);
            if (eventTime == null) eventTime = System.now();

            // Ignore old events (but return 200 to stop retries)
            if (eventTime < System.now().addMinutes(-MAX_EVENT_AGE_MIN)) {
                res.statusCode = 200;
                res.responseBody = Blob.valueOf('{"status":"ok","note":"ignored old event"}');
                return;
            }

            // Build dedupe key: txn|type|yyyyMMddHHmmss (GMT)
            String tsKey = eventTime.formatGmt('yyyyMMddHHmmss');
            String eventKey = transactionId + '|' + eventType + '|' + tsKey;

            Trip_Event__c ev = new Trip_Event__c();
            ev.Event_Key__c      = eventKey;
            ev.Processed__c      = false;
            ev.transactionId__c  = transactionId;
            ev.eventType__c      = eventType;
            ev.VIN__c            = vin;
            ev.imei__c           = imei;
            ev.timestamp__c      = eventTime;

            // Map fields
            if (subMap != null) {
                if (eventType == 'tripStart' || eventType == 'tripEnd') {
                    // Odometer (miles -> km)
                    Decimal odo = getDecimal(subMap, 'odometer');
                    if (odo != null) ev.odometer__c = odo * MILES_TO_KM;

                    // Fuel (gallons -> litres) on tripEnd
                    if (eventType == 'tripEnd') {
                        Decimal fuel = getDecimal(subMap, 'fuelConsumed');
                        if (fuel != null) ev.fuelConsumed__c = fuel * GAL_TO_LITERS;
                    }
                }

                if (eventType == 'tripMetrics') {
                    Decimal dist = getDecimal(subMap, 'tripDistance');
                    if (dist != null) ev.Trip_KM__c = (dist * MILES_TO_KM).setScale(1);

                    Decimal tripSec = getDecimal(subMap, 'tripTime');
                    if (tripSec != null) ev.Trip_Time__c = (tripSec * SECONDS_TO_MINUTES).setScale(1);

                    Decimal idleSec = getDecimal(subMap, 'totalIdlingTime');
                    if (idleSec != null) ev.Idle_Time__c = (idleSec * SECONDS_TO_MINUTES).setScale(1);

                    Decimal maxMph = getDecimal(subMap, 'maxSpeed');
                    if (maxMph != null) ev.Max_Speed__c = (maxMph * MPH_TO_KMH).setScale(0);

                    Decimal avgMph = getDecimal(subMap, 'averageDriveSpeed');
                    if (avgMph != null) ev.Avg_Speed__c = (avgMph * MPH_TO_KMH).setScale(0);

                    Integer brakes = getInteger(subMap, 'hardBrakingCounts');
                    if (brakes != null) ev.Hard_Brakes__c = brakes;

                    Integer accel = getInteger(subMap, 'hardAccelerationCounts');
                    if (accel != null) ev.Hard_Accel__c = accel;
                }
            }

            // Upsert by Event_Key__c (dedupe)
            upsert ev Event_Key__c;

            // Always return 200 OK (Bouncie retry suppression)
            res.statusCode = 200;
            res.responseBody = Blob.valueOf('{"status":"ok"}');

        } catch (Exception ex) {
            // Still return 200 to avoid repeated retries; log for diagnosis.
            System.debug('BOUNCIE ERROR => ' + ex.getMessage() + ' | ' + ex.getStackTraceString());
            res.statusCode = 200;
            res.responseBody = Blob.valueOf('{"status":"ok","note":"exception logged"}');
        }
    }

    // ---------------- Helpers ----------------

    private static Boolean isAuthorized(RestRequest req) {
        String apiKey = req.headers.get('x-bouncie-authorization');
        if (String.isBlank(apiKey)) apiKey = req.headers.get('x-api-key');
        if (String.isBlank(apiKey)) apiKey = req.headers.get('Authorization');

        Bouncie_Settings__c settings = Bouncie_Settings__c.getOrgDefaults();
        String expectedKey = (settings != null) ? settings.Bouncie_Webhook_Key__c : null;

        return (!String.isBlank(apiKey) && !String.isBlank(expectedKey) && apiKey == expectedKey);
    }

    private static String getString(Map<String, Object> m, String key) {
        return (m != null && m.containsKey(key) && m.get(key) != null) ? String.valueOf(m.get(key)) : null;
    }

    private static Decimal getDecimal(Map<String, Object> m, String key) {
        if (m == null || !m.containsKey(key) || m.get(key) == null) return null;
        try { return Decimal.valueOf(String.valueOf(m.get(key))); }
        catch (Exception e) { return null; }
    }

    private static Integer getInteger(Map<String, Object> m, String key) {
        if (m == null || !m.containsKey(key) || m.get(key) == null) return null;
        try { return Integer.valueOf(String.valueOf(m.get(key))); }
        catch (Exception e) { return null; }
    }

    private static Datetime extractTimestamp(Map<String, Object> subMap) {
        if (subMap == null || subMap.get('timestamp') == null) return null;
        try {
            // timestamp is usually ISO8601 string
            return (Datetime) JSON.deserialize('"' + String.valueOf(subMap.get('timestamp')) + '"', Datetime.class);
        } catch (Exception e) {
            return null;
        }
    }
}
