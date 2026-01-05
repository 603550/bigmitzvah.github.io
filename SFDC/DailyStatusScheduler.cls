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

            // --- CRITICAL CHANGE: If no booking, skip this tank entirely ---
            if (activeBookings.isEmpty()) {
                continue; 
            }

            // 4. Prepare Clean Data
            Booking__c b = activeBookings[0];
            
            Decimal fuelRaw = (tank.Fuel_Level__c != null) ? tank.Fuel_Level__c : 0;
            String fuelClean = String.valueOf(Math.round(fuelRaw));

            Decimal odoRaw = (tank.KM__c != null) ? tank.KM__c : 0;
            String odoClean = odoRaw.setScale(0).format(); 

            String mapsLink = 'http://maps.google.com/?q=' + tank.Location__Latitude__s + ',' + tank.Location__Longitude__s;

            String driverName = (b.Contact__r.Name != null) ? b.Contact__r.Name : 'Unknown';
            String rawPhone = (b.Contact__r.MobilePhone != null) ? b.Contact__r.MobilePhone : '';
            String driverPhone = rawPhone.replaceAll('[^0-9]', ''); 
            Decimal days = (b.Total_Days__c != null) ? b.Total_Days__c : 0;

            // 5. Build Message
            // BIGMITZVAH #BK0800 (Total 1 days) / Fuel 84% / 45,402 KM / David Kakon 5145740233
            String msg = 'BIGMITZVAH #' + b.Name + 
                         ' (Total ' + days + ' days) / Fuel ' + fuelClean + '% / ' + 
                         odoClean + ' KM / ' + driverName + ' ' + driverPhone + 
                         '\n' + mapsLink;

            // 6. Send
            for (Contact admin : admins) {
                TwilioService.sendSms(admin.MobilePhone, msg);
            }
        }
    }
}
