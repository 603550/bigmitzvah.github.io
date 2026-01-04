public with sharing class BookingController {

    private final Tanks__c tankRecord;
    public Booking__c activeBooking { get; set; }
    public String selectedContactId { get; set; }
    public String enteredPasscode { get; set; }
    public Boolean passcodeSent { get; set; }

    public BookingController(ApexPages.StandardController controller) {
        this.tankRecord = [SELECT Id, Name, Status__c, KM__c, Location__Latitude__s, Location__Longitude__s FROM Tanks__c WHERE Id = :controller.getId()];
        this.passcodeSent = false;
        loadActiveBooking();
    }

    private void loadActiveBooking() {
        List<Booking__c> bookings = [SELECT Id, Name, Contact__r.Name, Start_Time__c FROM Booking__c WHERE Tank__c = :tankRecord.Id AND Active__c = TRUE LIMIT 1];
        if (!bookings.isEmpty()) { 
            this.activeBooking = bookings[0]; 
        } else { 
            this.activeBooking = null; 
        }
    }

    public List<SelectOption> getContactOptions() {
        List<SelectOption> options = new List<SelectOption>();
        options.add(new SelectOption('', '-- Select a Driver --'));
        for (Contact c : [SELECT Id, Name FROM Contact WHERE Admin__c = FALSE ORDER BY Name]) {
            options.add(new SelectOption(c.Id, c.Name));
        }
        return options;
    }

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
        String passcode = String.valueOf(Integer.valueOf(Math.random() * 9000) + 1000);
        driver.OTP__c = passcode;
        driver.OTP_Exipre__c = System.now().addMinutes(5);
        update driver;
        
        TwilioService.sendSms(driver.MobilePhone, 'Your BigMitzvah.org verification code is: ' + passcode);
        
        this.passcodeSent = true;
        ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.INFO, 'Passcode sent to ' + driver.MobilePhone));
    }

    public PageReference startBooking() {
        // 1. Validate Passcode
        List<Contact> verifiedDriver = [
            SELECT Id, FirstName, MobilePhone 
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
        
        // 2. Lock & Validate Tank
        Tanks__c freshTank = [SELECT Id, Status__c, KM__c, Location__Latitude__s, Location__Longitude__s FROM Tanks__c WHERE Id = :tankRecord.Id FOR UPDATE];
        if (freshTank.Status__c != 'Open') {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Sorry! This tank was just booked by someone else a moment ago.'));
            return null;
        }
        
        // 3. Create Booking
        Booking__c newBooking = new Booking__c(
            Contact__c = selectedContactId,
            Tank__c = freshTank.Id,
            Start_Time__c = System.now(),
            Active__c = TRUE,
            Status__c = 'Open',
            KM_Start__c = (freshTank.KM__c != null ? freshTank.KM__c : 0),
            Location_Start__Latitude__s = freshTank.Location__Latitude__s,
            Location_Start__Longitude__s = freshTank.Location__Longitude__s
        );
        insert newBooking;
        
        // 4. Refresh for Auto-Number
        newBooking = [SELECT Id, Name FROM Booking__c WHERE Id = :newBooking.Id];
        
        // 5. Update Tank & Clear Driver OTP
        freshTank.Status__c = 'Booked';
        update freshTank;
        
        Contact driverToClear = new Contact(Id = selectedContactId, OTP__c = null, OTP_Exipre__c = null);
        update driverToClear;

        // 6. Notifications
        String firstName = (verifiedDriver[0].FirstName != null) ? verifiedDriver[0].FirstName : 'Driver';

        if (verifiedDriver[0].MobilePhone != null) {
            // A. Driver Welcome
            String combinedMsg = 'Welcome to the BigMitzvah Tank, ' + firstName + '! (Booking #' + newBooking.Name + ') Have a safe drive.\n\nNote: Please text this number for any support or assistance.';
            TwilioService.sendSms(verifiedDriver[0].MobilePhone, combinedMsg);

            // B. Set Chat Context (Crucial)
            TwilioService.updateChatContext(verifiedDriver[0].MobilePhone);
        }

        // C. ALL ADMINS Notification (Exact text you requested)
        List<Contact> admins = [SELECT MobilePhone FROM Contact WHERE Admin__c = TRUE AND MobilePhone != null];
        String adminMsg = firstName + ' has started Booking #' + newBooking.Name + '. You are listed as the contact number for support messages. Please keep an eye out for messages from the driver. Have a nice day.';

        for (Contact admin : admins) {
            TwilioService.sendSms(admin.MobilePhone, adminMsg);
        }

        return new PageReference('/' + freshTank.Id);
    }
}
