@isTest
public class CreateQuoteLinesTest {
    
    @isTest
    public static void testWithDiscountGreaterThanZero() {
        runTestWithDiscount(10); // Sconto 10%
    }
    
    @isTest
    public static void testWithNullDiscount() {
        runTestWithDiscount(null); // Nessuno sconto
    }
    
    @isTest
    public static void testWihZeroDiscount() {
        runTestWithDiscount(0);    // Sconto 0
    }
    
    public static void runTestWithDiscount(Integer discountValue) {
        Id standardPricebookId = Test.getStandardPricebookId();
        
        // Crea un prodotto
        Product2 prod = new Product2(Name = 'Test Product', IsActive = true);
        insert prod;
        
        // Crea un PricebookEntry
        PricebookEntry stdPbe = new PricebookEntry(
            Product2Id = prod.Id,
            Pricebook2Id = standardPricebookId,
            UnitPrice = 100,
            IsActive = true
        );
        insert stdPbe;
        
        //Crea un Lead
        Lead lead = new Lead(
            FirstName = 'Test',
            LastName = 'Lead',
            Email = 'test@lead.com',
            Phone = '123456');
        insert lead;
        
        // Crea un'opportunità
        Opportunity opp = new Opportunity(
            Name = 'Test Opp',
            CloseDate = Date.today().addDays(10),
            StageName = 'Prospecting',
            Lead__c=lead.id,
            Event_Start_Date__c=Date.today().addDays(5),
            Event_End_Date__c=Date.today().addDays(6)
        );
        insert opp;
        
        // Crea una quote
        Quote quote = new Quote(
            Name = 'Test Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = standardPricebookId,
            Status = 'Draft'
        );
        insert quote;
        
        // QuoteLineItem da inserire tramite il metodo
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = quote.Id,
            Quantity = 1,
            UnitPrice = 100,
            PricebookEntryId = stdPbe.Id
        );
        
        // Prepara input
        CreateQuoteLines.InputWrapper input = new CreateQuoteLines.InputWrapper();
        input.discount = discountValue;
        input.totalQuoteLines = new List<QuoteLineItem>{ qli };
            input.quoteId = quote.Id;
        input.opp = opp;
        input.vatApplicable = 'yes';
        
        Test.startTest();
        CreateQuoteLines.createUpdateRecords(new List<CreateQuoteLines.InputWrapper>{ input });
        Test.stopTest();
        
        // Asserzioni
        List<QuoteLineItem> resultQLI = [SELECT Id, Discount FROM QuoteLineItem WHERE QuoteId = :quote.Id];
        System.assertEquals(1, resultQLI.size());
        
        if (discountValue != null && discountValue > 0) {
            System.assertEquals(discountValue, resultQLI[0].Discount);
        } else {
            System.assertEquals(null, resultQLI[0].Discount);
        }
        
        Quote updatedQuote = [SELECT Id, Tax FROM Quote WHERE Id = :quote.Id];
        System.assertNotEquals(null, updatedQuote.Tax);
        System.assert(updatedQuote.Tax > 0);
        
        Opportunity updatedOpp = [SELECT Id, SyncedQuoteId FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(quote.Id, updatedOpp.SyncedQuoteId);
    }
}