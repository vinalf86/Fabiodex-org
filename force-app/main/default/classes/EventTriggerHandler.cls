public class EventTriggerHandler {

    // ─────────────────────────────────────────────────────────────────────────
    // AFTER INSERT — Prenotazione nuova call: popola data e setta stage
    // ─────────────────────────────────────────────────────────────────────────
    public static void handleAfterInsert(List<Event> newEvents) {
        try {
            String targetSubject = getTargetSubject();
            if (String.isBlank(targetSubject)) return;

            List<Event> matchingEvents = new List<Event>();
            for (Event ev : newEvents) {
                if (ev.Subject != null && ev.Subject.containsIgnoreCase(targetSubject)) {
                    matchingEvents.add(ev);
                }
            }
            if (matchingEvents.isEmpty()) return;

            Map<String, Date> emailToDate = buildEmailToDateMap(matchingEvents);
            // Per insert: escludiamo Vendita Fissata (non riaprire opp già chiuse o già fissate)
            List<Opportunity> oppsToUpdate = queryOpportunities(emailToDate.keySet(), true);

            List<Opportunity> toUpdate = new List<Opportunity>();
            for (Opportunity opp : oppsToUpdate) {
                String leadEmail = opp.Lead__r.Email;
                if (emailToDate.containsKey(leadEmail)) {
                    opp.Chiamata_prenotata__c = emailToDate.get(leadEmail);
                    opp.StageName = 'Vendita Fissata';
                    toUpdate.add(opp);
                }
            }

            if (!toUpdate.isEmpty()) {
                update toUpdate;
            }

        } catch (Exception e) {
            logError('handleAfterInsert', e);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AFTER UPDATE — Modifica call: aggiorna solo la data, stage invariato
    // ─────────────────────────────────────────────────────────────────────────
    public static void handleAfterUpdate(List<Event> newEvents, Map<Id, Event> oldMap) {
        try {
            String targetSubject = getTargetSubject();
            if (String.isBlank(targetSubject)) return;

            List<Event> matchingEvents = new List<Event>();
            for (Event ev : newEvents) {
                if (ev.Subject != null && ev.Subject.containsIgnoreCase(targetSubject)) {
                    matchingEvents.add(ev);
                }
            }
            if (matchingEvents.isEmpty()) return;

            Set<String> emails = buildEmailSet(matchingEvents);
            // Per update: includiamo anche Vendita Fissata (l'opp esiste già in quello stage)
            List<Opportunity> oppsToUpdate = queryOpportunities(emails, false);

            List<Opportunity> toUpdate = new List<Opportunity>();
            for (Opportunity opp : oppsToUpdate) {
                if (emails.contains(opp.Lead__r.Email)) {
                    opp.Chiamata_prenotata__c = Date.today();
                    // StageName lasciato invariato
                    toUpdate.add(opp);
                }
            }

            if (!toUpdate.isEmpty()) {
                update toUpdate;
            }

        } catch (Exception e) {
            logError('handleAfterUpdate', e);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AFTER DELETE — Cancellazione call: rimuovi data e torna a "Richiesta"
    // ─────────────────────────────────────────────────────────────────────────
    public static void handleAfterDelete(List<Event> oldEvents) {
        try {
            String targetSubject = getTargetSubject();
            if (String.isBlank(targetSubject)) return;

            List<Event> matchingEvents = new List<Event>();
            for (Event ev : oldEvents) {
                if (ev.Subject != null && ev.Subject.containsIgnoreCase(targetSubject)) {
                    matchingEvents.add(ev);
                }
            }
            if (matchingEvents.isEmpty()) return;

            Set<String> emails = buildEmailSet(matchingEvents);
            // Per delete: includiamo anche Vendita Fissata (dobbiamo resettarla)
            List<Opportunity> oppsToUpdate = queryOpportunities(emails, false);

            List<Opportunity> toUpdate = new List<Opportunity>();
            for (Opportunity opp : oppsToUpdate) {
                if (emails.contains(opp.Lead__r.Email)) {
                    opp.Chiamata_prenotata__c = null;
                    opp.StageName = 'Richiesta';
                    toUpdate.add(opp);
                }
            }

            if (!toUpdate.isEmpty()) {
                update toUpdate;
            }

        } catch (Exception e) {
            logError('handleAfterDelete', e);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // METODI PRIVATI DI SUPPORTO
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Recupera il soggetto target dal Custom Setting UserIds__c
     */
    private static String getTargetSubject() {
        UserIds__c setting = UserIds__c.getInstance();
        if (setting == null || String.isBlank(setting.Event_Subject__c)) {
            System.debug(LoggingLevel.WARN, 'EventTriggerHandler: Custom Setting UserIds__c non configurato o Event_Subject vuoto.');
            return null;
        }
        return setting.Event_Subject__c;
    }

    /**
     * Costruisce una mappa Email → Data evento dagli eventi corrispondenti.
     * L'email viene recuperata tramite WhoId → Lead.Email, poiché ev.Email
     * non è un campo accessibile direttamente sull'oggetto Event in Apex.
     */
    private static Map<String, Date> buildEmailToDateMap(List<Event> events) {
        Map<Id, Date> whoIdToDate = new Map<Id, Date>();
        for (Event ev : events) {
            if (ev.WhoId != null) {
                whoIdToDate.put(ev.WhoId, ev.ActivityDate);
            }
        }

        Map<String, Date> emailToDate = new Map<String, Date>();
        if (whoIdToDate.isEmpty()) return emailToDate;

        for (Lead l : [SELECT Id, Email FROM Lead WHERE Id IN :whoIdToDate.keySet()]) {
            if (String.isNotBlank(l.Email)) {
                emailToDate.put(l.Email, whoIdToDate.get(l.Id));
            }
        }
        return emailToDate;
    }

    /**
     * Restituisce il set delle email dagli eventi tramite WhoId → Lead.Email.
     */
    private static Set<String> buildEmailSet(List<Event> events) {
        Set<Id> whoIds = new Set<Id>();
        for (Event ev : events) {
            if (ev.WhoId != null) whoIds.add(ev.WhoId);
        }

        Set<String> emails = new Set<String>();
        if (whoIds.isEmpty()) return emails;

        for (Lead l : [SELECT Email FROM Lead WHERE Id IN :whoIds]) {
            if (String.isNotBlank(l.Email)) emails.add(l.Email);
        }
        return emails;
    }

    /**
     * Query sulle Opportunity aperte con email Lead corrispondente.
     * - excludeVenditaFissata = true  → usato su INSERT (non riaprire opp già fissate)
     * - excludeVenditaFissata = false → usato su UPDATE/DELETE (l'opp è già in Vendita Fissata)
     */
    private static List<Opportunity> queryOpportunities(Set<String> emails, Boolean excludeVenditaFissata) {
        if (emails == null || emails.isEmpty()) return new List<Opportunity>();

        if (excludeVenditaFissata) {
            return [
                SELECT Id, StageName, Lead__c, Lead__r.Email, Chiamata_prenotata__c
                FROM Opportunity
                WHERE Lead__r.Email IN :emails
                  AND StageName NOT IN ('Chiusa/Vinta', 'Chiusa/Persa', 'Vendita Fissata')
            ];
        } else {
            return [
                SELECT Id, StageName, Lead__c, Lead__r.Email, Chiamata_prenotata__c
                FROM Opportunity
                WHERE Lead__r.Email IN :emails
                  AND StageName NOT IN ('Chiusa/Vinta', 'Chiusa/Persa')
            ];
        }
    }

    /**
     * Centralizza il log degli errori; estendibile con piattaforma di logging custom
     */
    private static void logError(String methodName, Exception e) {
        System.debug(
            LoggingLevel.ERROR,
            'EventTriggerHandler.' + methodName + ' — ' + e.getMessage() + ' | Stack: ' + e.getStackTraceString()
        );
    }
}