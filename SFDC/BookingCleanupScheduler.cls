global class BookingCleanupScheduler implements Schedulable {
    
    global void execute(SchedulableContext ctx) {
        
        // 1. Fetch Active, Unflagged bookings that have a limit set
        List<Booking__c> activeBookings = [
            SELECT Id, Name, Start_Time__c, Days_Limit__c, 
                   Contact__r.FirstName 
            FROM Booking__c 
            WHERE Active__c = TRUE 
            AND Flag__c = FALSE 
            AND Days_Limit__c != NULL
        ];
        
        if (activeBookings.isEmpty()) return;

        List<Booking__c> bookingsToUpdate = new List<Booking__c>();
        List<Contact> admins = [SELECT MobilePhone FROM Contact WHERE Admin__c = TRUE AND MobilePhone != null];
        Datetime now = System.now();

        // 2. Check each booking individually
        for (Booking__c b : activeBookings) {
            
            // Calculate the specific deadline for THIS booking
            // e.g. Start Time + 2 Days
            Integer limitDays = Integer.valueOf(b.Days_Limit__c);
            Datetime deadline = b.Start_Time__c.addDays(limitDays);
            
            // 3. Is it overdue?
            if (now > deadline) {
                b.Flag__c = TRUE; // Check the box
                bookingsToUpdate.add(b);
                
                // Send SMS Alert to All Admins
                String msg = 'Alert: Booking #' + b.Name + ' (' + b.Contact__r.FirstName + ') has exceeded its ' + limitDays + '-day limit.';
                
                for (Contact admin : admins) {
                    // Call the future method to send text
                    TwilioService.sendSms(admin.MobilePhone, msg);
                }
            }
        }
        
        // 4. Save changes
        if (!bookingsToUpdate.isEmpty()) {
            update bookingsToUpdate;
        }
    }
}
