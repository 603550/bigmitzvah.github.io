public with sharing class CloseBookingController {

    // Properties for the page state
    private final Tanks__c tank;
    public String enteredPasscode { get; set; }
    public Boolean passcodeSent { get; set; }

    // Constructor
    public CloseBookingController(ApexPages.StandardController controller) {
        // Querying the name so it's available for SMS messages
        this.tank = [SELECT Id, Name FROM Tanks__c WHERE Id = :controller.getId()];
        this.passcodeSent = false;
    }

    // --- Step 1: Send Passcode to All Admnins ---
    public void sendPasscode() {
        // Validation: Don't allow closing if there is an Active Trip currently running
        List<Trip__c> activeTrips = [
            SELECT Id FROM Trip__c 
            WHERE Booking__r.Tank__c = :tank.Id AND Booking__r.Active__c = TRUE AND Active__c = TRUE 
            LIMIT 1
        ];

        if (!activeTrips.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Error: This booking cannot be closed because there is currently an ACTIVE trip running. Please wait for the car to stop.'));
            return;
        }

        List<Contact> admins = [SELECT Id, MobilePhone FROM Contact WHERE Admin__c = TRUE AND MobilePhone != null];

        if (admins.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'No admin contacts with a mobile number found to send a passcode.'));
            return;
        }

        // Generate 4-digit code
        String passcode = String.valueOf(Integer.valueOf(Math.random() * 9000) + 1000);
        
        List<Contact> contactsToUpdate = new List<Contact>();
        for (Contact admin : admins) {
            admin.OTP__c = passcode;
            admin.OTP_Exipre__c = System.now().addMinutes(5);
            contactsToUpdate.add(admin);
        }
        update contactsToUpdate;

        // Send SMS to all Admins
        for (Contact admin : admins) {
            TwilioService.sendSms(admin.MobilePhone, 'Request to CLOSE booking for ' + tank.Name + '. Code: ' + passcode);
        }
        
        passcodeSent = true;
        ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.CONFIRM, 'A verification passcode has been sent to all administrators.'));
    }

    // --- Step 2: Verify Passcode and Close the Booking ---
    public PageReference verifyAndCloseBooking() {
        // 1. Validate Passcode
        List<Contact> matchingAdmins = [
            SELECT Id FROM Contact 
            WHERE Admin__c = TRUE AND OTP__c = :enteredPasscode AND OTP_Exipre__c > :System.now()
            LIMIT 1
        ];

        if (matchingAdmins.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Invalid or expired passcode. Please try again.'));
            return null;
        }

        List<Booking__c> activeBookings = [SELECT Id, Contact__r.MobilePhone, Contact__c, Admin__c, Start_Time__c FROM Booking__c WHERE Tank__c = :tank.Id AND Active__c = TRUE LIMIT 1];
        if (activeBookings.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.INFO, 'There is no active booking for this tank to close.'));
            return null;
        }
        
        // 2. Close the Booking
        Tanks__c currentTankState = [SELECT KM__c, Location__Latitude__s, Location__Longitude__s FROM Tanks__c WHERE Id = :tank.Id LIMIT 1];
        Booking__c bookingToClose = activeBookings[0];
        
        bookingToClose.Active__c = false;
        bookingToClose.End_Time__c = System.now();
        bookingToClose.Status__c = 'Closed';
        bookingToClose.KM_End__c = currentTankState.KM__c;
        
        update bookingToClose; 

        // 3. Re-Open the Tank
        Tanks__c tankToUpdate = new Tanks__c(Id = tank.Id, Status__c = 'Open');
        update tankToUpdate;

        // 4. Calculate Total Fuel from Trip records
        AggregateResult[] tripResults = [
            SELECT SUM(Total_Fuel__c) totalFuel 
            FROM Trip__c 
            WHERE Booking__c = :bookingToClose.Id
        ];
        Decimal fuelSum = (Decimal)tripResults[0].get('totalFuel');
        if (fuelSum == null) fuelSum = 0;

        // 5. Re-Query Booking for Formula Values
        Booking__c closedBooking = [
            SELECT Id, Contact__c, Admin__c, Start_Time__c, End_Time__c, 
                   Total_KM__c, Total_Days__c, Tank__c,
                   KM_Start__c, KM_End__c 
            FROM Booking__c 
            WHERE Id = :bookingToClose.Id
        ];
        
        // 6. GENERATE CHARGE
        if (closedBooking.Admin__c == false) {
            
            // Retrieve today's Gas Price from Custom Setting
            Gasoline__c gasSettings = Gasoline__c.getOrgDefaults();

            Charge__c newCharge = new Charge__c(
                Booking__c    = closedBooking.Id,
                Contact__c    = closedBooking.Contact__c,
                Start_Time__c = closedBooking.Start_Time__c,
                End_Time__c   = closedBooking.End_Time__c,
                Tank__c       = closedBooking.Tank__c,
                Type__c       = 'Booking',
                Expense__c    = 0,
                
                // DATA MAPPING
                KM_Total__c   = closedBooking.Total_KM__c, 
                Total_Days__c = closedBooking.Total_Days__c,
                Total_Fuel__c = fuelSum,
                KM_Start__c   = closedBooking.KM_Start__c,
                KM_End__c     = closedBooking.KM_End__c,

                // CAPTURE RETURN GPS (Snapshot from the Tank)
                Location_GPS__Latitude__s  = currentTankState.Location__Latitude__s,
                Location_GPS__Longitude__s = currentTankState.Location__Longitude__s
            );

            // Populate Fuel Rates if Gas Settings are available
            if (gasSettings != null) {
                newCharge.Gas_Date__c   = gasSettings.Gas_Date__c;
                newCharge.Gas_Price__c  = gasSettings.Gas_Price__c;
                newCharge.Gas_Source__c = gasSettings.Gas_Source__c;
                newCharge.Fuel_Rate__c  = gasSettings.Gas_Price__c; // Billing rate matches market rate
            }

            insert newCharge;

            // Optional Feedback SMS to Customer
            if (bookingToClose.Contact__r.MobilePhone != null) {
                String feedbackMessage = 'Thank you for driving with BigMitzvah.org! Total Days: ' + closedBooking.Total_Days__c + '. How was your experience?';
                TwilioService.sendSms(bookingToClose.Contact__r.MobilePhone, feedbackMessage);
            }
        }

        // 7. Cleanup Admin Passcodes
        List<Contact> allAdmins = [SELECT Id FROM Contact WHERE Admin__c = TRUE];
        for(Contact admin : allAdmins) {
            admin.OTP__c = null;
            admin.OTP_Exipre__c = null;
        }
        update allAdmins;

        return new PageReference('/' + tank.Id);
    }
}
