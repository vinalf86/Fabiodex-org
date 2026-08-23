@isTest
private class RevolutPaymentLinkGenerationTest {
    
    @TestSetup
    static void setupUserIdsSetting() {
        insert new UserIds__c(Fabio__c = UserInfo.getUserId());
    }
    
    // Mock HTTP configurabile: risponde con uno status/body fissi, oppure lancia un'eccezione
    // per simulare un timeout/CalloutException.
    private class RevolutApiMock implements HttpCalloutMock {
        Integer statusCode;
        String responseBody;
        Exception exceptionToThrow;
        HttpRequest capturedRequest;
        
        RevolutApiMock(Integer statusCode, String responseBody) {
            this.statusCode = statusCode;
            this.responseBody = responseBody;
        }
        
        RevolutApiMock(Exception exceptionToThrow) {
            this.exceptionToThrow = exceptionToThrow;
        }
        
        public HttpResponse respond(HttpRequest req) {
            capturedRequest = req;
            if (exceptionToThrow != null) {
                throw exceptionToThrow;
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(responseBody);
            return res;
        }
    }
    
    // Metodo di utilità per creare un'Opportunità valida (stesso pattern già usato altrove:
    // Lead__c soddisfa la validation rule Account_or_Lead)
    private static Opportunity createOpportunity(String uniqueSuffix, Decimal caparra) {
        UserIds__c uids = UserIds__c.getOrgDefaults();
        
        Lead l = new Lead(
            FirstName = 'Test',
            LastName = 'Lead ' + uniqueSuffix,
            Company = 'Test Company',
            Email = 'test.' + uniqueSuffix + '@example.com',
            Phone = '1234567890',
            Event_Start_Date__c = Date.today(),
            Event_End_Date__c = Date.today().addDays(1)
        );
        insert l;
        
        Opportunity opp = new Opportunity(
            Name = 'Test Opportunity ' + uniqueSuffix,
            StageName = 'Richiesta',
            CloseDate = Date.today().addDays(30),
            Event_Start_Date__c = Date.today(),
            Event_End_Date__c = Date.today().addDays(1),
            Lead__c = l.Id,
            Caparra__c = caparra,
            OwnerId = uids.Fabio__c
        );
        insert opp;
        return opp;
    }
    
    private static String successResponseBody(String orderId, String token) {
        return JSON.serialize(new Map<String, Object>{
            'id' => orderId,
                'token' => token,
                'state' => 'pending',
                'checkout_url' => 'https://checkout.revolut.com/payment-link/' + token
                });
    }
    
    // Scenario 1: risposta 201 con checkout_url -> successo, endpoint/header/body inviati corretti
    @isTest
    static void testGenerateRevolutPaymentLink_Successo_AggiornaLinkEInviaBodyCorretto() {
        Opportunity opp = createOpportunity('successo', 150.00);
        RevolutApiMock mock = new RevolutApiMock(201, successResponseBody('ord_123', 'tok_456'));
        Test.setMock(HttpCalloutMock.class, mock);
        
        Test.startTest();
        RevolutPaymentLinkGeneration.generateRevolutPaymentLink(new List<Opportunity>{ opp });
        Test.stopTest();
        
        Opportunity updated = [SELECT Link_pagamento__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('https://checkout.revolut.com/payment-link/tok_456', updated.Link_pagamento__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Log__c WHERE FailedRecordId__c = :opp.Id]);
        
        Assert.areEqual('callout:Revolut_Merchant/api/orders', mock.capturedRequest.getEndpoint());
        Assert.areEqual('POST', mock.capturedRequest.getMethod());
        Assert.areEqual('2026-04-20', mock.capturedRequest.getHeader('Revolut-Api-Version'));
        Assert.areEqual('application/json', mock.capturedRequest.getHeader('Content-Type'));
        
        String sentBody = mock.capturedRequest.getBody();
        Assert.isTrue(sentBody.contains('"amount":15000'), 'L\'importo inviato dovrebbe essere in unità minori (150.00 -> 15000)');
        Assert.isTrue(sentBody.contains('"currency":"EUR"'));
        Assert.isTrue(sentBody.contains('"reference":"' + opp.Id + '"'));
        Assert.isTrue(sentBody.contains('"salesforce_record_id":"' + opp.Id + '"'));
    }
    
    // Scenario 2: risposta 400 -> Log__c con dettagli gateway, nessuno stack trace
    @isTest
    static void testGenerateRevolutPaymentLink_Risposta400_CreaLogSenzaStackTrace() {
        Opportunity opp = createOpportunity('fallimento400', 150.00);
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(400, '{"code":"invalid_amount"}'));
        
        Test.startTest();
        RevolutPaymentLinkGeneration.generateRevolutPaymentLink(new List<Opportunity>{ opp });
        Test.stopTest();
        
