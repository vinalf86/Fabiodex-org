@isTest
private class RevolutWebhookHandlerTest {

    private static final String TEST_SECRET = 'test-signing-secret';

    // Mock HTTP per la GET di richiamo sull'ordine (usata solo quando il payload ricevuto non
    // contiene già merchant_order_data.reference)
    private class OrderLookupMock implements HttpCalloutMock {
        Integer statusCode;
        String responseBody;

        OrderLookupMock(Integer statusCode, String responseBody) {
            this.statusCode = statusCode;
            this.responseBody = responseBody;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(responseBody);
            return res;
        }
    }

    // Metodo di utilità per creare un'Opportunità valida (stesso pattern già usato altrove:
    // Lead__c soddisfa la validation rule Account_or_Lead)
    private static Opportunity createOpportunity(String uniqueSuffix, Decimal caparra, Decimal amount, String stageName) {
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
            StageName = stageName,
            CloseDate = Date.today().addDays(30),
            Event_Start_Date__c = Date.today(),
            Event_End_Date__c = Date.today().addDays(1),
            Lead__c = l.Id,
            Caparra__c = caparra,
            Amount = amount
        );
        insert opp;
        return opp;
    }

    private static String computeSignature(String secret, String timestamp, String rawBody) {
        String payloadToSign = 'v1.' + timestamp + '.' + rawBody;
        Blob hmac = Crypto.generateMac('hmacSHA256', Blob.valueOf(payloadToSign), Blob.valueOf(secret));
        return 'v1=' + EncodingUtil.convertToHex(hmac);
    }

    // Invia il payload al webhook con una firma valida (o volutamente errata), impostando
    // RestContext come farebbe la piattaforma per una vera chiamata REST
    private static void invokeWebhook(String rawBody, Boolean withValidSignature) {
        String timestamp = String.valueOf(Datetime.now().getTime());

        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest/revolut/webhook';
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf(rawBody);
        request.headers.put('Revolut-Request-Timestamp', timestamp);
        request.headers.put('Revolut-Signature',
            withValidSignature ? computeSignature(TEST_SECRET, timestamp, rawBody) : 'v1=firma_non_valida');

        RestContext.request = request;
        RestContext.response = new RestResponse();
        RevolutWebhookHandler.signingSecretOverride = TEST_SECRET;

        RevolutWebhookHandler.handleOrderCompleted();
    }

    private static String orderCompletedPayload(Id opportunityId) {
        return JSON.serialize(new Map<String, Object>{
            'event' => 'ORDER_COMPLETED',
            'id' => 'ord_123',
            'state' => 'completed',
            'merchant_order_data' => new Map<String, Object>{ 'reference' => opportunityId }
        });
    }

    // Scenario 1: pagamento della caparra (Caparra__c < Amount) -> Data_ricezione_caparra__c
    // valorizzata, Stage aggiornato, nessun Log__c
    @isTest
    static void testHandleOrderCompleted_CaparraMinoreDiAmount_ValorizzaDataCaparra() {
        Opportunity opp = createOpportunity('caparra', 100.00, 200.00, 'Richiesta');

        Test.startTest();
        invokeWebhook(orderCompletedPayload(opp.Id), true);
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);

        Opportunity updated = [SELECT StageName, Data_ricezione_caparra__c, Data_ricezione_saldo__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('Chiuse/Conseguite', updated.StageName);
        Assert.areEqual(Date.today(), updated.Data_ricezione_caparra__c);
        Assert.isNull(updated.Data_ricezione_saldo__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Log__c WHERE FailedRecordId__c = :opp.Id]);
    }

    // Scenario 2: pagamento del saldo (Caparra__c == Amount) -> Data_ricezione_saldo__c valorizzata
    @isTest
    static void testHandleOrderCompleted_CaparraUgualeAdAmount_ValorizzaDataSaldo() {
        Opportunity opp = createOpportunity('saldo', 200.00, 200.00, 'Richiesta');

        Test.startTest();
        invokeWebhook(orderCompletedPayload(opp.Id), true);
        Test.stopTest();

        Opportunity updated = [SELECT StageName, Data_ricezione_caparra__c, Data_ricezione_saldo__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('Chiuse/Conseguite', updated.StageName);
        Assert.areEqual(Date.today(), updated.Data_ricezione_saldo__c);
        Assert.isNull(updated.Data_ricezione_caparra__c);
    }

    // Scenario 3: firma non valida -> 401, log di anomalia, nessun aggiornamento Opportunity
    @isTest
    static void testHandleOrderCompleted_FirmaNonValida_401ELogAnomalia() {
        Opportunity opp = createOpportunity('firmanonvalida', 100.00, 200.00, 'Richiesta');

        Test.startTest();
        invokeWebhook(orderCompletedPayload(opp.Id), false);
        Test.stopTest();

        Assert.areEqual(401, RestContext.response.statusCode);

        Opportunity updated = [SELECT StageName FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('Richiesta', updated.StageName, 'Con firma non valida non deve succedere nulla sull\'Opportunity');

        List<Log__c> logs = [SELECT ResultCode__c, Status__c FROM Log__c WHERE ResultCode__c = 'SIGNATURE_INVALID'];
        Assert.areEqual(1, logs.size());
        Assert.areEqual('Failed', logs[0].Status__c);
    }

    // Scenario 4: timestamp fuori tolleranza (>5 minuti) -> firma considerata non valida, 401
    @isTest
    static void testHandleOrderCompleted_TimestampFuoriTolleranza_401() {
        Opportunity opp = createOpportunity('timestampvecchio', 100.00, 200.00, 'Richiesta');
        String rawBody = orderCompletedPayload(opp.Id);
        String oldTimestamp = String.valueOf(Datetime.now().addMinutes(-10).getTime());

        RestRequest request = new RestRequest();
        request.requestURI = '/services/apexrest/revolut/webhook';
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf(rawBody);
        request.headers.put('Revolut-Request-Timestamp', oldTimestamp);
        request.headers.put('Revolut-Signature', computeSignature(TEST_SECRET, oldTimestamp, rawBody));
        RestContext.request = request;
        RestContext.response = new RestResponse();
        RevolutWebhookHandler.signingSecretOverride = TEST_SECRET;

        Test.startTest();
        RevolutWebhookHandler.handleOrderCompleted();
        Test.stopTest();

        Assert.areEqual(401, RestContext.response.statusCode);
    }

    // Scenario 5: body non JSON valido -> 400, log di anomalia
    @isTest
    static void testHandleOrderCompleted_BodyNonJsonValido_400ELogAnomalia() {
        Test.startTest();
        invokeWebhook('non è json valido {{{', true);
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode);
        Assert.areEqual(1, [SELECT COUNT() FROM Log__c WHERE ResultCode__c = 'PAYLOAD_INVALID']);
    }

    // Scenario 6: payload senza merchant_order_data.reference -> fallback GET sull'ordine recupera la reference
    @isTest
    static void testHandleOrderCompleted_PayloadSenzaReference_RecuperaConGetSullOrdine() {
        Opportunity opp = createOpportunity('fallbackget', 100.00, 200.00, 'Richiesta');

        String rawBody = JSON.serialize(new Map<String, Object>{
            'event' => 'ORDER_COMPLETED',
            'order_id' => 'ord_456',
            'state' => 'completed'
        });
        String orderDetails = JSON.serialize(new Map<String, Object>{
            'id' => 'ord_456',
            'state' => 'completed',
            'merchant_order_data' => new Map<String, Object>{ 'reference' => opp.Id }
        });
        Test.setMock(HttpCalloutMock.class, new OrderLookupMock(200, orderDetails));

        Test.startTest();
        invokeWebhook(rawBody, true);
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        Opportunity updated = [SELECT Data_ricezione_caparra__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual(Date.today(), updated.Data_ricezione_caparra__c);
    }

    // Scenario 7: reference presente ma non è un Id Salesforce valido -> log di anomalia, nessuna eccezione
    @isTest
    static void testHandleOrderCompleted_ReferenceNonValida_LogAnomalia() {
        String rawBody = JSON.serialize(new Map<String, Object>{
            'event' => 'ORDER_COMPLETED',
            'id' => 'ord_789',
            'state' => 'completed',
            'merchant_order_data' => new Map<String, Object>{ 'reference' => 'non-e-un-id' }
        });

        Test.startTest();
        invokeWebhook(rawBody, true);
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.areEqual(1, [SELECT COUNT() FROM Log__c WHERE ResultCode__c = 'REFERENCE_INVALID']);
    }

    // Scenario 8: reference valida ma nessuna Opportunity trovata -> log di anomalia
    @isTest
    static void testHandleOrderCompleted_OpportunityNonTrovata_LogAnomalia() {
        // Id sintatticamente valido ma di un record inesistente
        String rawBody = orderCompletedPayload('006000000000001AAA');

        Test.startTest();
        invokeWebhook(rawBody, true);
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        Assert.areEqual(1, [SELECT COUNT() FROM Log__c WHERE ResultCode__c = 'OPPORTUNITY_NOT_FOUND']);
    }

    // Scenario 9: idempotenza -> Stage già Chiuse/Conseguite e data già valorizzata, un secondo
    // evento non sovrascrive la data né crea eccezioni
    @isTest
    static void testHandleOrderCompleted_GiaProcessato_NonSovrascriveELogNulla() {
        Opportunity opp = createOpportunity('idempotenza', 100.00, 200.00, 'Chiuse/Conseguite');
        Date dataOriginale = Date.today().addDays(-5);
        opp.Data_ricezione_caparra__c = dataOriginale;
        update opp;

        Test.startTest();
        invokeWebhook(orderCompletedPayload(opp.Id), true);
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        Opportunity updated = [SELECT StageName, Data_ricezione_caparra__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('Chiuse/Conseguite', updated.StageName);
        Assert.areEqual(dataOriginale, updated.Data_ricezione_caparra__c, 'La data reale del pagamento non deve mai essere sovrascritta');
        Assert.areEqual(0, [SELECT COUNT() FROM Log__c WHERE FailedRecordId__c = :opp.Id]);
    }

    // Scenario 10: Caparra__c > Amount (incoerenza dati) -> log di anomalia, nessun campo data
    // valorizzato, ma lo Stage viene comunque aggiornato
    @isTest
    static void testHandleOrderCompleted_CaparraMaggioreDiAmount_LogAnomaliaMaStageAggiornato() {
        Opportunity opp = createOpportunity('caparramaggiore', 300.00, 200.00, 'Richiesta');

        Test.startTest();
        invokeWebhook(orderCompletedPayload(opp.Id), true);
        Test.stopTest();

        Opportunity updated = [SELECT StageName, Data_ricezione_caparra__c, Data_ricezione_saldo__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('Chiuse/Conseguite', updated.StageName);
        Assert.isNull(updated.Data_ricezione_caparra__c);
        Assert.isNull(updated.Data_ricezione_saldo__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Log__c WHERE ResultCode__c = 'CAPARRA_MAGGIORE_AMOUNT']);
    }

    // Scenario 11: evento diverso da ORDER_COMPLETED (state non completed) -> 200, nessuna
    // azione, nessun log
    @isTest
    static void testHandleOrderCompleted_EventoNonRilevante_NessunaAzione() {
        Opportunity opp = createOpportunity('eventoirrilevante', 100.00, 200.00, 'Richiesta');
        String rawBody = JSON.serialize(new Map<String, Object>{
            'event' => 'ORDER_AUTHORISED',
            'id' => 'ord_999',
            'state' => 'authorised',
            'merchant_order_data' => new Map<String, Object>{ 'reference' => opp.Id }
        });

        Test.startTest();
        invokeWebhook(rawBody, true);
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode);
        Opportunity updated = [SELECT StageName FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('Richiesta', updated.StageName);
        Assert.areEqual(0, [SELECT COUNT() FROM Log__c]);
    }
}