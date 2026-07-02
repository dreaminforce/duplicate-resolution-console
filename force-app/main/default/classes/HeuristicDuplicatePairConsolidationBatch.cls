public with sharing class HeuristicDuplicatePairConsolidationBatch implements Database.Batchable<SObject>, Database.Stateful {
  private Id scanId;
  private String objectApiName;
  private String objectLabel;
  private Integer totalRecords;
  private Integer candidatePairs;
  private String failure;

  private Map<Id, Id> parents = new Map<Id, Id>();
  private Map<Id, Integer> bestScoreById = new Map<Id, Integer>();
  private Map<Id, String> bestReasonById = new Map<Id, String>();
  private Map<Id, MemberSnapshot> snapshotById = new Map<Id, MemberSnapshot>();

  @TestVisible
  private static Boolean forceAsyncPersistForTest = false;

  public HeuristicDuplicatePairConsolidationBatch(
    Id scanId,
    String objectApiName,
    String objectLabel,
    Integer totalRecords,
    Integer candidatePairs
  ) {
    this.scanId = scanId;
    this.objectApiName = objectApiName;
    this.objectLabel = objectLabel;
    this.totalRecords = totalRecords == null ? 0 : totalRecords;
    this.candidatePairs = candidatePairs == null ? 0 : candidatePairs;
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    update new Heuristic_Duplicate_Scan__c(
      Id = scanId,
      Status__c = 'Running',
      Object_Api_Name__c = objectApiName,
      Object_Label__c = objectLabel,
      Total_Accounts__c = totalRecords,
      Processed_Accounts__c = totalRecords,
      Candidate_Pairs__c = candidatePairs,
      Last_Heartbeat__c = System.now()
    );

    return Database.getQueryLocator([
      SELECT
        Left_Record_Id__c,
        Right_Record_Id__c,
        Score__c,
        Reason__c,
        Left_Display_Value__c,
        Left_Phone__c,
        Left_City__c,
        Left_Website__c,
        Right_Display_Value__c,
        Right_Phone__c,
        Right_City__c,
        Right_Website__c
      FROM Heuristic_Duplicate_Pair__c
      WHERE Scan__c = :scanId
    ]);
  }

  public void execute(Database.BatchableContext bc, List<SObject> scope) {
    if (!String.isBlank(failure)) {
      return;
    }

    try {
      for (SObject source : scope) {
        Heuristic_Duplicate_Pair__c pairRow = (Heuristic_Duplicate_Pair__c) source;
        Id leftId = parseRecordId(pairRow.Left_Record_Id__c);
        Id rightId = parseRecordId(pairRow.Right_Record_Id__c);
        if (leftId == null || rightId == null) {
          continue;
        }

        union(parents, leftId, rightId);
        PairScore score = new PairScore();
        score.value = toInteger(pairRow.Score__c);
        score.reason = pairRow.Reason__c;
        trackBest(bestScoreById, bestReasonById, leftId, score);
        trackBest(bestScoreById, bestReasonById, rightId, score);
        trackSnapshot(leftId, pairRow.Left_Display_Value__c, pairRow.Left_Phone__c, pairRow.Left_City__c, pairRow.Left_Website__c);
        trackSnapshot(rightId, pairRow.Right_Display_Value__c, pairRow.Right_Phone__c, pairRow.Right_City__c, pairRow.Right_Website__c);
      }
    } catch (Exception ex) {
      failure = describeException(ex);
    }
  }

  public void finish(Database.BatchableContext bc) {
    if (String.isBlank(failure)) {
      try {
        PersistPlan plan = buildPersistPlan();
        if (Test.isRunningTest() && !forceAsyncPersistForTest) {
          persistPlanSynchronouslyForTest(plan);
          return;
        }

        if (plan.groupKeys.isEmpty()) {
          update new Heuristic_Duplicate_Scan__c(
            Id = scanId,
            Status__c = 'Completed',
            Completed_At__c = System.now(),
            Last_Heartbeat__c = System.now(),
            Total_Accounts__c = totalRecords,
            Processed_Accounts__c = totalRecords,
            Candidate_Pairs__c = candidatePairs,
            Flagged_Accounts__c = 0,
            Flagged_Groups__c = 0,
            Error_Message__c = null
          );
          cleanupPairs();
          return;
        }

        Id persistJobId = Database.executeBatch(buildPersistBatch(plan), 1);
        update new Heuristic_Duplicate_Scan__c(
          Id = scanId,
          Status__c = 'Running',
          Job_Id__c = String.valueOf(persistJobId),
          Last_Heartbeat__c = System.now(),
          Total_Accounts__c = totalRecords,
          Processed_Accounts__c = totalRecords,
          Candidate_Pairs__c = candidatePairs
        );
        return;
      } catch (Exception ex) {
        failure = describeException(ex);
      }
    }

    if (!String.isBlank(failure)) {
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
  public static void consolidateSynchronouslyForTest(
    Id scanId,
    String objectApiName,
    String objectLabel,
    Integer totalRecords,
    Integer candidatePairs
  ) {
    HeuristicDuplicatePairConsolidationBatch worker = new HeuristicDuplicatePairConsolidationBatch(
      scanId,
      objectApiName,
      objectLabel,
      totalRecords,
      candidatePairs
    );
    List<SObject> rows = new List<SObject>();
    rows.addAll([
      SELECT
        Left_Record_Id__c,
        Right_Record_Id__c,
        Score__c,
        Reason__c,
        Left_Display_Value__c,
        Left_Phone__c,
        Left_City__c,
        Left_Website__c,
        Right_Display_Value__c,
        Right_Phone__c,
        Right_City__c,
        Right_Website__c
      FROM Heuristic_Duplicate_Pair__c
      WHERE Scan__c = :scanId
    ]);
    worker.execute(null, rows);
    worker.finish(null);
  }

  private PersistPlan buildPersistPlan() {
    PersistPlan plan = new PersistPlan();
    Map<Id, List<Id>> membersByRoot = new Map<Id, List<Id>>();
    for (Id memberId : parents.keySet()) {
      Id root = find(parents, memberId);
      if (!membersByRoot.containsKey(root)) {
        membersByRoot.put(root, new List<Id>());
      }
      membersByRoot.get(root).add(memberId);
    }

    for (Id rootId : membersByRoot.keySet()) {
      List<Id> memberIds = membersByRoot.get(rootId);
      if (memberIds.size() < 2) {
        continue;
      }
      memberIds.sort();
      String groupKey = buildGroupKey(memberIds);
      Integer topScore = 0;
      List<String> memberRecordIds = new List<String>();
      for (Id memberId : memberIds) {
        Integer score = bestScoreById.containsKey(memberId) ? bestScoreById.get(memberId) : 0;
        topScore = Math.max(topScore, score);

        String recordId = String.valueOf(memberId);
        MemberSnapshot snapshot = snapshotById.get(memberId);
        memberRecordIds.add(recordId);
        plan.bestScoreByRecordId.put(recordId, score);
        plan.bestReasonByRecordId.put(recordId, bestReasonById.get(memberId));
        plan.displayByRecordId.put(recordId, snapshot == null ? recordId : snapshot.displayValue);
        if (snapshot != null) {
          plan.phoneByRecordId.put(recordId, snapshot.phone);
          plan.cityByRecordId.put(recordId, snapshot.city);
          plan.websiteByRecordId.put(recordId, snapshot.website);
        }
      }

      plan.groupKeys.add(groupKey);
      plan.memberIdsByGroup.put(groupKey, memberRecordIds);
      plan.topScoreByGroupKey.put(groupKey, topScore);
      plan.groupSummaryByKey.put(groupKey, buildGroupSummary(memberIds, bestReasonById));
    }

    plan.groupKeys.sort();
    return plan;
  }

  private HeuristicDuplicateGroupPersistBatch buildPersistBatch(PersistPlan plan) {
    return new HeuristicDuplicateGroupPersistBatch(
      scanId,
      objectApiName,
      objectLabel,
      totalRecords,
      candidatePairs,
      plan.groupKeys,
      plan.memberIdsByGroup,
      plan.topScoreByGroupKey,
      plan.groupSummaryByKey,
      plan.bestScoreByRecordId,
      plan.bestReasonByRecordId,
      plan.displayByRecordId,
      plan.phoneByRecordId,
      plan.cityByRecordId,
      plan.websiteByRecordId
    );
  }

  private void persistPlanSynchronouslyForTest(PersistPlan plan) {
    HeuristicDuplicateGroupPersistBatch.persistSynchronouslyForTest(
      scanId,
      objectApiName,
      objectLabel,
      totalRecords,
      candidatePairs,
      plan.groupKeys,
      plan.memberIdsByGroup,
      plan.topScoreByGroupKey,
      plan.groupSummaryByKey,
      plan.bestScoreByRecordId,
      plan.bestReasonByRecordId,
      plan.displayByRecordId,
      plan.phoneByRecordId,
      plan.cityByRecordId,
      plan.websiteByRecordId
    );
  }

  private void trackSnapshot(Id recordId, String displayValue, String phone, String city, String website) {
    if (!snapshotById.containsKey(recordId)) {
      MemberSnapshot snapshot = new MemberSnapshot();
      snapshot.displayValue = displayValue;
      snapshot.phone = phone;
      snapshot.city = city;
      snapshot.website = website;
      snapshotById.put(recordId, snapshot);
      return;
    }

    MemberSnapshot existing = snapshotById.get(recordId);
    if (String.isBlank(existing.displayValue)) {
      existing.displayValue = displayValue;
    }
    if (String.isBlank(existing.phone)) {
      existing.phone = phone;
    }
    if (String.isBlank(existing.city)) {
      existing.city = city;
    }
    if (String.isBlank(existing.website)) {
      existing.website = website;
    }
  }

  private void cleanupPairs() {
    if (Test.isRunningTest()) {
      Database.delete([SELECT Id FROM Heuristic_Duplicate_Pair__c WHERE Scan__c = :scanId], false);
      return;
    }

    Database.executeBatch(new HeuristicDuplicatePairCleanupBatch(scanId), 2000);
  }

  private String buildGroupKey(List<Id> sortedMemberIds) {
    List<String> parts = new List<String>();
    for (Id memberId : sortedMemberIds) {
      parts.add(String.valueOf(memberId));
    }

    Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(String.join(parts, '|')));
    String token = EncodingUtil.convertToHex(digest).substring(0, 12).toUpperCase();
    String scanToken = String.valueOf(scanId).right(4);
    return 'HDS-' + scanToken + '-' + token;
  }

  private static String buildGroupSummary(List<Id> memberIds, Map<Id, String> reasonsById) {
    Set<String> reasons = new Set<String>();
    for (Id memberId : memberIds) {
      if (reasonsById.containsKey(memberId) && !String.isBlank(reasonsById.get(memberId))) {
        reasons.add(reasonsById.get(memberId));
      }
    }

    if (reasons.isEmpty()) {
      return 'Grouped by heuristic similarity.';
    }

    List<String> sortedReasons = new List<String>();
    sortedReasons.addAll(reasons);
    sortedReasons.sort();
    String combined = String.join(sortedReasons, ' | ');
    if (combined.length() > 1000) {
      return combined.substring(0, 997) + '...';
    }
    return combined;
  }

  private static Id parseRecordId(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    try {
      return (Id) raw;
    } catch (Exception ignored) {
      return null;
    }
  }

  private static Id find(Map<Id, Id> parent, Id idValue) {
    if (!parent.containsKey(idValue)) {
      parent.put(idValue, idValue);
      return idValue;
    }

    Id root = parent.get(idValue);
    if (root == idValue) {
      return root;
    }

    Id collapsed = find(parent, root);
    parent.put(idValue, collapsed);
    return collapsed;
  }

  private static void union(Map<Id, Id> parent, Id leftId, Id rightId) {
    Id leftRoot = find(parent, leftId);
    Id rightRoot = find(parent, rightId);
    if (leftRoot == rightRoot) {
      return;
    }

    if (String.valueOf(leftRoot) < String.valueOf(rightRoot)) {
      parent.put(rightRoot, leftRoot);
    } else {
      parent.put(leftRoot, rightRoot);
    }
  }

  private static void trackBest(
    Map<Id, Integer> bestScoreById,
    Map<Id, String> bestReasonById,
    Id recordId,
    PairScore score
  ) {
    Integer current = bestScoreById.containsKey(recordId) ? bestScoreById.get(recordId) : -1;
    if (score.value > current) {
      bestScoreById.put(recordId, score.value);
      bestReasonById.put(recordId, score.reason);
    }
  }

  private static Integer toInteger(Object raw) {
    if (raw == null) {
      return 0;
    }
    if (raw instanceof Integer) {
      return (Integer) raw;
    }
    if (raw instanceof Long) {
      return Integer.valueOf(String.valueOf(raw));
    }
    if (raw instanceof Decimal) {
      return ((Decimal) raw).intValue();
    }
    return Integer.valueOf(String.valueOf(raw));
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

  private class MemberSnapshot {
    public String displayValue;
    public String phone;
    public String city;
    public String website;
  }

  private class PairScore {
    public Integer value;
    public String reason;
  }

  private class PersistPlan {
    public List<String> groupKeys = new List<String>();
    public Map<String, List<String>> memberIdsByGroup = new Map<String, List<String>>();
    public Map<String, Integer> topScoreByGroupKey = new Map<String, Integer>();
    public Map<String, String> groupSummaryByKey = new Map<String, String>();
    public Map<String, Integer> bestScoreByRecordId = new Map<String, Integer>();
    public Map<String, String> bestReasonByRecordId = new Map<String, String>();
    public Map<String, String> displayByRecordId = new Map<String, String>();
    public Map<String, String> phoneByRecordId = new Map<String, String>();
    public Map<String, String> cityByRecordId = new Map<String, String>();
    public Map<String, String> websiteByRecordId = new Map<String, String>();
  }
}
