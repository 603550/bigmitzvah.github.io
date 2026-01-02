public with sharing class BookingController {

    // Properties
    private final Tanks__c tankRecord;
    public Booking__c activeBooking { get; set; }
    public String selectedContactId { get; set; }
    public String enteredPasscode { get; set; }
    public Boolean passcodeSent { get; set; }

    // Constructor
    public BookingController(ApexPages.StandardController controller) {
        // We need to re-query the Tank to get the latest Status and KM (in case the page was cached)
        this.tankRecord = [SELECT Id, Name, Status__c, KM__c FROM Tanks__c WHERE Id = :controller.getId()];
        this.passcodeSent = false;
        loadActiveBooking();
    }

    // --- Helper: Find if this Tank is already busy ---
    private void loadActiveBooking() {
        List<Booking__c> bookings = [
            SELECT Id, Name, Contact__r.Name, Start_Time__c 
            FROM Booking__c 
            WHERE Tank__c = :tankRecord.Id AND Active__c = TRUE 
            LIMIT 1
        ];
        if (!bookings.isEmpty()) {
            this.activeBooking = bookings[0];
        } else {
            this.activeBooking = null;
        }
    }

    // --- Dropdown List of Drivers ---
    public List<SelectOption> getContactOptions() {
        List<SelectOption> options = new List<SelectOption>();
        options.add(new SelectOption('', '-- Select a Driver --'));
        
        for (Contact c : [SELECT Id, Name FROM Contact WHERE Admin__c = FALSE ORDER BY Name]) {
            options.add(new SelectOption(c.Id, c.Name));
        }
        return options;
    }

    // --- Step 1: Send Passcode ---
    public void sendPasscode() {
        if (String.isBlank(selectedContactId)) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Please select a driver first.'));
            return;
        }

        Contact driver = [SELECT Id, MobilePhone FROM Contact WHERE Id = :selectedContactId LIMIT 1];

        if (driver.MobilePhone == null) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'This driver does not have a mobile number.'));
            return;
        }

        // Generate 4-digit Code
        String passcode = String.valueOf(Integer.valueOf(Math.random() * 9000) + 1000);
        
        driver.OTP__c = passcode;
        driver.OTP_Exipre__c = System.now().addMinutes(5);
        update driver;

        // Send SMS
        TwilioService.sendSms(driver.MobilePhone, 'Your BigMitzvah.org verification code is: ' + passcode);

        this.passcodeSent = true;
        ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.INFO, 'Passcode sent to ' + driver.MobilePhone));
    }

    // --- Step 2: Verify & Start Booking ---
    public PageReference startBooking() {
        // 1. Verify Passcode
        List<Contact> verifiedDriver = [
            SELECT Id 
            FROM Contact 
            WHERE Id = :selectedContactId 
            AND OTP__c = :enteredPasscode 
            AND OTP_Exipre__c > :System.now()
            LIMIT 1
        ];

        if (verifiedDriver.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Invalid or expired passcode.'));
            return null;
        }

        // 2. Refresh Tank Data (Critical for "Double Booking" check)
        Tanks__c freshTank = [SELECT Id, Status__c, KM__c FROM Tanks__c WHERE Id = :tankRecord.Id FOR UPDATE];

        // Safety Check: Is it actually available?
        if (freshTank.Status__c != 'Open') {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Sorry! This tank was just booked by someone else a moment ago.'));
            return null;
        }

        // 3. Create Booking
        // AUTOMATION: We grab the KM straight from the Tank. No user input.
        Booking__c newBooking = new Booking__c(
            Contact__c = selectedContactId,
            Tank__c = freshTank.Id,
            Start_Time__c = System.now(),
            Active__c = TRUE,
            Status__c = 'Open',
            KM_Start__c = (freshTank.KM__c != null ? freshTank.KM__c : 0) // <--- Automatic
        );
        insert newBooking;

        // 4. Update Tank Status ONLY
        // We do NOT update KM__c or Last_Use__c here. We trust Bouncie/Live Tracking for that.
        freshTank.Status__c = 'Booked';
        update freshTank;

        // 5. Clear Driver OTP
        Contact driverToClear = new Contact(Id = selectedContactId, OTP__c = null, OTP_Exipre__c = null);
        update driverToClear;

        // 6. Refresh Page
        return new PageReference('/' + freshTank.Id);
    }
}
