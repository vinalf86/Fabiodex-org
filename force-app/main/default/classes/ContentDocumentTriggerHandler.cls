public with sharing class ContentDocumentTriggerHandler {

    public void afterInsertHandler(List<ContentDocument> contentDocuments) {

        if (contentDocuments == null || contentDocuments.isEmpty()) return;

        Set<Id> contractDocIds = new Set<Id>();
        for (ContentDocument cd : contentDocuments) {
            if (cd.Title.contains('Contratto firmato')) {
                contractDocIds.add(cd.Id);
            }
        }

        if (contractDocIds.isEmpty()) return;

        String oppKeyPrefix = Schema.SObjectType.Opportunity.getKeyPrefix();
        Set<Id> oppIds = new Set<Id>();

        for (ContentDocumentLink cdl : [
            SELECT LinkedEntityId
            FROM ContentDocumentLink
            WHERE ContentDocumentId IN :contractDocIds
        ]) {
            if (cdl.LinkedEntityId != null &&
                String.valueOf(cdl.LinkedEntityId).startsWith(oppKeyPrefix)) {
                oppIds.add(cdl.LinkedEntityId);
            }
        }

        if (oppIds.isEmpty()) return;

        List<Opportunity> oppsToUpdate = [
            SELECT Id, Name, StageName
            FROM Opportunity
            WHERE Id IN :oppIds
            AND StageName NOT IN ('Chiuse/Conseguite', 'Contratto firmato')
        ];

        if (oppsToUpdate.isEmpty()) return;

        // Recupera gli Id utente dal Custom Setting
        UserIds__c userIdsSetting = UserIds__c.getInstance();
        Set<String> recipientIds = new Set<String>();
        if (String.isNotBlank(userIdsSetting.Sabrina__c)) {
            recipientIds.add(userIdsSetting.Sabrina__c);
        }
        if (String.isNotBlank(userIdsSetting.Fabio__c)) {
            recipientIds.add(userIdsSetting.Fabio__c);
        } 

        // Recupera il tipo di notifica custom
        CustomNotificationType notifType = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = 'Nuova_Opportunita'
            LIMIT 1
        ];

        for (Opportunity o : oppsToUpdate) {
            o.StageName = 'Contratto firmato';
        }

        List<Database.SaveResult> results = Database.update(oppsToUpdate, false);

        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                // Notifica di successo
                Messaging.CustomNotification successNotif = new Messaging.CustomNotification();
                successNotif.setNotificationTypeId(notifType.Id);
                successNotif.setTitle('Contratto Firmato');
                successNotif.setBody('Il contratto per l\'Opportunità ' + oppsToUpdate[i].Name + ' è stato firmato.');
                successNotif.setTargetId(oppsToUpdate[i].Id);
                try {
                    successNotif.send(recipientIds);
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, 'Errore invio notifica successo: ' + e.getMessage());
                }
            } else {
                // Notifica di errore
                String errorMsg = results[i].getErrors()[0].getMessage();
                System.debug(LoggingLevel.ERROR, 'Errore aggiornamento Opportunity ' + oppsToUpdate[i].Id + ': ' + errorMsg);

                Messaging.CustomNotification errorNotif = new Messaging.CustomNotification();
                errorNotif.setNotificationTypeId(notifType.Id);
                errorNotif.setTitle('Errore aggiornamento Opportunità');
                errorNotif.setBody('Errore durante l\'aggiornamento dell\'Opportunità ' + oppsToUpdate[i].Name + ': ' + errorMsg);
                errorNotif.setTargetId(oppsToUpdate[i].Id);
                try {
                    errorNotif.send(recipientIds);
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, 'Errore invio notifica errore: ' + e.getMessage());
                }
            }
        }
    }
}