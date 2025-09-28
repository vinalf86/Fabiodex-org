public class LeadConversion {
    /**
* Converte un Lead con lo stato Qualified.
* - Se Company è valorizzato => Business Account
* - Se Company è vuoto => Person Account
* - Non viene creata nessuna Opportunità
*/
        public static void convertLead(List<String> leadIds) {
        // Recupero il Lead
        Lead leadToConvert = [
            SELECT Id, Status, Company, IsConverted
            FROM Lead
            WHERE Id IN :leadIds
            AND Status != 'Qualified'
            LIMIT 1
        ];
        
        if (leadToConvert == null) {
            throw new AuraHandledException('Lead non trovato, già convertito o già in stato "Qualified".');
        }
        
        leadToConvert.Status = 'Qualified';
        update leadToConvert;
        
        // Preparo la conversione
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(leadToConvert.Id);
        lc.setConvertedStatus(leadToConvert.Status);
        lc.setDoNotCreateOpportunity(true);
        
        // Eseguo la conversione
        Database.LeadConvertResult result = Database.convertLead(lc);
        
        if (!result.isSuccess()) {
            throw new AuraHandledException('Errore durante la conversione del Lead: ' + result.getErrors()[0].getMessage());
        }
    }
}