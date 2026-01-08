global class DailyStatusScheduler implements Schedulable {

    global void execute(SchedulableContext ctx) {
        
        // 1. Get Admins
        List<Contact> admins = [SELECT MobilePhone FROM Contact WHERE Admin__c = TRUE AND MobilePhone != null];
        
        // 2. BULKIFIED QUERY
        List<Booking__c> activeBookings = [
            SELECT Name, Total_Days__c, Days_Limit__c, Total_Flags__c, Status__c, 
                   Total_Trips__c, Total_KM__c, Total_Fuel__c,
                   Contact__r.Name, Contact__r.MobilePhone,
                   Tank__r.Id, Tank__r.Name, Tank__r.KM__c, Tank__r.Fuel_Level__c, 
                   Tank__r.Location__Latitude__s, Tank__r.Location__Longitude__s
            FROM Booking__c 
            WHERE Active__c = TRUE 
            AND Tank__c != null
        ];

        if (activeBookings.isEmpty()) return;

        // 3. Loop through results
        for (Booking__c b : activeBookings) {
            
            // --- DATA PREPARATION ---
            String driverName = (b.Contact__r.Name != null) ? b.Contact__r.Name : 'Unknown';
            // rawPhone is the raw database value (e.g. +1 514...)
            String rawPhone = (b.Contact__r.MobilePhone != null) ? b.Contact__r.MobilePhone : '';
            // driverPhone is the clean version for the text body (e.g. 514...)
            String driverPhone = rawPhone.replaceAll('[^0-9]', ''); 

            String status = (b.Status__c != null) ? b.Status__c : 'Active';
            Decimal days = (b.Total_Days__c != null) ? b.Total_Days__c : 0;
            Decimal trips = (b.Total_Trips__c != null) ? b.Total_Trips__c : 0;
            Decimal flags = (b.Total_Flags__c != null) ? b.Total_Flags__c : 0; 
            
            String totalKm = (b.Total_KM__c != null) ? b.Total_KM__c.setScale(0).format() : '0';
            String fuelUsed = (b.Total_Fuel__c != null) ? String.valueOf(b.Total_Fuel__c.setScale(1)) : '0';

            Decimal currentFuelRaw = (b.Tank__r.Fuel_Level__c != null) ? b.Tank__r.Fuel_Level__c : 0;
            String currentFuelLevel = String.valueOf(Math.round(currentFuelRaw));

            // --- MAP LINK ---
            String lat = (b.Tank__r.Location__Latitude__s != null) ? String.valueOf(b.Tank__r.Location__Latitude__s) : '0';
            String lng = (b.Tank__r.Location__Longitude__s != null) ? String.valueOf(b.Tank__r.Location__Longitude__s) : '0';
            String mapsLink = 'https://maps.google.com/?q=' + lat + ',' + lng;

            // --- ALERTS ---
            String alerts = '';
            if (b.Days_Limit__c != null && days > b.Days_Limit__c) {
                alerts += '\n🚨 ** PAST DUE **';
            }
            if (flags > 0) {
                alerts += '\n🚩 ** FLAGGED **';
            }

            // --- BUILD MESSAGE ---
            String msg = 'BIGMITZVAH #' + b.Name + '\n' +
                         driverName + ' ' + driverPhone + '\n' +
                         'Status: ' + status + '\n' +
                         'Fuel: ' + currentFuelLevel + '% (Used ' + fuelUsed + 'L)\n' +
                         'Stats: ' + totalKm + 'km | ' + trips + ' Trips | ' + days + ' Days' +
                         alerts + '\n' + 
                         mapsLink;

            // --- 4. PREPARE RECIPIENTS ---
            // Use a Set to avoid duplicates if driver is also an admin
            Set<String> recipientPhones = new Set<String>();

            // Add all Admins
            for (Contact admin : admins) {
                recipientPhones.add(admin.MobilePhone);
            }

            // Add Current Driver (if they have a phone number)
            if (String.isNotBlank(rawPhone)) {
                recipientPhones.add(rawPhone);
            }

            // --- 5. SEND ---
            for (String phone : recipientPhones) {
                TwilioService.sendSms(phone, msg);
            }
        }
    }
}
