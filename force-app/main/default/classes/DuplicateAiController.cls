public with sharing class DuplicateAiController {
  @AuraEnabled(cacheable=true)
  public static List<DuplicateAiService.ObjectOption> getObjectOptions() {
    return DuplicateAiService.getObjectOptions();
  }

  @AuraEnabled
  public static DuplicateAiService.AnalysisResponse analyzeObject(
    String objectApiName,
    Integer maxSets,
    Boolean runAi
  ) {
    return DuplicateAiService.analyzeObject(objectApiName, maxSets, runAi);
  }

  @AuraEnabled
  public static DuplicateAiService.DuplicateSetAnalysis analyzeSingleSet(
    String objectApiName,
    Id duplicateRecordSetId,
    Boolean runAi
  ) {
    return DuplicateAiService.analyzeSingleSet(objectApiName, duplicateRecordSetId, runAi);
  }

  @AuraEnabled
  public static DuplicateAiService.ActionResult mergeRecords(
    String objectApiName,
    Id parentRecordId,
    List<Id> childRecordIds
  ) {
    return DuplicateAiService.mergeRecords(objectApiName, parentRecordId, childRecordIds);
  }

  @AuraEnabled
  public static DuplicateAiService.ActionResult deleteRecords(List<Id> recordIds) {
    return DuplicateAiService.deleteRecords(recordIds);
  }
}
