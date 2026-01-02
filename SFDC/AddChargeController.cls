public with sharing class AddChargeController {

    // Properties for the page state
    public Id tankId { get; private set; }
    public String enteredPasscode { get; set; }
    public Boolean passcodeSent { get; set; }
    public Boolean isAdminVerified { get; set; }
    public Boolean bookingFound { get; set; }
    public Boolean isAdminBookingFound { get; set; } 

    // Properties for the charge details
    public Datetime chargeDateTime { get; set; }
    public Decimal chargeAmount { get; set; }
    public String chargeDescription { get; set; }
    public Booking__c foundBooking { get; set; }

    // Constructor
    public AddChargeController(ApexPages.StandardController controller) {
        this.tankId = controller.getId();
        this.passcodeSent = false;
        this.isAdminVerified = false;
        this.bookingFound = false;
        this.isAdminBookingFound = false; 
    }

    // --- Step 1: Send Passcode to Admins ---
    public void sendPasscode() {
        List<Contact> admins = [SELECT Id, MobilePhone FROM Contact WHERE Admin__c = TRUE AND MobilePhone != null];

        if (admins.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'No admin contacts with a mobile number found to send a passcode.'));
            return;
        }

        String passcode = String.valueOf(Integer.valueOf(Math.random() * 9000) + 1000);
        
        for (Contact admin : admins) {
            admin.OTP__c = passcode;
            admin.OTP_Exipre__c = System.now().addMinutes(5);
        }
        update admins;

        for (Contact admin : admins) {
            TwilioService.sendSms(admin.MobilePhone, 'A request to add a new charge requires verification. The passcode is: ' + passcode);
        }

        this.passcodeSent = true;
        ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.CONFIRM, 'A passcode has been sent to all administrators.'));
    }

    // --- Step 2: Verify the Admin's Passcode ---
    public void verifyPasscode() {
        List<Contact> matchingAdmins = [
            SELECT Id FROM Contact 
            WHERE Admin__c = TRUE 
            AND OTP__c = :enteredPasscode 
            AND OTP_Exipre__c > :System.now()
            LIMIT 1
        ];

        if (matchingAdmins.isEmpty()) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Invalid or expired passcode. Please try again.'));
            this.passcodeSent = false;
        } else {
            this.isAdminVerified = true;
        }
    }
    
    // --- Step 3: Find the Correct Booking ---
    public void findBookingAndConfirm() {
        // Find a customer booking that was active during the specified time
        List<Booking__c> bookings = [
            SELECT Id, Name, Contact__r.Name, Contact__r.MobilePhone, Tank__r.Name, Admin__c 
            FROM Booking__c 
            WHERE Tank__c = :this.tankId 
            AND Start_Time__c <= :chargeDateTime 
            AND End_Time__c >= :chargeDateTime 
            AND Admin__c = FALSE
            LIMIT 1
        ];

        if (!bookings.isEmpty()) {
            this.foundBooking = bookings[0];
            this.isAdminBookingFound = false; 
        } else {
            // If no customer booking is found, fall back to the Admin booking FOR THIS TANK
            List<Booking__c> adminBookings = [
                SELECT Id, Name, Contact__r.Name, Contact__r.MobilePhone, Tank__r.Name 
                FROM Booking__c 
                WHERE Admin__c = TRUE 
                AND Tank__c = :this.tankId  // <--- FIXED: Only get admin booking for THIS tank
                LIMIT 1
            ];
            if (!adminBookings.isEmpty()) {
                this.foundBooking = adminBookings[0];
                this.isAdminBookingFound = true; 
            }
        }
        
        if (this.foundBooking != null) {
            this.bookingFound = true;
        } else {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'No active booking (customer or admin) could be found for the specified date and time.'));
        }
    }

    // --- Step 4: Create the Charge Record ---
    public PageReference createCharge() {
        Charge__c newCharge = new Charge__c(
            Booking__c = this.foundBooking.Id,
            Contact__c = this.foundBooking.Contact__c,
            Tank__c = this.tankId,
            Start_Time__c = this.chargeDateTime,
            End_Time__c = this.chargeDateTime,
            Expense__c = this.chargeAmount,
            Description__c = this.chargeDescription,
            Type__c = 'Expense',
            Status__c = 'Unpaid',
            KM_Total__c = 0,
            Total_Fuel__c = 0,
            Day_Rate__c = 0,
            Fuel_Rate__c = 0
        );
        insert newCharge;

        return new PageReference('/' + this.tankId);
    }
    
    public PageReference cancel() {
        return new PageReference('/' + this.tankId);
    }
}
