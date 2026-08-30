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
        String signatureHeader = getHeaderIgnoreCase(req.headers, SIGNATURE_HEADER);
        String timestampHeader = getHeaderIgnoreCase(req.headers, TIMESTAMP_HEADER);
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

    /** RestRequest.headers è case-sensitive sulle chiavi, ma su questo sito i nomi degli header
     * arrivano in minuscolo (normalizzazione legata a HTTP/2 lungo il percorso Cloudflare/edge) —
     * confermato analizzando il contenuto reale di req.headers in fase di collaudo. Cerchiamo quindi
     * l'header ignorando maiuscole/minuscole, senza fare affidamento su una particolare casistica. */
    private static String getHeaderIgnoreCase(Map<String, String> headers, String headerName) {
        if (headers == null) {
            return null;
        }
        for (String key : headers.keySet()) {
            if (key.equalsIgnoreCase(headerName)) {
                return headers.get(key);
            }
        }
        return null;
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

        if (opp.Data_ricezione_caparra__c != null) {
            // La caparra risulta già ricevuta in una chiamata precedente: questo evento
            // può riguardare solo il pagamento del saldo (i due pagamenti arrivano quasi
            // sempre in momenti diversi, ma il metodo chiamato da Revolut è lo stesso).
            if (opp.Data_ricezione_saldo__c == null) {
                opp.Data_ricezione_saldo__c = Date.today();
                needsUpdate = true;
            }
        } else if (opp.Caparra__c != null && opp.Amount != null) {
            if (opp.Caparra__c == opp.Amount) {
                // La caparra copre l'intero importo: caparra e saldo vengono ricevuti
                // nello stesso pagamento.
                opp.Data_ricezione_caparra__c = Date.today();
                opp.Data_ricezione_saldo__c = Date.today();
                needsUpdate = true;
            } else {
                // Caparra__c < Amount: pagamento della sola caparra, caso normale.
                // Caparra__c > Amount: dato anomalo (la caparra impostata supera il totale),
                // ma per decisione esplicita viene trattato allo stesso modo, segnalando
                // comunque l'anomalia con un log per la revisione manuale.
                opp.Data_ricezione_caparra__c = Date.today();
                needsUpdate = true;
                if (opp.Caparra__c > opp.Amount) {
                    logAnomaly('CAPARRA_MAGGIORE_AMOUNT',
                        'Caparra__c (' + opp.Caparra__c + ') è maggiore di Amount (' + opp.Amount + ') sull\'Opportunity ' +
                            opp.Id + ': trattato comunque come pagamento della caparra.',
                        reference, rawBody);
                }
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