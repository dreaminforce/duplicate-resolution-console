public with sharing class HeuristicDuplicateGroupPersistBatch implements Database.Batchable<String>, Database.Stateful {
  private static final Integer MAX_DML_ROWS_PER_EXECUTE = 9000;

  private Id scanId;
  private String objectApiName;
  private String objectLabel;
  private Integer totalRecords;
  private Integer candidatePairs;
  private List<String> groupKeys;
  private Map<String, List<String>> memberIdsByGroup;
  private Map<String, Integer> topScoreByGroupKey;
  private Map<String, String> groupSummaryByKey;
  private Map<String, Integer> bestScoreByRecordId;
  private Map<String, String> bestReasonByRecordId;
  private Map<String, String> displayByRecordId;
  private Map<String, String> phoneByRecordId;
  private Map<String, String> cityByRecordId;
  private Map<String, String> websiteByRecordId;

  private Integer flaggedGroups = 0;
  private Integer flaggedRecords = 0;
  private String failure;

  public HeuristicDuplicateGroupPersistBatch(
    Id scanId,
    String objectApiName,
    String objectLabel,
    Integer totalRecords,
    Integer candidatePairs,
    List<String> groupKeys,
    Map<String, List<String>> memberIdsByGroup,
    Map<String, Integer> topScoreByGroupKey,
    Map<String, String> groupSummaryByKey,
    Map<String, Integer> bestScoreByRecordId,
    Map<String, String> bestReasonByRecordId,
    Map<String, String> displayByRecordId,
    Map<String, String> phoneByRecordId,
    Map<String, String> cityByRecordId,
    Map<String, String> websiteByRecordId
  ) {
    this.scanId = scanId;
    this.objectApiName = objectApiName;
    this.objectLabel = objectLabel;
    this.totalRecords = totalRecords == null ? 0 : totalRecords;
    this.candidatePairs = candidatePairs == null ? 0 : candidatePairs;
    this.groupKeys = groupKeys == null ? new List<String>() : groupKeys;
    this.memberIdsByGroup = memberIdsByGroup == null ? new Map<String, List<String>>() : memberIdsByGroup;
    this.topScoreByGroupKey = topScoreByGroupKey == null ? new Map<String, Integer>() : topScoreByGroupKey;
    this.groupSummaryByKey = groupSummaryByKey == null ? new Map<String, String>() : groupSummaryByKey;
    this.bestScoreByRecordId = bestScoreByRecordId == null ? new Map<String, Integer>() : bestScoreByRecordId;
    this.bestReasonByRecordId = bestReasonByRecordId == null ? new Map<String, String>() : bestReasonByRecordId;
    this.displayByRecordId = displayByRecordId == null ? new Map<String, String>() : displayByRecordId;
    this.phoneByRecordId = phoneByRecordId == null ? new Map<String, String>() : phoneByRecordId;
    this.cityByRecordId = cityByRecordId == null ? new Map<String, String>() : cityByRecordId;
    this.websiteByRecordId = websiteByRecordId == null ? new Map<String, String>() : websiteByRecordId;
  }

  public Iterable<String> start(Database.BatchableContext bc) {
    Heuristic_Duplicate_Scan__c scanUpdate = new Heuristic_Duplicate_Scan__c(
      Id = scanId,
      Status__c = 'Running',
      Object_Api_Name__c = objectApiName,
      Object_Label__c = objectLabel,
      Total_Accounts__c = totalRecords,
      Processed_Accounts__c = totalRecords,
      Candidate_Pairs__c = candidatePairs,
      Last_Heartbeat__c = System.now()
    );
    if (bc != null) {
      scanUpdate.Job_Id__c = String.valueOf(bc.getJobId());
    }
    update scanUpdate;

    return groupKeys;
  }

  public void execute(Database.BatchableContext bc, List<String> scope) {
    if (!String.isBlank(failure)) {
      return;
    }

    try {
      Integer requiredDmlRows = 0;
      for (String groupKey : scope) {
        List<String> memberIds = memberIdsByGroup.get(groupKey);
        if (memberIds == null || memberIds.size() < 2) {
          continue;
        }
        requiredDmlRows += 1 + memberIds.size();
      }

      if (requiredDmlRows > MAX_DML_ROWS_PER_EXECUTE) {
        throw new PersistException(
          'Too many final duplicate members to persist in one batch transaction. Reduce the batch scope or raise the threshold.'
        );
      }

      List<String> persistedGroupKeys = new List<String>();
      List<Heuristic_Duplicate_Group__c> groupsToInsert = new List<Heuristic_Duplicate_Group__c>();
      for (String groupKey : scope) {
        List<String> memberIds = memberIdsByGroup.get(groupKey);
        if (memberIds == null || memberIds.size() < 2) {
          continue;
        }

        groupsToInsert.add(new Heuristic_Duplicate_Group__c(
          Scan__c = scanId,
          Object_Api_Name__c = objectApiName,
          Group_Key__c = groupKey,
          Record_Count__c = memberIds.size(),
          Top_Score__c = topScoreByGroupKey.containsKey(groupKey) ? topScoreByGroupKey.get(groupKey) : 0,
          Summary__c = groupSummaryByKey.containsKey(groupKey)
            ? groupSummaryByKey.get(groupKey)
            : 'Grouped by heuristic similarity.'
        ));
        persistedGroupKeys.add(groupKey);
      }

      if (groupsToInsert.isEmpty()) {
        return;
      }

      insert groupsToInsert;
      flaggedGroups += groupsToInsert.size();

      List<Heuristic_Duplicate_Member__c> membersToInsert = new List<Heuristic_Duplicate_Member__c>();
      for (Integer i = 0; i < persistedGroupKeys.size(); i++) {
        String groupKey = persistedGroupKeys[i];
        Id groupId = groupsToInsert[i].Id;
        for (String recordId : memberIdsByGroup.get(groupKey)) {
          membersToInsert.add(new Heuristic_Duplicate_Member__c(
            Scan__c = scanId,
            Group__c = groupId,
            Object_Api_Name__c = objectApiName,
            Record_Id__c = recordId,
            Display_Value__c = displayByRecordId.containsKey(recordId) ? displayByRecordId.get(recordId) : recordId,
            Score__c = bestScoreByRecordId.containsKey(recordId) ? bestScoreByRecordId.get(recordId) : 0,
            Reason__c = bestReasonByRecordId.get(recordId),
            Phone__c = phoneByRecordId.get(recordId),
            City__c = cityByRecordId.get(recordId),
            Website__c = websiteByRecordId.get(recordId)
          ));
        }
      }

      if (!membersToInsert.isEmpty()) {
        insert membersToInsert;
        flaggedRecords += membersToInsert.size();
      }
    } catch (Exception ex) {
      failure = describeException(ex);
    }
  }

  public void finish(Database.BatchableContext bc) {
    if (String.isBlank(failure)) {
      update new Heuristic_Duplicate_Scan__c(
        Id = scanId,
        Status__c = 'Completed',
        Completed_At__c = System.now(),
        Last_Heartbeat__c = System.now(),
        Total_Accounts__c = totalRecords,
        Processed_Accounts__c = totalRecords,
        Candidate_Pairs__c = candidatePairs,
        Flagged_Accounts__c = flaggedRecords,
        Flagged_Groups__c = flaggedGroups,
        Error_Message__c = null
      );
    } else {
      update new Heuristic_Duplicate_Scan__c(
        Id = scanId,
        Status__c = 'Failed',
        Completed_At__c = System.now(),
        Last_Heartbeat__c = System.now(),
        Total_Accounts__c = totalRecords,
        Processed_Accounts__c = totalRecords,
        Candidate_Pairs__c = candidatePairs,
        Error_Message__c = failure
      );
    }

    cleanupPairs();
  }

  @TestVisible
  public static void persistSynchronouslyForTest(
    Id scanId,
    String objectApiName,
    String objectLabel,
    Integer totalRecords,
    Integer candidatePairs,
    List<String> groupKeys,
    Map<String, List<String>> memberIdsByGroup,
    Map<String, Integer> topScoreByGroupKey,
    Map<String, String> groupSummaryByKey,
    Map<String, Integer> bestScoreByRecordId,
    Map<String, String> bestReasonByRecordId,
    Map<String, String> displayByRecordId,
    Map<String, String> phoneByRecordId,
    Map<String, String> cityByRecordId,
    Map<String, String> websiteByRecordId
  ) {
    HeuristicDuplicateGroupPersistBatch worker = new HeuristicDuplicateGroupPersistBatch(
      scanId,
      objectApiName,
      objectLabel,
      totalRecords,
      candidatePairs,
      groupKeys,
      memberIdsByGroup,
      topScoreByGroupKey,
      groupSummaryByKey,
      bestScoreByRecordId,
      bestReasonByRecordId,
      displayByRecordId,
      phoneByRecordId,
      cityByRecordId,
      websiteByRecordId
    );
    worker.start(null);
    worker.execute(null, groupKeys == null ? new List<String>() : groupKeys);
    worker.finish(null);
  }

  private void cleanupPairs() {
    if (Test.isRunningTest()) {
      Database.delete([SELECT Id FROM Heuristic_Duplicate_Pair__c WHERE Scan__c = :scanId], false);
      return;
    }

    Database.executeBatch(new HeuristicDuplicatePairCleanupBatch(scanId), 2000);
  }

  private static String describeException(Exception ex) {
    if (ex == null) {
      return 'Unknown error.';
    }

    String message = ex.getMessage();
    if (String.isBlank(message)) {
      message = ex.getTypeName();
    }

    if (message.length() > 32768) {
      return message.substring(0, 32765) + '...';
    }
    return message;
  }

  private class PersistException extends Exception {
  }
}
