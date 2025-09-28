public class CreateQuoteLines {

    //Wrapper che contiene le variabili di input
    public class InputWrapper {
        @invocableVariable(required=false)
        public Integer discount;

        @invocableVariable(required=true)
        public List<QuoteLineItem> totalQuoteLines;

        @invocableVariable(required=true)
        public Id quoteId;

        @invocableVariable(required=true)
        public Opportunity opp;

        @InvocableVariable(required=false)
        public String vatApplicable;

    }
	//Metodo invocabile che riceve in input la classe wrapper come lista
    @invocableMethod(label='Create Quote Lines' description='Create Quote Lines, update Tax and discount if needed and sync with the Opportunity' category='Opportunity')
    public static void createUpdateRecords(List<InputWrapper> inputs) {
        
        //Creazione liste da usare nelle operazioni DML finali
        List<QuoteLineItem> quoteLines = new List<QuoteLineItem>();
        List<Quote> quote = new List<Quote>();
        List<Opportunity> updatedOpp = new List<Opportunity>();

        /*Loop principale sugli input del wrapper, all'interno del quale vengono compiute 
        le varie operazioni di calcolo e modifica sull'oggetto*/
        for(InputWrapper input : inputs) {
            
        //Controlla se lo sconto è stato inserito e lo aggiunge sui Quote Line Items, altrimenti no
        if(input.discount!=null && input.discount>0) {
             for(QuoteLineItem qli : input.totalQuoteLines){
                qli.discount = input.discount;
                quoteLines.add(qli);
            }
        }
        else{
            for(QuoteLineItem qli : input.totalQuoteLines){
                quoteLines.add(qli);
        }        
    }
    //Controlla se bisogna applicare l'IVA o meno
    if(input.vatApplicable=='yes') {
               Quote newQuote = [SELECT Id, Tax, TotalPrice 
                                FROM Quote
                                WHERE Id = :input.quoteId
                                LIMIT 1];
        
        newQuote.Tax = newQuote.TotalPrice * 0.22;
        quote.add(newQuote);
        }
    
    //Sincronizza il preventivo con l'Opportunità
    input.opp.SyncedQuoteId = input.quoteId;
    updatedOpp.add(input.opp);
}
        insert quoteLines;
        update quote;
        update updatedOpp;
}
}