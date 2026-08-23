@RestResource(urlMapping='/revolut/webhook')
global without sharing class RevolutWebhookHandler {

    private static final String SIGNATURE_HEADER = 'Revolut-Signature';
    private static final String TIMESTAMP_HEADER = 'Revolut-Request-Timestamp';
    private static final String SIGNATURE_PREFIX = 'v1=';
    private static final Long TIMESTAMP_TOLERANCE_SECONDS = 300;

    private static final String NAMED_CREDENTIAL_ENDPOINT = 'callout:Revolut_Merchant';
    private static final String ORDERS_PATH = '/api/orders/';
    private static final String API_VERSION_HEADER = 'Revolut-Api-Version';
    private static final String API_VERSION = '2026-04-20';

    // "Chiusa Vinta" non esiste come valore del picklist StageName in questo org: l'unico
    // stage con won = true è "Chiuse/Conseguite" (verificato su OpportunityStage.standardValueSet).
    private static final String STAGE_CHIUSA_VINTA = 'Chiuse/Conseguite';
    private static final String COMPLETED_STATE = 'completed';
    private static final String COMPLETED_EVENT = 'ORDER_COMPLETED';

    private static final String LOG_ORIGIN = 'Revolut';
    private static final String LOG_STATUS_FAILED = 'Failed';

    /** Consente ai test di iniettare un secret senza dipendere dal valore reale nel custom metadata. */
    @TestVisible
    private static String signingSecretOverride;

    @HttpPost
    global static void handleOrderCompleted() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        String rawBody = req.requestBody != null ? req.requestBody.toString() : '';

        try {
            if (!isSignatureValid(req, rawBody)) {
                logAnomaly('SIGNATURE_INVALID', 'Firma webhook non valida o timestamp fuori tolleranza.', null, rawBody);
                res.statusCode = 401;
                return;
            }

            Map<String, Object> payload;
            try {
                payload = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
            } catch (Exception ex) {
                logAnomaly('PAYLOAD_INVALID', 'Body del webhook non deserializzabile: ' + ex.getMessage(), null, rawBody);
                res.statusCode = 400;
                return;
            }

            if (!isRelevantEvent(payload)) {
                res.statusCode = 200;
                return;
            }

            String reference = extractReference(payload);
            if (String.isBlank(reference)) {
                logAnomaly('REFERENCE_MISSING', 'Nessun merchant_order_data.reference nel payload né recuperabile dall\'ordine.',
                    extractOrderId(payload), rawBody);
                res.statusCode = 200;
                return;
            }

            processCompletedOrder(reference, rawBody);
            res.statusCode = 200;

        } catch (Exception ex) {
            logAnomaly(ex.getTypeName(), ex.getMessage() + ' | ' + ex.getStackTraceString(), null, rawBody);
            res.statusCode = 500;
        }
    }

    private static Boolean isSignatureValid(RestRequest req, String rawBody) {
        String signatureHeader = req.headers.get(SIGNATURE_HEADER);
        String timestampHeader = req.headers.get(TIMESTAMP_HEADER);
        if (String.isBlank(signatureHeader) || String.isBlank(timestampHeader)) {
            return false;
        }
        if (!isTimestampWithinTolerance(timestampHeader)) {
            return false;
        }

        String signingSecret = getSigningSecret();
        if (String.isBlank(signingSecret)) {
            return false;
        }

        String payloadToSign = 'v1.' + timestampHeader + '.' + rawBody;
        Blob hmac = Crypto.generateMac('hmacSHA256', Blob.valueOf(payloadToSign), Blob.valueOf(signingSecret));
        String computedSignature = SIGNATURE_PREFIX + EncodingUtil.convertToHex(hmac);

        for (String candidate : signatureHeader.split(',')) {
            if (candidate.trim() == computedSignature) {
                return true;
            }
        }
        return false;
    }

    private static Boolean isTimestampWithinTolerance(String timestampHeader) {
        try {
            Long diffSeconds = Math.abs(Datetime.now().getTime() - Long.valueOf(timestampHeader)) / 1000;
            return diffSeconds <= TIMESTAMP_TOLERANCE_SECONDS;
        } catch (Exception ex) {
            // Formato dell'header non riconosciuto: non blocchiamo solo per questo, la firma
            // HMAC resta la vera verifica di sicurezza.
            return true;
        }
    }

    private static String getSigningSecret() {
        if (signingSecretOverride != null) {
            return signingSecretOverride;
        }
        Revolut_Webhook_Config__mdt config = Revolut_Webhook_Config__mdt.getInstance('Default');
        return config != null ? config.Signing_Secret__c : null;
    }

    private static Boolean isRelevantEvent(Map<String, Object> payload) {
        Object eventValue = payload.get('event');
        if (eventValue != null && eventValue != COMPLETED_EVENT) {
            return false;
        }
        Object stateValue = payload.get('state');
        if (stateValue != null && stateValue != COMPLETED_STATE) {
            return false;
        }
        return true;
    }

    private static String extractReference(Map<String, Object> payload) {
        String directReference = extractNestedReference(payload);
        if (String.isNotBlank(directReference)) {
            return directReference;
        }

        String orderId = extractOrderId(payload);
        if (String.isBlank(orderId)) {
            return null;
        }
        Map<String, Object> order = fetchOrder(orderId);
        return order != null ? extractNestedReference(order) : null;
    }

    private static String extractNestedReference(Map<String, Object> payload) {
        if (payload == null) {
            return null;
        }
        Object merchantOrderData = payload.get('merchant_order_data');
        if (merchantOrderData instanceof Map<String, Object>) {
            Object reference = ((Map<String, Object>) merchantOrderData).get('reference');
            return reference != null ? String.valueOf(reference) : null;
        }
        return null;
    }

    private static String extractOrderId(Map<String, Object> payload) {
        if (payload == null) {
            return null;
        }
        Object orderId = payload.get('order_id');
        if (orderId == null) {
            orderId = payload.get('id');
        }
        return orderId != null ? String.valueOf(orderId) : null;
    }

    private static Map<String, Object> fetchOrder(String orderId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL_ENDPOINT + ORDERS_PATH + orderId);
        req.setMethod('GET');
        req.setHeader(API_VERSION_HEADER, API_VERSION);
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            return null;
        }
        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    private static void processCompletedOrder(String reference, String rawBody) {
        Id opportunityId;
        try {
            opportunityId = Id.valueOf(reference);
        } catch (Exception ex) {
            logAnomaly('REFERENCE_INVALID', 'Il reference non è un Id Salesforce valido: ' + reference, reference, rawBody);
            return;
        }

        List<Opportunity> matches = [
            SELECT Id, Caparra__c, Amount, StageName, Data_ricezione_caparra__c, Data_ricezione_saldo__c
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];
        if (matches.isEmpty()) {
            logAnomaly('OPPORTUNITY_NOT_FOUND', 'Nessuna Opportunity trovata per l\'Id ' + opportunityId, reference, rawBody);
            return;
        }

        Opportunity opp = matches[0];
        Boolean needsUpdate = false;

        if (opp.StageName != STAGE_CHIUSA_VINTA) {
            opp.StageName = STAGE_CHIUSA_VINTA;
            needsUpdate = true;
        }

        if (opp.Caparra__c != null && opp.Amount != null) {
            if (opp.Caparra__c < opp.Amount) {
                if (opp.Data_ricezione_caparra__c == null) {
                    opp.Data_ricezione_caparra__c = Date.today();
                    needsUpdate = true;
                }
            } else if (opp.Caparra__c == opp.Amount) {
                if (opp.Data_ricezione_saldo__c == null) {
                    opp.Data_ricezione_saldo__c = Date.today();
                    needsUpdate = true;
                }
            } else {
                logAnomaly('CAPARRA_MAGGIORE_AMOUNT',
                    'Caparra__c (' + opp.Caparra__c + ') è maggiore di Amount (' + opp.Amount + ') sull\'Opportunity ' + opp.Id,
                    reference, rawBody);
            }
        } else {
            logAnomaly('IMPORTI_MANCANTI',
                'Caparra__c o Amount non valorizzati sull\'Opportunity ' + opp.Id + ': impossibile determinare quale campo data valorizzare.',
                reference, rawBody);
        }

        if (needsUpdate) {
            update opp;
        }
    }

    private static void logAnomaly(String resultCode, String message, String relatedRecordId, String payload) {
        Log__c logRecord = new Log__c();
        logRecord.FailedRecordId__c = relatedRecordId;
        logRecord.Origin__c = LOG_ORIGIN;
        logRecord.ResultCode__c = resultCode;
        logRecord.SystemException__c = message;
        logRecord.Payload__c = payload;
        logRecord.Status__c = LOG_STATUS_FAILED;
        insert logRecord;
    }
}