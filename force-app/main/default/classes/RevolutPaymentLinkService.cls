/**
 * Genera link di pagamento Revolut (hosted checkout) per una o più Opportunity: legge
 * l'importo da Caparra__c, chiama la Revolut Merchant API (versione 2026-04-20) e, in base
 * all'esito, valorizza Link_pagamento__c oppure registra l'errore su Log__c.
 *
 * Bulk by design: generateRevolutPaymentLinks accetta sempre una List<Opportunity> e
 * bulkifica query di dedup e DML (1 query di lettura + al massimo 2 DML in scrittura totali,
 * indipendentemente da quante Opportunity vengono passate). generateRevolutPaymentLink
 * (singolare) è solo una comodità per i call site con un solo record: richiama sempre la
 * versione bulk. L'unica cosa che NON si può bulkificare è il callout HTTP in sé: Revolut non
 * offre una API per creare più ordini in una sola chiamata, quindi c'è comunque 1 callout per
 * Opportunity. Per questo il metodo rifiuta liste più lunghe del limite Salesforce di 100
 * callout per transazione, con un errore chiaro invece di un LimitException a metà lista.
 *
 * Precondizione sui record in input: ogni Opportunity deve arrivare con almeno i campi Id e
 * Caparra__c già interrogati (es. dal Flow/trigger chiamante) — questa classe non fa una query
 * di completamento, per evitare una SELECT ridondante quando il chiamante li ha già.
 *
 * Prerequisito da configurare a mano in Setup (NON gestito da questa classe, per non mettere
 * mai una chiave nel codice): Named Credential "Revolut_Merchant" con External Credential
 * collegata che inietta l'header Authorization: Bearer <Secret API key> ad ogni callout su
 * "callout:Revolut_Merchant". L'header "Revolut-Api-Version" invece non è un segreto: viene
 * impostato qui in Apex.
 *
 * Due percorsi di errore, loggati entrambi su Log__c con Status__c = 'Resend':
 * - Revolut risponde ma non con 201, o con un body inatteso: non c'è un'eccezione Apex reale,
 *   quindi StackTrace__c resta vuoto; ResultCode__c = lo status HTTP restituito dal gateway.
 * - Eccezione di sistema (timeout, importo non valido...): StackTrace__c e SystemException__c
 *   vengono presi dall'eccezione reale; ResultCode__c = il tipo dell'eccezione (es.
 *   'System.CalloutException'). Payload__c viene comunque valorizzato con il body già
 *   costruito, se il fallimento è avvenuto dopo la sua costruzione (es. su un timeout) — è
 *   proprio il caso più ambiguo (non si sa se Revolut ha ricevuto l'ordine prima di scadere)
 *   in cui riaverlo per il replay conta di più.
 *
 * Dedup: prima di creare un nuovo Log__c, si cerca uno esistente con lo stesso
 * FailedRecordId__c (l'Id dell'Opportunity) e Origin__c = 'Revolut'. Se trovato, viene
 * aggiornato invece di duplicato — così un futuro log di un altro gateway sulla stessa
 * Opportunity non viene mai sovrascritto. Retry__c non viene mai toccato qui: parte da 0 per
 * default sul nuovo record, e il suo incremento è compito del futuro job di retry schedulato.
 */
