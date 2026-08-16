@isTest
private class RevolutPaymentLinkServiceTest {

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

    // Mock per lo scenario bulk con esiti misti: risponde in base a quale Opportunity
    // riconosce nel body della richiesta, per simulare successo/fallimento nella stessa chiamata.
    private class BulkMixedMock implements HttpCalloutMock {
        Id successOpportunityId;

        BulkMixedMock(Id successOpportunityId) {
            this.successOpportunityId = successOpportunityId;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getBody().contains(successOpportunityId)) {
                res.setStatusCode(201);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'id' => 'ord_1', 'token' => 'tok_1', 'state' => 'pending',
                    'checkout_url' => 'https://checkout.revolut.com/payment-link/tok_1'
                }));
            } else {
                res.setStatusCode(400);
                res.setBody('{"message":"Fallito"}');
            }
            return res;
        }
    }

    // Metodo di utilità per creare un'Opportunità valida (stesso pattern di
    // ContentDocumentTriggerHandlerTest: Lead__c soddisfa la validation rule Account_or_Lead)
    private static Opportunity createOpportunity(String uniqueSuffix, Decimal caparra) {
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
            Caparra__c = caparra
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
    static void testGenerateRevolutPaymentLinks_Successo_AggiornaLinkEInviaBodyCorretto() {
        Opportunity opp = createOpportunity('successo', 150.00);
        RevolutApiMock mock = new RevolutApiMock(201, successResponseBody('ord_123', 'tok_456'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        RevolutPaymentLinkService.generateRevolutPaymentLinks(new List<Opportunity>{ opp });
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
    static void testGenerateRevolutPaymentLinks_Risposta400_CreaLogSenzaStackTrace() {
        Opportunity opp = createOpportunity('fallimento400', 150.00);
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(400, '{"code":"invalid_amount"}'));

        Test.startTest();
        RevolutPaymentLinkService.generateRevolutPaymentLinks(new List<Opportunity>{ opp });
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
    static void testGenerateRevolutPaymentLinks_Risposta201BodyMalformato_CreaLog() {
        Opportunity opp = createOpportunity('bodymalformato', 150.00);
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(201, 'non è json valido {{{'));

        Test.startTest();
        RevolutPaymentLinkService.generateRevolutPaymentLinks(new List<Opportunity>{ opp });
        Test.stopTest();

        Log__c logRecord = [SELECT ResultCode__c, SystemException__c FROM Log__c WHERE FailedRecordId__c = :opp.Id];
        Assert.areEqual('201', logRecord.ResultCode__c);
        Assert.isTrue(logRecord.SystemException__c.contains('deserializzabile'));
    }

    // Scenario 4: risposta 201 valida ma senza checkout_url -> Log__c
    @isTest
    static void testGenerateRevolutPaymentLinks_Risposta201SenzaCheckoutUrl_CreaLog() {
        Opportunity opp = createOpportunity('senzacheckouturl', 150.00);
        String responseBody = JSON.serialize(new Map<String, Object>{ 'id' => 'ord_123', 'state' => 'pending' });
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(201, responseBody));

        Test.startTest();
        RevolutPaymentLinkService.generateRevolutPaymentLinks(new List<Opportunity>{ opp });
        Test.stopTest();

        Log__c logRecord = [SELECT SystemException__c FROM Log__c WHERE FailedRecordId__c = :opp.Id];
        Assert.isTrue(logRecord.SystemException__c.contains('checkout_url'));
    }

    // Scenario 5: timeout/CalloutException -> Log__c con stack trace reale e payload salvato
    @isTest
    static void testGenerateRevolutPaymentLinks_Timeout_CreaLogConStackTraceEPayload() {
        Opportunity opp = createOpportunity('timeout', 150.00);
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(new CalloutException('Read timed out')));

        Test.startTest();
        RevolutPaymentLinkService.generateRevolutPaymentLinks(new List<Opportunity>{ opp });
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
    static void testGenerateRevolutPaymentLinks_CaparraNonValida_CreaLogSenzaCallout() {
        List<Decimal> invalidAmounts = new List<Decimal>{ null, 0, -10 };

        Test.startTest();
        for (Integer i = 0; i < invalidAmounts.size(); i++) {
            Opportunity opp = createOpportunity('invalida' + i, invalidAmounts[i]);
            RevolutPaymentLinkService.generateRevolutPaymentLinks(new List<Opportunity>{ opp });

            Log__c logRecord = [SELECT ResultCode__c, SystemException__c, Payload__c FROM Log__c WHERE FailedRecordId__c = :opp.Id];
            Assert.isTrue(logRecord.ResultCode__c.contains('PaymentLinkException'),
                'Caparra__c ' + invalidAmounts[i] + ' dovrebbe generare una PaymentLinkException');
            Assert.isTrue(logRecord.SystemException__c.contains('Caparra__c'));
            Assert.isNull(logRecord.Payload__c, 'La validazione fallisce prima di costruire il body: nessun payload da salvare');
        }
        Test.stopTest();
    }

    // Scenario 7: un secondo fallimento sullo stesso record aggiorna il Log__c esistente,
    // non lo duplica
    @isTest
    static void testGenerateRevolutPaymentLinks_FallimentoRipetuto_AggiornaLogEsistenteSenzaDuplicare() {
        Opportunity opp = createOpportunity('dedup', 150.00);

        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(400, '{"message":"Primo errore"}'));
        RevolutPaymentLinkService.generateRevolutPaymentLinks(new List<Opportunity>{ opp });

        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(500, '{"message":"Secondo errore"}'));

        Test.startTest();
        RevolutPaymentLinkService.generateRevolutPaymentLinks(new List<Opportunity>{ opp });
        Test.stopTest();

        List<Log__c> logs = [SELECT ResultCode__c FROM Log__c WHERE FailedRecordId__c = :opp.Id];
        Assert.areEqual(1, logs.size(), 'Il secondo fallimento deve aggiornare il log esistente, non crearne uno nuovo');
        Assert.areEqual('500', logs[0].ResultCode__c);
    }

    // Scenario 8: un log esistente su un altro gateway per la stessa Opportunity non viene riusato
    @isTest
    static void testGenerateRevolutPaymentLinks_LogEsistenteAltroGateway_NonVieneRiusato() {
        Opportunity opp = createOpportunity('multigateway', 150.00);
        insert new Log__c(FailedRecordId__c = opp.Id, Origin__c = 'Stripe', Status__c = 'Sent');

        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(400, '{"message":"Errore Revolut"}'));

        Test.startTest();
        RevolutPaymentLinkService.generateRevolutPaymentLinks(new List<Opportunity>{ opp });
        Test.stopTest();

        List<Log__c> logs = [SELECT Origin__c FROM Log__c WHERE FailedRecordId__c = :opp.Id];
        Assert.areEqual(2, logs.size(), 'Revolut e Stripe devono restare due log distinti sulla stessa Opportunity');
    }

    // Scenario 9: lista bulk con esiti misti -> ogni record riceve il trattamento corretto
    @isTest
    static void testGenerateRevolutPaymentLinks_ListaBulkConEsitiMisti_TrattaOgniRecordCorrettamente() {
        Opportunity oppSuccesso = createOpportunity('bulksuccesso', 100.00);
        Opportunity oppFallimento = createOpportunity('bulkfallimento', 200.00);
        Test.setMock(HttpCalloutMock.class, new BulkMixedMock(oppSuccesso.Id));

        Test.startTest();
        RevolutPaymentLinkService.generateRevolutPaymentLinks(new List<Opportunity>{ oppSuccesso, oppFallimento });
        Test.stopTest();

        Opportunity updatedSuccesso = [SELECT Link_pagamento__c FROM Opportunity WHERE Id = :oppSuccesso.Id];
        Assert.isNotNull(updatedSuccesso.Link_pagamento__c);

        Assert.areEqual(1, [SELECT COUNT() FROM Log__c WHERE FailedRecordId__c = :oppFallimento.Id]);
        Assert.areEqual(0, [SELECT COUNT() FROM Log__c WHERE FailedRecordId__c = :oppSuccesso.Id]);
    }

    // Scenario 10: lista nulla o vuota -> nessuna eccezione, nessun callout
    @isTest
    static void testGenerateRevolutPaymentLinks_ListaNullaOVuota_NonFaNulla() {
        Test.startTest();
        try {
            RevolutPaymentLinkService.generateRevolutPaymentLinks(null);
            RevolutPaymentLinkService.generateRevolutPaymentLinks(new List<Opportunity>());
            Assert.isTrue(true, 'Nessuna eccezione attesa con lista nulla o vuota');
        } catch (Exception ex) {
            Assert.fail('Non avrebbe dovuto lanciare eccezioni: ' + ex.getMessage());
        }
        Test.stopTest();
    }

    // Scenario 11: più di 100 Opportunity in un'unica chiamata -> eccezione chiara, nessun
    // callout tentato (se venisse tentato, il test fallirebbe comunque: i callout senza mock
    // non sono ammessi nei metodi di test)
    @isTest
    static void testGenerateRevolutPaymentLinks_PiuDiCentoOpportunity_LanciaEccezioneSenzaCallout() {
        List<Opportunity> troppe = new List<Opportunity>();
        for (Integer i = 0; i < 101; i++) {
            troppe.add(new Opportunity());
        }

        Test.startTest();
        try {
            RevolutPaymentLinkService.generateRevolutPaymentLinks(troppe);
            Assert.fail('Oltre 100 Opportunity dovrebbe lanciare una PaymentLinkException');
        } catch (PaymentLinkUtils.PaymentLinkException ex) {
            Assert.isTrue(ex.getMessage().contains('100'));
        }
        Test.stopTest();
    }

    // Scenario 12: generateRevolutPaymentLink (singolo record) funziona come la versione bulk
    @isTest
    static void testGenerateRevolutPaymentLink_SingoloRecord_FunzionaComeLaVersioneBulk() {
        Opportunity opp = createOpportunity('singolo', 150.00);
        Test.setMock(HttpCalloutMock.class, new RevolutApiMock(201, successResponseBody('ord_s', 'tok_s')));

        Test.startTest();
        RevolutPaymentLinkService.generateRevolutPaymentLink(opp);
        Test.stopTest();

        Opportunity updated = [SELECT Link_pagamento__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('https://checkout.revolut.com/payment-link/tok_s', updated.Link_pagamento__c);
    }
}
