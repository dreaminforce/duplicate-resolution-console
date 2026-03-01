public with sharing class HeuristicDuplicateScanController {
  @AuraEnabled(cacheable=true)
  public static List<HeuristicDuplicateScanService.ObjectOption> getObjectOptions() {
    return HeuristicDuplicateScanService.getObjectOptions();
  }

  @AuraEnabled
  public static Id startScan(
    String objectApiName,
    Integer maxRecords,
    Integer scoreThreshold,
    Boolean clearPreviousFlags
  ) {
    return HeuristicDuplicateScanService.startScan(objectApiName, maxRecords, scoreThreshold, clearPreviousFlags);
  }

  @AuraEnabled
  public static HeuristicDuplicateScanService.ScanStatus getScanStatus(Id scanId) {
    return HeuristicDuplicateScanService.getScanStatus(scanId);
  }

  @AuraEnabled
  public static List<HeuristicDuplicateScanService.ScanStatus> getRecentScans(Integer maxRows) {
    return HeuristicDuplicateScanService.getRecentScans(maxRows);
  }

  @AuraEnabled
  public static List<HeuristicDuplicateScanService.DuplicateGroup> getGroupsForScan(Id scanId, Integer maxGroups) {
    return HeuristicDuplicateScanService.getGroupsForScan(scanId, maxGroups);
  }

  @AuraEnabled
  public static HeuristicDuplicateScanService.GroupDetail getGroupDetail(Id groupId) {
    return HeuristicDuplicateScanService.getGroupDetail(groupId);
  }

  @AuraEnabled
  public static DuplicateMergeService.MergeProposal getMergeProposal(
    String objectApiName,
    List<String> recordIds,
    String preferredSurvivorId
  ) {
    return DuplicateMergeService.getMergeProposal(objectApiName, recordIds, preferredSurvivorId);
  }

  @AuraEnabled
  public static DuplicateMergeService.MergeExecutionResult executeMerge(DuplicateMergeService.MergeExecutionRequest request) {
    return DuplicateMergeService.executeMerge(request);
  }

  @AuraEnabled
  public static DuplicateMergeService.MergeExecutionResult executeSoftMerge(
    String objectApiName,
    String survivorRecordId,
    List<String> loserRecordIds,
    List<DuplicateMergeService.FieldSelectionInput> fieldSelections
  ) {
    DuplicateMergeService.MergeExecutionRequest request = new DuplicateMergeService.MergeExecutionRequest();
    request.objectApiName = objectApiName;
    request.survivorRecordId = survivorRecordId;
    request.loserRecordIds = loserRecordIds;
    request.fieldSelections = fieldSelections;
    return DuplicateMergeService.executeMerge(request);
  }

  @AuraEnabled
  public static HeuristicDuplicateScanService.ActionResult mergeRecords(
    String objectApiName,
    Id parentRecordId,
    List<Id> childRecordIds
  ) {
    return HeuristicDuplicateScanService.mergeRecords(objectApiName, parentRecordId, childRecordIds);
  }

  @AuraEnabled
  public static HeuristicDuplicateScanService.ActionResult cancelScan(Id scanId) {
    return HeuristicDuplicateScanService.cancelScan(scanId);
  }
}
