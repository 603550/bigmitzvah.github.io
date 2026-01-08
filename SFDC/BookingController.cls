public with sharing class CloseBookingController {

    private final Tanks__c tank;
    public String enteredPasscode { get; set; }
    public Boolean passcodeSent { get; set; }

    public CloseBookingController(ApexPages.StandardController controller) {
        this.tank = [SELECT Id, Name FROM Tanks__c WHERE Id = :controller.getId()];
        this.passcodeSent = false;
    }

    public void sendPasscode() {
        // 1. Safety Check
        List<Trip__c> activeTrips = [SELECT Id FROM Trip__c WHERE Booking__r.Tank__c = :tank.Id AND Booking__r.Active__c = TRUE AND Active__c = TRUE LIMIT 1];
        if (!activeTrips.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Error: Active trip running.'));
            return;
        }

        // 2. Fetch Booking Name
        List<Booking__c> currentBookings = [SELECT Name FROM Booking__c WHERE Tank__c = :tank.Id AND Active__c = TRUE LIMIT 1];
        if (currentBookings.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'No active booking found to close.'));
            return;
        }
        String bookingName = currentBookings[0].Name;

        // 3. Find Admins
        List<Contact> admins = [SELECT Id, MobilePhone FROM Contact WHERE Admin__c = TRUE AND MobilePhone != null];
        if (admins.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'No admins found.'));
            return;
        }

        // 4. Generate Code
        String passcode = String.valueOf(Integer.valueOf(Math.random() * 9000) + 1000);
        List<Contact> contactsToUpdate = new List<Contact>();
        for (Contact admin : admins) {
            admin.OTP__c = passcode;
            admin.OTP_Exipre__c = System.now().addMinutes(5);
            contactsToUpdate.add(admin);
        }
        update contactsToUpdate;

        // 5. Send Code to ALL Admins
        String salt = String.valueOf(System.currentTimeMillis()).right(5);
        String msg = 'Confirmation code to close Booking #' + bookingName + ': ' + passcode + ' (Ref: ' + salt + ')';
        
        for (Contact admin : admins) {
            TwilioService.sendSms(admin.MobilePhone, msg);
        }
        
        passcodeSent = true;
    }

    public PageReference verifyAndCloseBooking() {
        // 1. Verify Passcode
        List<Contact> matchingAdmins = [SELECT Id FROM Contact WHERE Admin__c = TRUE AND OTP__c = :enteredPasscode AND OTP_Exipre__c > :System.now() LIMIT 1];
        if (matchingAdmins.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Invalid.'));
            return null;
        }
        
        // Query Tank__c so we can pass it to the Charge later
        List<Booking__c> activeBookings = [
            SELECT Id, Contact__r.MobilePhone, Contact__r.FirstName, Contact__c, Admin__c, Start_Time__c, KM_Start__c, Tank__c
            FROM Booking__c 
            WHERE Tank__c = :tank.Id AND Active__c = TRUE 
            LIMIT 1
        ];
        
        if (activeBookings.isEmpty()) { return null; }
        
        Tanks__c currentTankState = [SELECT KM__c, Location__Latitude__s, Location__Longitude__s FROM Tanks__c WHERE Id = :tank.Id LIMIT 1];
        Booking__c bookingToClose = activeBookings[0];

        // --- MANUAL CALCULATION (Trip Stats) ---
        // Sums up all trips instantly to ensure accurate billing
        AggregateResult[] tripResults = [
            SELECT SUM(Total_Fuel__c) totalFuel, 
                   SUM(Trip_KM__c) totalDist 
            FROM Trip__c 
            WHERE Booking__c = :bookingToClose.Id
        ];

        Decimal fuelSum = (Decimal)tripResults[0].get('totalFuel');
        if (fuelSum == null) fuelSum = 0;

        Decimal distSum = (Decimal)tripResults[0].get('totalDist');
        if (distSum == null) distSum = 0;

        // 2. Close Booking
        bookingToClose.Active__c = false;
        bookingToClose.End_Time__c = System.now();
        bookingToClose.Status__c = 'Closed';
        bookingToClose.KM_End__c = currentTankState.KM__c;
        bookingToClose.Location_Stop__Latitude__s = currentTankState.Location__Latitude__s;
        bookingToClose.Location_Stop__Longitude__s = currentTankState.Location__Longitude__s;
        
        // Save Totals to Booking History
        bookingToClose.Total_Fuel__c = fuelSum;
        bookingToClose.Total_KM__c = distSum;
        
        update bookingToClose;

        // 3. Reset Tank
        Tanks__c tankToUpdate = new Tanks__c(Id = tank.Id, Status__c = 'Open');
        update tankToUpdate;

        // 4. Generate Charge
        if (bookingToClose.Admin__c == false) {
            
            // --- CALC DAYS (Calendar Days) ---
            Date startDate = bookingToClose.Start_Time__c.date();
            Date endDate = bookingToClose.End_Time__c.date();
            Integer daysDiff = startDate.daysBetween(endDate);
            if (daysDiff == 0) daysDiff = 1; // Minimum 1 day charge

            Gasoline__c gasSettings = Gasoline__c.getOrgDefaults();
            Charge__c newCharge = new Charge__c(
                Booking__c = bookingToClose.Id,
                Contact__c = bookingToClose.Contact__c,
                Start_Time__c = bookingToClose.Start_Time__c,
                End_Time__c = bookingToClose.End_Time__c,
                
                // Lookup
                Tank__c = bookingToClose.Tank__c,
                
                // Stats
                KM_Total__c = distSum,
                Total_Fuel__c = fuelSum,
                Total_Days__c = daysDiff,
                
                // Meta
                KM_Start__c = bookingToClose.KM_Start__c,
                KM_End__c = bookingToClose.KM_End__c,
                Location_GPS__Latitude__s = currentTankState.Location__Latitude__s,
                Location_GPS__Longitude__s = currentTankState.Location__Longitude__s
            );
            
            // Apply Gas Settings (Price & Date)
            if (gasSettings != null) {
                newCharge.Gas_Price__c = gasSettings.Gas_Price__c;
                newCharge.Fuel_Rate__c = gasSettings.Gas_Price__c;
                newCharge.Gas_Date__c = gasSettings.Gas_Date__c; // <--- ADDED
            }
            insert newCharge;

            // Send Feedback SMS
            if (bookingToClose.Contact__r.MobilePhone != null) {
                String firstName = (bookingToClose.Contact__r.FirstName != null) ? bookingToClose.Contact__r.FirstName : 'Driver';
                TwilioService.sendSms(bookingToClose.Contact__r.MobilePhone, 'Thank you ' + firstName + '! How was your experience? Reply to let us know.');
            }
        }

        List<Contact> allAdmins = [SELECT Id FROM Contact WHERE Admin__c = TRUE];
        for(Contact a : allAdmins) {
            a.OTP__c = null; a.OTP_Exipre__c = null;
        }
        update allAdmins;

        return new PageReference('/' + tank.Id);
    }
}
