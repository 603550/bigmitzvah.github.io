global class DailyStatusScheduler implements Schedulable {

    global void execute(SchedulableContext ctx) {
        
        // 1. Get Admins
        List<Contact> admins = [SELECT MobilePhone FROM Contact WHERE Admin__c = TRUE AND MobilePhone != null];
        if (admins.isEmpty()) return;

        // 2. Get All Tanks
        List<Tanks__c> tanks = [
            SELECT Id, Name, KM__c, Fuel_Level__c, 
                   Location__Latitude__s, Location__Longitude__s 
            FROM Tanks__c
        ];

        for (Tanks__c tank : tanks) {
            // 3. Find Active Booking
            List<Booking__c> activeBookings = [
                SELECT Name, Contact__r.Name, Contact__r.MobilePhone, Total_Days__c
                FROM Booking__c 
                WHERE Tank__c = :tank.Id 
                AND Active__c = TRUE 
                LIMIT 1
            ];

            // 4. Prepare Clean Data
            // Round Fuel to whole number (e.g. 84%)
            Decimal fuelRaw = (tank.Fuel_Level__c != null) ? tank.Fuel_Level__c : 0;
            String fuelClean = String.valueOf(Math.round(fuelRaw));

            // Round Odometer to whole number (e.g. 45,402)
            Decimal odoRaw = (tank.KM__c != null) ? tank.KM__c : 0;
            String odoClean = odoRaw.setScale(0).format();

            String mapsLink = 'http://maps.google.com/?q=' + tank.Location__Latitude__s + ',' + tank.Location__Longitude__s;
            String msg = '';

            // 5. Build Message
            if (activeBookings.isEmpty()) {
                // --- IDLE STATE ---
                msg = 'BigMitzvah Update //\n' +
                      'BIGMITZVAH TANK\n\n' + // Extra newline for spacing
                      'Active booking: N/A\n' + 
                      'Fuel Level: ' + fuelClean + '%\n' +
                      'Odometer: ' + odoClean + ' KM\n\n' + 
                      mapsLink;
            } else {
                // --- ACTIVE STATE ---
                Booking__c b = activeBookings[0];
                String driverName = (b.Contact__r.Name != null) ? b.Contact__r.Name : 'Unknown';
                String driverPhone = (b.Contact__r.MobilePhone != null) ? b.Contact__r.MobilePhone : 'N/A';
                Decimal days = (b.Total_Days__c != null) ? b.Total_Days__c : 0;

                msg = 'BIGMITZVAH TANK\n\n' +
                      'Booking: ' + b.Name + '\n' +
                      'Total Days: ' + days + '\n' +
                      'Fuel Level: ' + fuelClean + '%\n' +
                      'Odometer: ' + odoClean + ' KM\n\n' +
                      'Driver: ' + driverName + '\n' +
                      'Contact: ' + driverPhone + '\n\n' +
                      mapsLink;
            }

            // 6. Send to All Admins
            for (Contact admin : admins) {
                TwilioService.sendSms(admin.MobilePhone, msg);
            }
        }
    }
}
