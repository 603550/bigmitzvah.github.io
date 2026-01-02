/**
 * @description Apex controller for the Rental App Visualforce page.
 * UPDATED: Removes manual odometer input and trusts Bouncie automation.
 */
public with sharing class BookingAppController {

    // Wrapper class to safely transport Contact data to the front end.
    public class Driver {
        @AuraEnabled public Id contactId { get; set; }
        @AuraEnabled public String driverId { get; set; } 
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String phone { get; set; }
        @AuraEnabled public String licenseNumber { get; set; }
        @AuraEnabled public String licenseExpiry { get; set; }
        @AuraEnabled public String cardLast4 { get; set; }

        public Driver(Contact c) {
            this.contactId = c.Id;
            this.driverId = c.Description; 
            this.name = c.Name;
            this.phone = c.MobilePhone;
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

    @RemoteAction
    public static List<Driver> getDrivers() {
        List<Driver> driverList = new List<Driver>();
        for (Contact c : [SELECT Id, Name, MobilePhone, Description FROM Contact WHERE Admin__c = FALSE ORDER BY Name]) {
            driverList.add(new Driver(c));
        }
        return driverList;
    }
    
    @RemoteAction
    public static List<Tank> getAvailableTanks() {
        List<Tank> tankList = new List<Tank>();
        for (Tanks__c t : [SELECT Id, Name, KM__c FROM Tanks__c WHERE Status__c = 'Open' ORDER BY Name]) {
            tankList.add(new Tank(t));
        }
        return tankList;
    }

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

        // Note: Ensure TwilioService is accessible here, or use the helper method below
        sendSms(driver.MobilePhone, 'Your BigMitzvah.org verification code is: ' + passcode);
        
        return driver.MobilePhone;
    }

    /**
     * @description Verifies the OTP and creates a new booking.
     * UPDATED: Removed 'startKM' parameter.
     */
    @RemoteAction
    public static Booking__c startNewBooking(Id contactId, Id tankId, String otpCode) {
        // 1. Validate Driver OTP
        List<Contact> drivers = [SELECT Id FROM Contact WHERE Id = :contactId AND OTP__c = :otpCode AND OTP_Exipre__c > :System.now() LIMIT 1];
        if (drivers.isEmpty()) {
            throw new AuraHandledException('Invalid or expired passcode. Please try again.');
        }

        // 2. Fetch Tank Details
        Tanks__c tank = [SELECT Id, Name, KM__c, Status__c FROM Tanks__c WHERE Id = :tankId LIMIT 1];

        // --- SAFETY CHECK: PREVENT DOUBLE BOOKING ---
        List<Booking__c> existingActive = [SELECT Id FROM Booking__c WHERE Tank__c = :tankId AND Active__c = TRUE LIMIT 1];
        if (tank.Status__c != 'Open' || !existingActive.isEmpty()) {
            throw new AuraHandledException('Sorry, this vehicle has just been booked by another driver.');
        }

        // 3. Create Booking (AUTOMATICALLY use Tank Odometer)
        Booking__c newBooking = new Booking__c(
            Contact__c = contactId,
            Tank__c = tankId,
            Start_Time__c = System.now(),
            Active__c = TRUE,
            Status__c = 'Open',
            // If Tank KM is null, default to 0 to prevent errors
            KM_Start__c = (tank.KM__c != null ? tank.KM__c : 0) 
        );
        insert newBooking;
        
        // 4. Update Tank Status ONLY
        // We do NOT update KM__c or Last_Use__c here. We trust Bouncie automation.
        tank.Status__c = 'Booked';
        update tank;
        
        // 5. Cleanup OTP
        Contact driverToClear = new Contact(Id = contactId, OTP__c = null, OTP_Exipre__c = null);
        update driverToClear;
        
        return [SELECT Id, Name, Contact__r.Name, Contact__r.Description, Start_Time__c, KM_Start__c FROM Booking__c WHERE Id = :newBooking.Id];
    }

    @future(callout=true)
    private static void sendSms(String phoneNumber, String messageBody) {
        // Calls your Twilio Service
        TwilioService.sendSms(phoneNumber, messageBody);
    }
}
