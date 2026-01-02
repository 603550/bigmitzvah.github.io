/**
 * @description Apex controller for the Rental App Visualforce page.
 * Provides @RemoteAction methods that can be called from JavaScript to interact with Salesforce data.
 */
public with sharing class BookingAppController {

    // Wrapper class to safely transport Contact data to the front end.
    public class Driver {
        @AuraEnabled public Id contactId { get; set; }
        @AuraEnabled public String driverId { get; set; } // Assuming a custom field for BMD001 etc.
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String phone { get; set; }
        @AuraEnabled public String licenseNumber { get; set; }
        @AuraEnabled public String licenseExpiry { get; set; }
        @AuraEnabled public String cardLast4 { get; set; }

        public Driver(Contact c) {
            this.contactId = c.Id;
            // NOTE: You'll need a custom field on Contact for the friendly ID, e.g., Driver_ID__c
            // If you don't have one, you can use another unique field.
            this.driverId = c.Description; // Using Description as a placeholder for 'BMD001'
            this.name = c.Name;
            this.phone = c.MobilePhone;
            // NOTE: These are placeholders for custom fields you would have on your Contact object.
            this.licenseNumber = 'QC197601-172278';
            this.licenseExpiry = '2026-05-10';
            this.cardLast4 = '4242';
        }
    }
    
    // Wrapper class for Tank data
    public class Tank {
        @AuraEnabled public Id tankId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Decimal currentKM { get; set; }
        
        public Tank(Tanks__c t) {
            this.tankId = t.Id;
            this.name = t.Name;
            this.currentKM = t.KM__c;
        }
    }

    /**
     * @description Fetches all non-admin contacts to be displayed as drivers.
     * @return List<Driver> A list of driver details.
     */
    @RemoteAction
    public static List<Driver> getDrivers() {
        List<Driver> driverList = new List<Driver>();
        for (Contact c : [SELECT Id, Name, MobilePhone, Description FROM Contact WHERE Admin__c = FALSE ORDER BY Name]) {
            driverList.add(new Driver(c));
        }
        return driverList;
    }
    
    /**
     * @description Fetches all tanks with a status of 'Open'.
     * @return List<Tank> A list of available tanks.
     */
    @RemoteAction
    public static List<Tank> getAvailableTanks() {
        List<Tank> tankList = new List<Tank>();
        for (Tanks__c t : [SELECT Id, Name, KM__c FROM Tanks__c WHERE Status__c = 'Open' ORDER BY Name]) {
            tankList.add(new Tank(t));
        }
        return tankList;
    }

    /**
     * @description Generates and sends a 4-digit OTP to the selected driver.
     * @param contactId The ID of the contact (driver) to send the OTP to.
     * @return String The phone number the code was sent to, for display purposes.
     */
    @RemoteAction
    public static String sendOtp(Id contactId) {
        Contact driver = [SELECT Id, MobilePhone FROM Contact WHERE Id = :contactId LIMIT 1];
        if (driver.MobilePhone == null) {
            throw new AuraHandledException('This driver does not have a mobile phone number on file.');
        }

        String passcode = String.valueOf(Math.floor(Math.random() * 9000) + 1000).substring(0,4);
        
        driver.OTP__c = passcode;
        driver.OTP_Exipre__c = System.now().addMinutes(5);
        update driver;

        sendSms(driver.MobilePhone, 'Your BigMitzvah.org verification code is: ' + passcode);
        
        return driver.MobilePhone;
    }

    /**
     * @description Verifies the OTP and creates a new booking.
     * @param contactId The ID of the driver.
     * @param tankId The ID of the selected tank.
     * @param otpCode The 4-digit code entered by the user.
     * @param startKM The starting KM entered by the user.
     * @return Booking__c The newly created booking record.
     */
    @RemoteAction
    public static Booking__c startNewBooking(Id contactId, Id tankId, String otpCode, Decimal startKM) {
        List<Contact> drivers = [SELECT Id FROM Contact WHERE Id = :contactId AND OTP__c = :otpCode AND OTP_Exipre__c > :System.now() LIMIT 1];
        if (drivers.isEmpty()) {
            throw new AuraHandledException('Invalid or expired passcode. Please try again.');
        }

        Tanks__c tank = [SELECT Id, Name, KM__c FROM Tanks__c WHERE Id = :tankId LIMIT 1];
        
        Booking__c newBooking = new Booking__c(
            Contact__c = contactId,
            Tank__c = tankId,
            Start_Time__c = System.now(),
            Active__c = TRUE,
            Status__c = 'Open',
            KM_Start__c = startKM
        );
        insert newBooking;
        
        // Update Tank status
        tank.Status__c = 'Booked';
        tank.KM__c = startKM;
        tank.Last_Use__c = System.now();
        update tank;
        
        // Clear the OTP from the contact record for security
        Contact driverToClear = new Contact(Id = contactId, OTP__c = null, OTP_Exipre__c = null);
        update driverToClear;
        
        return [SELECT Id, Name, Contact__r.Name, Contact__r.Description, Start_Time__c, KM_Start__c FROM Booking__c WHERE Id = :newBooking.Id];
    }

    // Helper method for Twilio callout
    @future(callout=true)
    private static void sendSms(String phoneNumber, String messageBody) {
        // Your Twilio SMS logic from BookingController would go here.
        // For simplicity, we'll just log it for now.
        System.debug('Sending SMS to ' + phoneNumber + ': ' + messageBody);
    }
}
