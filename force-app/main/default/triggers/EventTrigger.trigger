trigger EventTrigger on Event (after insert, after update, after delete) {

    if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            EventTriggerHandler.handleAfterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            EventTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
        } else if (Trigger.isDelete) {
            EventTriggerHandler.handleAfterDelete(Trigger.old);
        }
    }
}