        Log__c logRecord = [
            SELECT Origin__c, ResultCode__c, SystemException__c, StackTrace__c, Payload__c, Status__c
            FROM Log__c WHERE FailedRecordId__c = :opp.Id
        ];
        Assert.areEqual('Revolut', logRecord.Origin__c);
        Assert.areEqual('400', logRecord.ResultCode__c);
        Assert.isTrue(logRecord.SystemException__c.contains('400'));
        Assert.isNull(logRecord.StackTrace__c, 'Un fallimento di dominio non ha un\'eccezione reale');
        Assert.isNotNull(logRecord.Payload__c, 'Il body inviato dovrebbe essere salvato per il replay');
        Assert.areEqual('Resend', logRecord.Status__c);
        
        Opportunity updated = [SELECT Link_pagamento__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.isNull(updated.Link_pagamento__c);
    }
    
    // Scenario 3: risposta 201 con body non deserializzabile -> Log__c
    @isTest
    static void testGenerateRevolutPaymentLink_Risposta201BodyMalformato_CreaLog() {
        Opportunity opp = createOpportunity('bodymalformato', 150.00);
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(201, 'non è json valido {{{'));
        
        Test.startTest();
        RevolutPaymentLinkGeneration.generateRevolutPaymentLink(new List<Opportunity>{ opp });
        Test.stopTest();
        
        Log__c logRecord = [SELECT ResultCode__c, SystemException__c FROM Log__c WHERE FailedRecordId__c = :opp.Id];
        Assert.areEqual('201', logRecord.ResultCode__c);
        Assert.isTrue(logRecord.SystemException__c.contains('deserializzabile'));
    }
    
    // Scenario 4: risposta 201 valida ma senza checkout_url -> Log__c
    @isTest
    static void testGenerateRevolutPaymentLink_Risposta201SenzaCheckoutUrl_CreaLog() {
        Opportunity opp = createOpportunity('senzacheckouturl', 150.00);
        String responseBody = JSON.serialize(new Map<String, Object>{ 'id' => 'ord_123', 'state' => 'pending' });
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(201, responseBody));
        
        Test.startTest();
        RevolutPaymentLinkGeneration.generateRevolutPaymentLink(new List<Opportunity>{ opp });
        Test.stopTest();
        
