public with sharing class HeuristicDuplicateScanService {
  public static final Integer DEFAULT_MAX_RECORDS = 2000;
  public static final Integer MAX_RECORDS_HARD_LIMIT = 5000;
  public static final Integer DEFAULT_THRESHOLD = 78;

  public class ObjectOption {
    @AuraEnabled public String objectApiName;
    @AuraEnabled public String objectLabel;
  }

  public class ScanStatus {
    @AuraEnabled public Id scanId;
    @AuraEnabled public String scanName;
    @AuraEnabled public String objectApiName;
    @AuraEnabled public String objectLabel;
    @AuraEnabled public String status;
    @AuraEnabled public String jobId;
    @AuraEnabled public Datetime createdDate;
    @AuraEnabled public Datetime startedAt;
    @AuraEnabled public Datetime completedAt;
    @AuraEnabled public Datetime lastHeartbeat;
    @AuraEnabled public Integer totalRecords;
    @AuraEnabled public Integer processedRecords;
    @AuraEnabled public Integer candidatePairs;
    @AuraEnabled public Integer flaggedRecords;
    @AuraEnabled public Integer flaggedGroups;
    @AuraEnabled public Integer threshold;
    @AuraEnabled public Integer maxRecords;
    @AuraEnabled public Boolean clearPreviousFlags;
    @AuraEnabled public String errorMessage;
    @AuraEnabled public String asyncStatus;
    @AuraEnabled public Integer asyncItemsProcessed;
    @AuraEnabled public Integer asyncTotalItems;
  }

  public class GroupRecord {
    @AuraEnabled public String recordId;
    @AuraEnabled public String name;
    @AuraEnabled public String phone;
    @AuraEnabled public String city;
    @AuraEnabled public String website;
    @AuraEnabled public Integer score;
    @AuraEnabled public String reason;
  }

  public class DuplicateGroup {
    @AuraEnabled public String groupKey;
    @AuraEnabled public Integer recordCount;
    @AuraEnabled public Integer topScore;
    @AuraEnabled public String summary;
    @AuraEnabled public List<GroupRecord> records;
  }

  public class ActionResult {
    @AuraEnabled public Boolean success;
    @AuraEnabled public String message;
  }

  public static List<ObjectOption> getObjectOptions() {
    List<ObjectOption> options = new List<ObjectOption>();
    for (Schema.SObjectType sType : Schema.getGlobalDescribe().values()) {
      Schema.DescribeSObjectResult d = sType.getDescribe();
      if (!isSupportedObjectForScan(d)) {
        continue;
      }

      ObjectOption opt = new ObjectOption();
      opt.objectApiName = d.getName();
      opt.objectLabel = d.getLabel();
      options.add(opt);
    }

    options.sort(new ObjectOptionSorter());
    return options;
  }

  public static Id startScan(
    String objectApiName,
    Integer maxRecords,
    Integer scoreThreshold,
    Boolean clearPreviousFlags
  ) {
    Schema.DescribeSObjectResult describeResult = validateObjectApiName(objectApiName);

    Integer normalizedMax = sanitizeMaxRecords(maxRecords);
    Integer normalizedThreshold = sanitizeThreshold(scoreThreshold);
    Boolean shouldClear = clearPreviousFlags != false;

    Heuristic_Duplicate_Scan__c scan = new Heuristic_Duplicate_Scan__c(
      Status__c = 'Queued',
      Object_Api_Name__c = objectApiName,
      Object_Label__c = describeResult.getLabel(),
      Max_Accounts__c = normalizedMax,
      Threshold__c = normalizedThreshold,
      Clear_Previous_Flags__c = shouldClear
    );
    insert scan;

    Id jobId = Database.executeBatch(
      new HeuristicDuplicateScanBatch(
        scan.Id,
        objectApiName,
        describeResult.getLabel(),
        normalizedMax,
        normalizedThreshold,
        shouldClear
      ),
      200
    );

    update new Heuristic_Duplicate_Scan__c(
      Id = scan.Id,
      Job_Id__c = String.valueOf(jobId)
    );

    return scan.Id;
  }

  public static ScanStatus getScanStatus(Id scanId) {
    if (scanId == null) {
      throw new AuraHandledException('scanId is required.');
    }

    List<Heuristic_Duplicate_Scan__c> scans = [
      SELECT
        Id,
        Name,
        Object_Api_Name__c,
        Object_Label__c,
        Status__c,
        Job_Id__c,
        CreatedDate,
        Started_At__c,
        Completed_At__c,
        Last_Heartbeat__c,
        Total_Accounts__c,
        Processed_Accounts__c,
        Candidate_Pairs__c,
        Flagged_Accounts__c,
        Flagged_Groups__c,
        Threshold__c,
        Max_Accounts__c,
        Clear_Previous_Flags__c,
        Error_Message__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scanId
      LIMIT 1
    ];

    if (scans.isEmpty()) {
      throw new AuraHandledException('Scan not found: ' + String.valueOf(scanId));
    }

    Map<String, AsyncApexJob> jobsById = queryAsyncJobs(new Set<String>{ scans[0].Job_Id__c });
    return toScanStatus(scans[0], jobsById.get(scans[0].Job_Id__c));
  }

  public static List<ScanStatus> getRecentScans(Integer maxRows) {
    Integer rowCount = maxRows == null || maxRows <= 0 ? 15 : Math.min(maxRows, 50);

    List<Heuristic_Duplicate_Scan__c> scans = [
      SELECT
        Id,
        Name,
        Object_Api_Name__c,
        Object_Label__c,
        Status__c,
        Job_Id__c,
        CreatedDate,
        Started_At__c,
        Completed_At__c,
        Last_Heartbeat__c,
        Total_Accounts__c,
        Processed_Accounts__c,
        Candidate_Pairs__c,
        Flagged_Accounts__c,
        Flagged_Groups__c,
        Threshold__c,
        Max_Accounts__c,
        Clear_Previous_Flags__c,
        Error_Message__c
      FROM Heuristic_Duplicate_Scan__c
      ORDER BY CreatedDate DESC
      LIMIT :rowCount
    ];

    Set<String> jobIds = new Set<String>();
    for (Heuristic_Duplicate_Scan__c scan : scans) {
      if (!String.isBlank(scan.Job_Id__c)) {
        jobIds.add(scan.Job_Id__c);
      }
    }

    Map<String, AsyncApexJob> jobsById = queryAsyncJobs(jobIds);
    List<ScanStatus> response = new List<ScanStatus>();
    for (Heuristic_Duplicate_Scan__c scan : scans) {
      response.add(toScanStatus(scan, jobsById.get(scan.Job_Id__c)));
    }
    return response;
  }

  public static List<DuplicateGroup> getGroupsForScan(Id scanId, Integer maxGroups) {
    if (scanId == null) {
      throw new AuraHandledException('scanId is required.');
    }

    Integer groupLimit = maxGroups == null || maxGroups <= 0 ? 25 : Math.min(maxGroups, 60);

    List<Heuristic_Duplicate_Group__c> groups = [
      SELECT Id, Group_Key__c, Record_Count__c, Top_Score__c, Summary__c
      FROM Heuristic_Duplicate_Group__c
      WHERE Scan__c = :scanId
      ORDER BY Top_Score__c DESC, Record_Count__c DESC, CreatedDate DESC
      LIMIT :groupLimit
    ];

    if (groups.isEmpty()) {
      return new List<DuplicateGroup>();
    }

    Set<Id> groupIds = new Set<Id>();
    Map<Id, DuplicateGroup> byGroupId = new Map<Id, DuplicateGroup>();
    for (Heuristic_Duplicate_Group__c source : groups) {
      groupIds.add(source.Id);

      DuplicateGroup dto = new DuplicateGroup();
      dto.groupKey = source.Group_Key__c;
      dto.recordCount = toInteger(source.Record_Count__c);
      dto.topScore = toInteger(source.Top_Score__c);
      dto.summary = source.Summary__c;
      dto.records = new List<GroupRecord>();
      byGroupId.put(source.Id, dto);
    }

    List<Heuristic_Duplicate_Member__c> members = [
      SELECT Group__c, Record_Id__c, Display_Value__c, Score__c, Reason__c, Phone__c, City__c, Website__c
      FROM Heuristic_Duplicate_Member__c
      WHERE Group__c IN :groupIds
      ORDER BY Group__c ASC, Score__c DESC, Display_Value__c ASC
      LIMIT 5000
    ];

    for (Heuristic_Duplicate_Member__c member : members) {
      if (!byGroupId.containsKey(member.Group__c)) {
        continue;
      }

      GroupRecord row = new GroupRecord();
      row.recordId = member.Record_Id__c;
      row.name = member.Display_Value__c;
      row.phone = member.Phone__c;
      row.city = member.City__c;
      row.website = member.Website__c;
      row.score = toInteger(member.Score__c);
      row.reason = member.Reason__c;
      byGroupId.get(member.Group__c).records.add(row);
    }

    List<DuplicateGroup> response = new List<DuplicateGroup>();
    for (Heuristic_Duplicate_Group__c source : groups) {
      response.add(byGroupId.get(source.Id));
    }

    return response;
  }

  public static ActionResult cancelScan(Id scanId) {
    if (scanId == null) {
      throw new AuraHandledException('scanId is required.');
    }

    List<Heuristic_Duplicate_Scan__c> scans = [
      SELECT Id, Status__c, Job_Id__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scanId
      LIMIT 1
    ];

    if (scans.isEmpty()) {
      throw new AuraHandledException('Scan not found: ' + String.valueOf(scanId));
    }

    Heuristic_Duplicate_Scan__c scan = scans[0];
    ActionResult result = new ActionResult();

    if (String.isBlank(scan.Job_Id__c)) {
      result.success = false;
      result.message = 'No async job is linked to this scan.';
      return result;
    }

    try {
      System.abortJob(scan.Job_Id__c);
      update new Heuristic_Duplicate_Scan__c(
        Id = scan.Id,
        Status__c = 'Cancelled',
        Completed_At__c = System.now(),
        Error_Message__c = 'Cancelled by admin.'
      );

      result.success = true;
      result.message = 'Scan cancelled.';
      return result;
    } catch (Exception ex) {
      result.success = false;
      result.message = 'Failed to cancel scan: ' + ex.getMessage();
      return result;
    }
  }

  private static ScanStatus toScanStatus(Heuristic_Duplicate_Scan__c scan, AsyncApexJob job) {
    ScanStatus dto = new ScanStatus();
    dto.scanId = scan.Id;
    dto.scanName = scan.Name;
    dto.objectApiName = scan.Object_Api_Name__c;
    dto.objectLabel = scan.Object_Label__c;
    dto.status = scan.Status__c;
    dto.jobId = scan.Job_Id__c;
    dto.createdDate = scan.CreatedDate;
    dto.startedAt = scan.Started_At__c;
    dto.completedAt = scan.Completed_At__c;
    dto.lastHeartbeat = scan.Last_Heartbeat__c;
    dto.totalRecords = toInteger(scan.Total_Accounts__c);
    dto.processedRecords = toInteger(scan.Processed_Accounts__c);
    dto.candidatePairs = toInteger(scan.Candidate_Pairs__c);
    dto.flaggedRecords = toInteger(scan.Flagged_Accounts__c);
    dto.flaggedGroups = toInteger(scan.Flagged_Groups__c);
    dto.threshold = toInteger(scan.Threshold__c);
    dto.maxRecords = toInteger(scan.Max_Accounts__c);
    dto.clearPreviousFlags = scan.Clear_Previous_Flags__c;
    dto.errorMessage = scan.Error_Message__c;

    if (job != null) {
      dto.asyncStatus = job.Status;
      dto.asyncItemsProcessed = job.JobItemsProcessed;
      dto.asyncTotalItems = job.TotalJobItems;
    }

    return dto;
  }

  private static Map<String, AsyncApexJob> queryAsyncJobs(Set<String> jobIds) {
    Map<String, AsyncApexJob> out = new Map<String, AsyncApexJob>();
    if (jobIds == null || jobIds.isEmpty()) {
      return out;
    }

    Set<Id> typedIds = new Set<Id>();
    for (String jobId : jobIds) {
      if (!String.isBlank(jobId) && String.valueOf(jobId).length() >= 15) {
        typedIds.add((Id) jobId);
      }
    }

    if (typedIds.isEmpty()) {
      return out;
    }

    try {
      for (AsyncApexJob job : [
        SELECT Id, Status, JobItemsProcessed, TotalJobItems
        FROM AsyncApexJob
        WHERE Id IN :typedIds
      ]) {
        out.put(String.valueOf(job.Id), job);
      }
    } catch (Exception ignored) {
      return out;
    }

    return out;
  }

  private static Schema.DescribeSObjectResult validateObjectApiName(String objectApiName) {
    if (String.isBlank(objectApiName) || !Schema.getGlobalDescribe().containsKey(objectApiName)) {
      throw new AuraHandledException('Unknown object: ' + objectApiName);
    }

    Schema.DescribeSObjectResult d = Schema.getGlobalDescribe().get(objectApiName).getDescribe();
    if (!isSupportedObjectForScan(d)) {
      throw new AuraHandledException('Object not supported for scanning: ' + objectApiName);
    }

    return d;
  }

  private static Boolean isSupportedObjectForScan(Schema.DescribeSObjectResult d) {
    if (d == null) {
      return false;
    }
    if (!d.isQueryable() || d.isDeprecatedAndHidden() || d.isCustomSetting()) {
      return false;
    }

    String label = d.getLabel();
    if (String.isBlank(label)) {
      return false;
    }

    String lowered = label.toLowerCase();
    if (
      lowered.contains('__missing label__') ||
      lowered.contains('propertyfile - val') ||
      lowered.contains(' not found in section ')
    ) {
      return false;
    }

    return true;
  }

  private static Integer sanitizeMaxRecords(Integer maxRecords) {
    if (maxRecords == null || maxRecords <= 0) {
      return DEFAULT_MAX_RECORDS;
    }
    return Math.min(maxRecords, MAX_RECORDS_HARD_LIMIT);
  }

  private static Integer sanitizeThreshold(Integer threshold) {
    if (threshold == null || threshold < 0) {
      return DEFAULT_THRESHOLD;
    }
    if (threshold > 100) {
      return 100;
    }
    return threshold;
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

  private class ObjectOptionSorter implements Comparator<ObjectOption> {
    public Integer compare(ObjectOption a, ObjectOption b) {
      String left = a == null || a.objectLabel == null ? '' : a.objectLabel.toLowerCase();
      String right = b == null || b.objectLabel == null ? '' : b.objectLabel.toLowerCase();
      return left.compareTo(right);
    }
  }
}
