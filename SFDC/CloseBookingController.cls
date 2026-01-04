public with sharing class CloseBookingController {

    private final Tanks__c tank;
    public String enteredPasscode { get; set; }
    public Boolean passcodeSent { get; set; }

    public CloseBookingController(ApexPages.StandardController controller) {
        this.tank = [SELECT Id, Name FROM Tanks__c WHERE Id = :controller.getId()];
        this.passcodeSent = false;
    }

    public void sendPasscode() {
        // 1. Safety Check: Don't close if engine is running (Active Trip)
        List<Trip__c> activeTrips = [SELECT Id FROM Trip__c WHERE Booking__r.Tank__c = :tank.Id AND Booking__r.Active__c = TRUE AND Active__c = TRUE LIMIT 1];
        if (!activeTrips.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Error: Active trip running.'));
            return;
        }

        // 2. Find Admins
        List<Contact> admins = [SELECT Id, MobilePhone FROM Contact WHERE Admin__c = TRUE AND MobilePhone != null];
        if (admins.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'No admins found.'));
            return;
        }

        // 3. Generate Code
        String passcode = String.valueOf(Integer.valueOf(Math.random() * 9000) + 1000);
        List<Contact> contactsToUpdate = new List<Contact>();
        for (Contact admin : admins) {
            admin.OTP__c = passcode;
            admin.OTP_Exipre__c = System.now().addMinutes(5);
            contactsToUpdate.add(admin);
        }
        update contactsToUpdate;

        // 4. Send Admin SMS (Specific Tank Name)
        for (Contact admin : admins) {
            String msg = 'Request to CLOSE booking for ' + tank.Name + '. Code: ' + passcode;
            TwilioService.sendSms(admin.MobilePhone, msg);
        }
        
        passcodeSent = true;
    }

    public PageReference verifyAndCloseBooking() {
        List<Contact> matchingAdmins = [SELECT Id FROM Contact WHERE Admin__c = TRUE AND OTP__c = :enteredPasscode AND OTP_Exipre__c > :System.now() LIMIT 1];
        if (matchingAdmins.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Invalid.'));
            return null;
        }
        
        // Fetch Booking (Need Name & Phone for Customer SMS)
        List<Booking__c> activeBookings = [
            SELECT Id, Contact__r.MobilePhone, Contact__r.FirstName, Contact__c, Admin__c, Start_Time__c, KM_Start__c 
            FROM Booking__c 
            WHERE Tank__c = :tank.Id AND Active__c = TRUE 
            LIMIT 1
        ];
        
        if (activeBookings.isEmpty()) { return null; }
        
        // Snapshot Tank Data
        Tanks__c currentTankState = [SELECT KM__c, Location__Latitude__s, Location__Longitude__s FROM Tanks__c WHERE Id = :tank.Id LIMIT 1];
        Booking__c bookingToClose = activeBookings[0];
        
        // Close Booking
        bookingToClose.Active__c = false;
        bookingToClose.End_Time__c = System.now();
        bookingToClose.Status__c = 'Closed';
        bookingToClose.KM_End__c = currentTankState.KM__c;
        bookingToClose.Location_Stop__Latitude__s = currentTankState.Location__Latitude__s;
        bookingToClose.Location_Stop__Longitude__s = currentTankState.Location__Longitude__s;
        update bookingToClose;

        // Reset Tank
        Tanks__c tankToUpdate = new Tanks__c(Id = tank.Id, Status__c = 'Open');
        update tankToUpdate;

        // Calc Fuel
        AggregateResult[] tripResults = [SELECT SUM(Total_Fuel__c) totalFuel FROM Trip__c WHERE Booking__c = :bookingToClose.Id];
        Decimal fuelSum = (Decimal)tripResults[0].get('totalFuel');
        if (fuelSum == null) fuelSum = 0;

        // Re-query for calculated fields
        Booking__c closedBooking = [SELECT Id, Contact__c, Admin__c, Start_Time__c, End_Time__c, Total_KM__c, Total_Days__c, Tank__c, KM_Start__c, KM_End__c FROM Booking__c WHERE Id = :bookingToClose.Id];
        
        // Generate Charge & Send Customer SMS
        if (closedBooking.Admin__c == false) {
            Gasoline__c gasSettings = Gasoline__c.getOrgDefaults();
            Charge__c newCharge = new Charge__c(
                Booking__c = closedBooking.Id,
                Contact__c = closedBooking.Contact__c,
                Start_Time__c = closedBooking.Start_Time__c,
                End_Time__c = closedBooking.End_Time__c,
                Tank__c = closedBooking.Tank__c,
                KM_Total__c = closedBooking.Total_KM__c,
                Total_Fuel__c = fuelSum,
                KM_Start__c = closedBooking.KM_Start__c,
                KM_End__c = closedBooking.KM_End__c,
                Location_GPS__Latitude__s = currentTankState.Location__Latitude__s,
                Location_GPS__Longitude__s = currentTankState.Location__Longitude__s
            );
            if (gasSettings != null) {
                newCharge.Gas_Price__c = gasSettings.Gas_Price__c;
                newCharge.Fuel_Rate__c = gasSettings.Gas_Price__c;
            }
            insert newCharge;

            // --- SEND CUSTOMER FEEDBACK SMS ---
            if (bookingToClose.Contact__r.MobilePhone != null) {
                String firstName = (bookingToClose.Contact__r.FirstName != null) ? bookingToClose.Contact__r.FirstName : 'Driver';
                
                // "Thank you for driving with BigMitzvah.org David! How was your experience? Let us know by replying to this text."
                String feedbackMessage = 'Thank you for driving with BigMitzvah.org ' + firstName + '! How was your experience? Let us know by replying to this text.';
                
                TwilioService.sendSms(bookingToClose.Contact__r.MobilePhone, feedbackMessage);
            }
        }

        // Cleanup Admins
        List<Contact> allAdmins = [SELECT Id FROM Contact WHERE Admin__c = TRUE];
        for(Contact a : allAdmins) {
            a.OTP__c = null; a.OTP_Exipre__c = null;
        }
        update allAdmins;

        return new PageReference('/' + tank.Id);
    }
}
