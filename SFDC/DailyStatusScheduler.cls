global class DailyStatusScheduler implements Schedulable {

    global void execute(SchedulableContext ctx) {
        
        // 1. Get Admins
        List<Contact> admins = [SELECT MobilePhone FROM Contact WHERE Admin__c = TRUE AND MobilePhone != null];
        if (admins.isEmpty()) return;

        // 2. BULKIFIED QUERY
        // Includes all fields we discussed: Days_Limit__c, Total_Flags__c, etc.
        List<Booking__c> activeBookings = [
            SELECT Name, Total_Days__c, Days_Limit__c, Total_Flags__c, Status__c, 
                   Total_Trips__c, KM_Total__c, Total_Fuel__c,
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
            String rawPhone = (b.Contact__r.MobilePhone != null) ? b.Contact__r.MobilePhone : '';
            String driverPhone = rawPhone.replaceAll('[^0-9]', ''); 

            String status = (b.Status__c != null) ? b.Status__c : 'Active';
            Decimal days = (b.Total_Days__c != null) ? b.Total_Days__c : 0;
            Decimal trips = (b.Total_Trips__c != null) ? b.Total_Trips__c : 0;
            Decimal flags = (b.Total_Flags__c != null) ? b.Total_Flags__c : 0; //
            
            String totalKm = (b.KM_Total__c != null) ? b.KM_Total__c.setScale(0).format() : '0';
            String fuelUsed = (b.Total_Fuel__c != null) ? String.valueOf(b.Total_Fuel__c.setScale(1)) : '0';

            Decimal currentFuelRaw = (b.Tank__r.Fuel_Level__c != null) ? b.Tank__r.Fuel_Level__c : 0;
            String currentFuelLevel = String.valueOf(Math.round(currentFuelRaw));

            // --- MAPS LINK FIX ---
            String lat = (b.Tank__r.Location__Latitude__s != null) ? String.valueOf(b.Tank__r.Location__Latitude__s) : '0';
            String lng = (b.Tank__r.Location__Longitude__s != null) ? String.valueOf(b.Tank__r.Location__Longitude__s) : '0';
            
            // The cleanest format for iOS/Android previews:
            String mapsLink = 'https://maps.google.com/?q=' + lat + ',' + lng;

            // --- ALERTS ---
            String alerts = '';
            // Check 1: Past Due
            if (b.Days_Limit__c != null && days > b.Days_Limit__c) {
                alerts += '\n🚨 ** PAST DUE **';
            }
            // Check 2: Flagged
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

            // 4. Send
            for (Contact admin : admins) {
                TwilioService.sendSms(admin.MobilePhone, msg);
            }
        }
    }
}