        Log__c logRecord = [SELECT SystemException__c FROM Log__c WHERE FailedRecordId__c = :opp.Id];
        Assert.isTrue(logRecord.SystemException__c.contains('checkout_url'));
    }
    
    // Scenario 5: timeout/CalloutException -> Log__c con stack trace reale e payload salvato
    @isTest
    static void testGenerateRevolutPaymentLink_Timeout_CreaLogConStackTraceEPayload() {
        Opportunity opp = createOpportunity('timeout', 150.00);
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(new CalloutException('Read timed out')));
        
        Test.startTest();
        RevolutPaymentLinkGeneration.generateRevolutPaymentLink(new List<Opportunity>{ opp });
        Test.stopTest();
        
        Log__c logRecord = [
            SELECT ResultCode__c, SystemException__c, StackTrace__c, Payload__c
            FROM Log__c WHERE FailedRecordId__c = :opp.Id
        ];
        Assert.areEqual('System.CalloutException', logRecord.ResultCode__c);
        Assert.areEqual('Read timed out', logRecord.SystemException__c);
        Assert.isNotNull(logRecord.StackTrace__c, 'Un\'eccezione reale deve avere uno stack trace');
        Assert.isTrue(logRecord.Payload__c.contains('"amount":15000'), 'Il body già costruito prima del timeout va salvato per il replay');
    }
    
    // Scenario 6: Caparra__c non valida (nulla, zero o negativa) -> Log__c via il percorso di
    // validazione, senza nessun callout e senza payload (il body non viene mai costruito)
    @isTest
    static void testGenerateRevolutPaymentLink_CaparraNonValida_CreaLogSenzaCallout() {
        List<Decimal> invalidAmounts = new List<Decimal>{ null, 0, -10 };
            
            Test.startTest();
        for (Integer i = 0; i < invalidAmounts.size(); i++) {
            Opportunity opp = createOpportunity('invalida' + i, invalidAmounts[i]);
            RevolutPaymentLinkGeneration.generateRevolutPaymentLink(new List<Opportunity>{ opp });
        }
        Test.stopTest();
        
        List<Log__c> logs = [SELECT FailedRecordId__c, ResultCode__c, SystemException__c, Payload__c FROM Log__c];
        Assert.areEqual(3, logs.size(), 'Ognuna delle 3 Opportunity con Caparra__c non valida dovrebbe generare un log');
        for (Log__c logRecord : logs) {
            Assert.isTrue(logRecord.ResultCode__c.contains('PaymentLinkException'));
            Assert.isTrue(logRecord.SystemException__c.contains('Caparra__c'));
            Assert.isNull(logRecord.Payload__c, 'La validazione fallisce prima di costruire il body: nessun payload da salvare');
        }
    }
    
    // Scenario 7: un secondo fallimento sullo stesso record aggiorna il Log__c esistente,
    // non lo duplica. La seconda "esecuzione asincrona" è simulata richiamando execute()
    // direttamente sul Queueable: un secondo Test.startTest() non è ammesso nello stesso
    // metodo di test, e qui serve comunque solo un callout mockato, non un vero accodamento.
    @isTest
    static void testGenerateRevolutPaymentLink_FallimentoRipetuto_AggiornaLogEsistenteSenzaDuplicare() {
        Opportunity opp = createOpportunity('dedup', 150.00);
        
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(400, '{"message":"Primo errore"}'));
        Test.startTest();
        RevolutPaymentLinkGeneration.generateRevolutPaymentLink(new List<Opportunity>{ opp });
        Test.stopTest();
        
        List<Log__c> logsAfterFirst = [SELECT ResultCode__c FROM Log__c WHERE FailedRecordId__c = :opp.Id];
        Assert.areEqual(1, logsAfterFirst.size());
        Assert.areEqual('400', logsAfterFirst[0].ResultCode__c);
        
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(500, '{"message":"Secondo errore"}'));
        new RevolutPaymentLinkGeneration.AsyncProcessor(opp.Id).execute(null);
        
        List<Log__c> logsAfterSecond = [SELECT ResultCode__c FROM Log__c WHERE FailedRecordId__c = :opp.Id];
        Assert.areEqual(1, logsAfterSecond.size(), 'Il secondo fallimento deve aggiornare il log esistente, non crearne uno nuovo');
        Assert.areEqual('500', logsAfterSecond[0].ResultCode__c);
    }
    
    // Scenario 8: un log esistente su un altro gateway per la stessa Opportunity non viene riusato
    @isTest
    static void testGenerateRevolutPaymentLink_LogEsistenteAltroGateway_NonVieneRiusato() {
        Opportunity opp = createOpportunity('multigateway', 150.00);
        insert new Log__c(FailedRecordId__c = opp.Id, Origin__c = 'Stripe', Status__c = 'Sent');
        
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(400, '{"message":"Errore Revolut"}'));
        
        Test.startTest();
        RevolutPaymentLinkGeneration.generateRevolutPaymentLink(new List<Opportunity>{ opp });
        Test.stopTest();
        
        List<Log__c> logs = [SELECT Origin__c FROM Log__c WHERE FailedRecordId__c = :opp.Id];
        Assert.areEqual(2, logs.size(), 'Revolut e Stripe devono restare due log distinti sulla stessa Opportunity');
    }
    
    // Scenario 9: lista nulla o vuota -> nessuna eccezione, nessun job accodato
    @isTest
    static void testGenerateRevolutPaymentLink_ListaNullaOVuota_NonFaNulla() {
        Test.startTest();
        try {
            RevolutPaymentLinkGeneration.generateRevolutPaymentLink(null);
            RevolutPaymentLinkGeneration.generateRevolutPaymentLink(new List<Opportunity>());
            Assert.isTrue(true, 'Nessuna eccezione attesa con lista nulla o vuota');
        } catch (Exception ex) {
            Assert.fail('Non avrebbe dovuto lanciare eccezioni: ' + ex.getMessage());
        }
        Test.stopTest();
        
        Assert.areEqual(0, Limits.getAsyncCalls(), 'Nessun job Queueable dovrebbe essere stato accodato');
    }
    
    // Scenario 10: se qualcuno chiama il metodo da Apex con più di un elemento (Flow non lo
    // farà mai, ma la firma List<Opportunity> resta chiamabile così), viene elaborato solo il
    // primo — comportamento esplicito, non un bug
    @isTest
    static void testGenerateRevolutPaymentLink_PiuDiUnElemento_ElaboraSoloIlPrimo() {
        Opportunity primaOpp = createOpportunity('prima', 150.00);
        Opportunity secondaOpp = createOpportunity('seconda', 150.00);
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(201, successResponseBody('ord_1', 'tok_1')));
        
        Test.startTest();
        RevolutPaymentLinkGeneration.generateRevolutPaymentLink(new List<Opportunity>{ primaOpp, secondaOpp });
        Test.stopTest();
        
        Opportunity primaAggiornata = [SELECT Link_pagamento__c FROM Opportunity WHERE Id = :primaOpp.Id];
        Opportunity secondaAggiornata = [SELECT Link_pagamento__c FROM Opportunity WHERE Id = :secondaOpp.Id];
        Assert.isNotNull(primaAggiornata.Link_pagamento__c, 'Il primo elemento della lista deve essere elaborato');
        Assert.isNull(secondaAggiornata.Link_pagamento__c, 'Gli elementi successivi al primo devono essere ignorati');
    }
}