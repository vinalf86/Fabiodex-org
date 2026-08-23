public with sharing class RevolutPaymentLinkGeneration {

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

    public class Request {
        @InvocableVariable(label='Opportunity' description='Opportunity per cui generare il link di pagamento Revolut.' required=true)
        public Opportunity opportunity;

        @InvocableVariable(label='Importo ordine' description='Importo da addebitare su Revolut per questo ordine (es. caparra o saldo), calcolato dal chiamante.' required=true)
        public Decimal orderAmount;
    }

    @InvocableMethod(label='Crea link di pagamento Revolut' description='Crea in modo asincrono il link di pagamento Revolut per le Opportunity passate come input.')
    public static void generateRevolutPaymentLinks(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        if (requests.size() > MAX_CALLOUTS_PER_TRANSACTION) {
            throw new PaymentLinkUtils.PaymentLinkException('Troppe richieste in una chiamata (' +
                requests.size() + '): il limite Salesforce è ' + MAX_CALLOUTS_PER_TRANSACTION +
                ' callout per transazione. Suddividere il lavoro in batch più piccoli.');
        }

        Map<Id, Decimal> orderAmountByOpportunityId = new Map<Id, Decimal>();
        for (Request req : requests) {
            if (req != null && req.opportunity != null && req.opportunity.Id != null) {
                orderAmountByOpportunityId.put(req.opportunity.Id, req.orderAmount);
            }
        }
        if (orderAmountByOpportunityId.isEmpty()) {
            return;
        }

        System.enqueueJob(new AsyncProcessor(orderAmountByOpportunityId));
    }

    public class AsyncProcessor implements Queueable, Database.AllowsCallouts {

        private Map<Id, Decimal> orderAmountByOpportunityId;

        public AsyncProcessor(Map<Id, Decimal> orderAmountByOpportunityId) {
            this.orderAmountByOpportunityId = orderAmountByOpportunityId;
        }

        public void execute(QueueableContext context) {
            List<Opportunity> opportunities = [
                SELECT Id, Caparra__c
                FROM Opportunity
                WHERE Id IN :orderAmountByOpportunityId.keySet()
            ];
            if (opportunities.isEmpty()) {
                return;
            }

            Map<Id, Log__c> existingLogsByOpportunityId = fetchExistingLogs(opportunities);

            List<Opportunity> opportunitiesToUpdate = new List<Opportunity>();
            List<Log__c> logsToUpsert = new List<Log__c>();

            for (Opportunity opp : opportunities) {
                processOpportunity(opp, orderAmountByOpportunityId.get(opp.Id), existingLogsByOpportunityId,
                    opportunitiesToUpdate, logsToUpsert);
            }

            if (!opportunitiesToUpdate.isEmpty()) {
                update opportunitiesToUpdate;
            }
            if (!logsToUpsert.isEmpty()) {
                upsert logsToUpsert;
            }
        }
    }

    private static void processOpportunity(Opportunity opp, Decimal orderAmount, Map<Id, Log__c> existingLogsByOpportunityId,
            List<Opportunity> opportunitiesToUpdate, List<Log__c> logsToUpsert) {

        String requestBody;
        try {
            validate(opp, orderAmount);
            requestBody = buildRequestBody(opp, orderAmount);
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
            logsToUpsert.add(buildLog(existingLogsByOpportunityId.get(opp.Id), opp.Id,
                ex.getTypeName(), ex.getMessage(), ex.getStackTraceString(), requestBody));
        }
    }

    private static void validate(Opportunity opp, Decimal orderAmount) {
        if (opp == null || opp.Id == null) {
            throw new PaymentLinkUtils.PaymentLinkException('Opportunity non valida: Id mancante.');
        }
        if (opp.Caparra__c == null || opp.Caparra__c <= 0) {
            throw new PaymentLinkUtils.PaymentLinkException('Il campo Caparra deve essere valorizzato e deve avere un valore positivo.');
        }
        if (orderAmount == null || orderAmount <= 0) {
            throw new PaymentLinkUtils.PaymentLinkException('orderAmount deve essere valorizzato e deve avere un valore positivo.');
        }
    }

    private static String buildRequestBody(Opportunity opp, Decimal orderAmount) {
        Map<String, Object> body = new Map<String, Object>();
        body.put('amount', PaymentLinkUtils.toMinorUnits(orderAmount));
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