public with sharing class RevolutPaymentLinkService {

    private static final String NAMED_CREDENTIAL_ENDPOINT = 'callout:Revolut_Merchant';
    private static final String ORDERS_PATH = '/api/orders';
    private static final String API_VERSION_HEADER = 'Revolut-Api-Version';
    private static final String API_VERSION = '2026-04-20';
    private static final Integer TIMEOUT_MS = 30000;
    private static final Integer HTTP_CREATED = 201;
    private static final String CURRENCY_EUR = 'EUR';
    private static final String ORIGIN = 'Revolut';
    private static final String LOG_STATUS_RESEND = 'Resend';
    private static final Integer MAX_CALLOUTS_PER_TRANSACTION = 100;

    /** Comodità per un solo record: internamente richiama sempre la versione bulk. */
    public static void generateRevolutPaymentLink(Opportunity opportunity) {
        generateRevolutPaymentLinks(new List<Opportunity>{ opportunity });
    }

    public static void generateRevolutPaymentLinks(List<Opportunity> opportunities) {
        if (opportunities == null || opportunities.isEmpty()) {
            return;
        }
        if (opportunities.size() > MAX_CALLOUTS_PER_TRANSACTION) {
            throw new PaymentLinkUtils.PaymentLinkException('Troppe Opportunità in una chiamata (' +
                opportunities.size() + '): il limite Salesforce è ' + MAX_CALLOUTS_PER_TRANSACTION +
                ' callout per transazione. Suddividere il lavoro in batch più piccoli.');
        }

        Map<Id, Log__c> existingLogsByOpportunityId = fetchExistingLogs(opportunities);

        List<Opportunity> opportunitiesToUpdate = new List<Opportunity>();
        List<Log__c> logsToUpsert = new List<Log__c>();

        for (Opportunity opp : opportunities) {
            processOpportunity(opp, existingLogsByOpportunityId, opportunitiesToUpdate, logsToUpsert);
        }

        if (!opportunitiesToUpdate.isEmpty()) {
            update opportunitiesToUpdate;
        }
        if (!logsToUpsert.isEmpty()) {
            upsert logsToUpsert;
        }
    }

    // Fa tutto il lavoro per una singola Opportunity: valida, chiama Revolut, decide se
    // aggiornare il record o loggare un errore. Tutto in un unico metodo con return anticipati
    // per ogni esito, così non serve un tipo "risultato" a parte solo per passare i dettagli
    // tra metodi diversi.
    private static void processOpportunity(Opportunity opp, Map<Id, Log__c> existingLogsByOpportunityId,
            List<Opportunity> opportunitiesToUpdate, List<Log__c> logsToUpsert) {

        String requestBody;
        try {
            validate(opp);
            requestBody = buildRequestBody(opp);
            HttpResponse response = sendCallout(requestBody);
            Integer statusCode = response.getStatusCode();
            String responseBody = response.getBody();

            if (statusCode != HTTP_CREATED) {
                logsToUpsert.add(buildLog(existingLogsByOpportunityId.get(opp.Id), opp.Id,
                    String.valueOf(statusCode),
                    'Revolut ha risposto con status ' + statusCode + ' invece di ' + HTTP_CREATED,
                    null, requestBody));
                return;
            }

            Map<String, Object> parsed;
            try {
                parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            } catch (Exception ex) {
                logsToUpsert.add(buildLog(existingLogsByOpportunityId.get(opp.Id), opp.Id,
                    String.valueOf(statusCode), 'Risposta Revolut non deserializzabile: ' + ex.getMessage(),
                    null, requestBody));
                return;
            }

            String checkoutUrl = (String) parsed.get('checkout_url');
            if (String.isBlank(checkoutUrl)) {
                logsToUpsert.add(buildLog(existingLogsByOpportunityId.get(opp.Id), opp.Id,
                    String.valueOf(statusCode), 'Risposta Revolut priva di checkout_url.', null, requestBody));
                return;
            }

            opportunitiesToUpdate.add(new Opportunity(Id = opp.Id, Link_pagamento__c = checkoutUrl));

        } catch (Exception ex) {
            // requestBody qui può essere null (se validate() ha fallito prima di costruirlo)
            // o valorizzato (es. su un timeout dopo che il body era già pronto): in entrambi i
            // casi è la variabile locale giusta da salvare in Payload__c, senza bisogno che
            // l'eccezione la porti con sé.
            logsToUpsert.add(buildLog(existingLogsByOpportunityId.get(opp.Id), opp.Id,
                ex.getTypeName(), ex.getMessage(), ex.getStackTraceString(), requestBody));
        }
    }

    private static void validate(Opportunity opp) {
        if (opp == null || opp.Id == null) {
            throw new PaymentLinkUtils.PaymentLinkException('Opportunity non valida: Id mancante.');
        }
        if (opp.Caparra__c == null || opp.Caparra__c <= 0) {
            throw new PaymentLinkUtils.PaymentLinkException('Caparra__c deve essere un valore positivo.');
        }
    }

    private static String buildRequestBody(Opportunity opp) {
        Map<String, Object> body = new Map<String, Object>();
        body.put('amount', PaymentLinkUtils.toMinorUnits(opp.Caparra__c));
        body.put('currency', CURRENCY_EUR);
        body.put('merchant_order_data', new Map<String, Object>{ 'reference' => opp.Id });
        body.put('metadata', new Map<String, String>{ 'salesforce_record_id' => opp.Id });
        return JSON.serialize(body);
    }

    private static HttpResponse sendCallout(String requestBody) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL_ENDPOINT + ORDERS_PATH);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader(API_VERSION_HEADER, API_VERSION);
        req.setBody(requestBody);
        req.setTimeout(TIMEOUT_MS);
        return new Http().send(req);
    }

    private static Map<Id, Log__c> fetchExistingLogs(List<Opportunity> opportunities) {
        Set<Id> opportunityIds = new Set<Id>();
        for (Opportunity opp : opportunities) {
            opportunityIds.add(opp.Id);
        }

        Map<Id, Log__c> logsByOpportunityId = new Map<Id, Log__c>();
        for (Log__c logRecord : [
            SELECT Id, FailedRecordId__c
            FROM Log__c
            WHERE FailedRecordId__c IN :opportunityIds
            AND Origin__c = :ORIGIN
            ORDER BY CreatedDate DESC
        ]) {
            Id opportunityId = Id.valueOf(logRecord.FailedRecordId__c);
            if (!logsByOpportunityId.containsKey(opportunityId)) {
                // Il primo risultato per ciascun Id è il più recente, grazie all'ORDER BY DESC.
                logsByOpportunityId.put(opportunityId, logRecord);
            }
        }
        return logsByOpportunityId;
    }

    private static Log__c buildLog(Log__c existingLog, Id opportunityId, String resultCode,
            String systemException, String stackTrace, String payload) {

        Log__c logRecord = existingLog != null ? existingLog : new Log__c();
        logRecord.FailedRecordId__c = opportunityId;
        logRecord.Origin__c = ORIGIN;
        logRecord.ResultCode__c = resultCode;
        logRecord.SystemException__c = systemException;
        logRecord.StackTrace__c = stackTrace;
        logRecord.Payload__c = payload;
        logRecord.Status__c = LOG_STATUS_RESEND;
        return logRecord;
    }
}
