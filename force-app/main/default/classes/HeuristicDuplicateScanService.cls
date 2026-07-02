public with sharing class HeuristicDuplicateScanService {
  public static final Integer DEFAULT_MAX_RECORDS = 50000;
  public static final Integer MAX_RECORDS_HARD_LIMIT = 400000;
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
    @AuraEnabled public String asyncClassName;
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
    @AuraEnabled public Id groupId;
    @AuraEnabled public String groupKey;
    @AuraEnabled public String objectApiName;
    @AuraEnabled public Integer recordCount;
    @AuraEnabled public Integer topScore;
    @AuraEnabled public String summary;
    @AuraEnabled public List<GroupRecord> records;
  }

  public class GroupDetailRecord {
    @AuraEnabled public String recordId;
    @AuraEnabled public String displayValue;
    @AuraEnabled public Integer score;
    @AuraEnabled public String reason;
    @AuraEnabled public Map<String, String> fields;
  }

  public class GroupDetail {
    @AuraEnabled public Id groupId;
    @AuraEnabled public String groupKey;
    @AuraEnabled public String objectApiName;
    @AuraEnabled public String objectLabel;
    @AuraEnabled public String summary;
    @AuraEnabled public List<String> fieldNames;
    @AuraEnabled public List<GroupDetailRecord> records;
  }

  public class MergedRecordHistory {
    @AuraEnabled public String sourceRecordId;
    @AuraEnabled public String sourceDisplay;
    @AuraEnabled public String mergedIntoRecordId;
    @AuraEnabled public String softMergeStatus;
  }

  public class MergedGroupHistory {
    @AuraEnabled public Id mergeRunId;
    @AuraEnabled public Id scanId;
    @AuraEnabled public Id groupId;
    @AuraEnabled public String groupKey;
    @AuraEnabled public String objectApiName;
    @AuraEnabled public String status;
    @AuraEnabled public String summary;
    @AuraEnabled public String warnings;
    @AuraEnabled public String survivorRecordId;
    @AuraEnabled public String survivorDisplayValue;
    @AuraEnabled public Datetime createdDate;
    @AuraEnabled public Integer updatedFieldCount;
    @AuraEnabled public Integer reparentedRecordCount;
    @AuraEnabled public Integer mergedRecordCount;
    @AuraEnabled public List<MergedRecordHistory> mergedRecords;
  }

  public class ActionResult {
    @AuraEnabled public Boolean success;
    @AuraEnabled public String message;
    @AuraEnabled public Integer processedCount;
    @AuraEnabled public List<String> errors;
  }

  private class QueryResultContext {
    public Map<Id, SObject> recordsById = new Map<Id, SObject>();
    public List<String> queriedFieldNames = new List<String>();
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
      SELECT Id, Group_Key__c, Object_Api_Name__c, Record_Count__c, Top_Score__c, Summary__c
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
      dto.groupId = source.Id;
      dto.groupKey = source.Group_Key__c;
      dto.objectApiName = source.Object_Api_Name__c;
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

    Set<Id> memberRecordIds = new Set<Id>();
    for (Heuristic_Duplicate_Member__c member : members) {
      Id parsed = parseRecordId(member.Record_Id__c);
      if (parsed != null) {
        memberRecordIds.add(parsed);
      }
    }
    Set<Id> softMergedIds = DuplicateMergeService.getSoftMergedRecordIds(groups[0].Object_Api_Name__c, memberRecordIds);

    for (Heuristic_Duplicate_Member__c member : members) {
      if (!byGroupId.containsKey(member.Group__c)) {
        continue;
      }
      Id parsed = parseRecordId(member.Record_Id__c);
      if (parsed != null && softMergedIds.contains(parsed)) {
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
      DuplicateGroup dto = byGroupId.get(source.Id);
      dto.recordCount = dto.records.size();
      if (dto.records.size() >= 2) {
        response.add(dto);
      }
    }

    return response;
  }

  public static List<MergedGroupHistory> getMergedGroupsForScan(Id scanId, Integer maxRows) {
    if (scanId == null) {
      throw new AuraHandledException('scanId is required.');
    }

    Integer rowLimit = maxRows == null || maxRows <= 0 ? 20 : Math.min(maxRows, 50);

    List<Duplicate_Merge_Run__c> mergeRuns = [
      SELECT
        Id,
        Scan__c,
        Group__c,
        Group_Key__c,
        Object_Api_Name__c,
        Status__c,
        Summary__c,
        Warnings__c,
        Survivor_Record_Id__c,
        Survivor_Display__c,
        CreatedDate,
        Updated_Field_Count__c,
        Reparented_Record_Count__c,
        Merged_Record_Count__c
      FROM Duplicate_Merge_Run__c
      WHERE Scan__c = :scanId
      ORDER BY CreatedDate DESC
      LIMIT :rowLimit
    ];

    if (mergeRuns.isEmpty()) {
      return new List<MergedGroupHistory>();
    }

    Map<Id, MergedGroupHistory> historyByRunId = new Map<Id, MergedGroupHistory>();
    Set<Id> runIds = new Set<Id>();
    for (Duplicate_Merge_Run__c run : mergeRuns) {
      runIds.add(run.Id);

      MergedGroupHistory row = new MergedGroupHistory();
      row.mergeRunId = run.Id;
      row.scanId = run.Scan__c;
      row.groupId = run.Group__c;
      row.groupKey = run.Group_Key__c;
      row.objectApiName = run.Object_Api_Name__c;
      row.status = run.Status__c;
      row.summary = run.Summary__c;
      row.warnings = run.Warnings__c;
      row.survivorRecordId = run.Survivor_Record_Id__c;
      row.survivorDisplayValue = run.Survivor_Display__c;
      row.createdDate = run.CreatedDate;
      row.updatedFieldCount = toInteger(run.Updated_Field_Count__c);
      row.reparentedRecordCount = toInteger(run.Reparented_Record_Count__c);
      row.mergedRecordCount = toInteger(run.Merged_Record_Count__c);
      row.mergedRecords = new List<MergedRecordHistory>();
      historyByRunId.put(run.Id, row);
    }

    for (Duplicate_Merge_Record__c recordRow : [
      SELECT Merge_Run__c, Source_Record_Id__c, Source_Display__c, Merged_Into_Record_Id__c, Soft_Merge_Status__c
      FROM Duplicate_Merge_Record__c
      WHERE Merge_Run__c IN :runIds
      ORDER BY CreatedDate DESC
      LIMIT 5000
    ]) {
      if (!historyByRunId.containsKey(recordRow.Merge_Run__c)) {
        continue;
      }

      MergedRecordHistory mergedRecord = new MergedRecordHistory();
      mergedRecord.sourceRecordId = recordRow.Source_Record_Id__c;
      mergedRecord.sourceDisplay = recordRow.Source_Display__c;
      mergedRecord.mergedIntoRecordId = recordRow.Merged_Into_Record_Id__c;
      mergedRecord.softMergeStatus = recordRow.Soft_Merge_Status__c;
      historyByRunId.get(recordRow.Merge_Run__c).mergedRecords.add(mergedRecord);
    }

    List<MergedGroupHistory> response = new List<MergedGroupHistory>();
    for (Duplicate_Merge_Run__c run : mergeRuns) {
      response.add(historyByRunId.get(run.Id));
    }
    return response;
  }

  public static GroupDetail getGroupDetail(Id groupId) {
    if (groupId == null) {
      throw new AuraHandledException('groupId is required.');
    }

    List<Heuristic_Duplicate_Group__c> groups = [
      SELECT Id, Group_Key__c, Object_Api_Name__c, Summary__c, Scan__r.Object_Label__c
      FROM Heuristic_Duplicate_Group__c
      WHERE Id = :groupId
      LIMIT 1
    ];
    if (groups.isEmpty()) {
      throw new AuraHandledException('Group not found: ' + String.valueOf(groupId));
    }

    Heuristic_Duplicate_Group__c groupRow = groups[0];
    String objectApiName = groupRow.Object_Api_Name__c;
    if (String.isBlank(objectApiName) || !Schema.getGlobalDescribe().containsKey(objectApiName)) {
      throw new AuraHandledException('Group has unknown object API name: ' + objectApiName);
    }

    List<Heuristic_Duplicate_Member__c> members = [
      SELECT Record_Id__c, Display_Value__c, Score__c, Reason__c
      FROM Heuristic_Duplicate_Member__c
      WHERE Group__c = :groupId
      ORDER BY Score__c DESC, Display_Value__c ASC
      LIMIT 5000
    ];

    Set<Id> recordIds = new Set<Id>();
    for (Heuristic_Duplicate_Member__c member : members) {
      Id parsed = parseRecordId(member.Record_Id__c);
      if (parsed != null) {
        recordIds.add(parsed);
      }
    }

    Set<Id> softMergedIds = DuplicateMergeService.getSoftMergedRecordIds(objectApiName, recordIds);
    recordIds.removeAll(softMergedIds);

    QueryResultContext queryContext = queryAllFieldsForRecords(objectApiName, recordIds);
    List<String> allFieldNames = queryContext.queriedFieldNames;
    Set<String> queriedFieldSet = new Set<String>();
    for (String fieldName : allFieldNames) {
      queriedFieldSet.add(fieldName.toLowerCase());
    }

    GroupDetail detail = new GroupDetail();
    detail.groupId = groupRow.Id;
    detail.groupKey = groupRow.Group_Key__c;
    detail.objectApiName = objectApiName;
    detail.objectLabel = groupRow.Scan__r == null ? objectApiName : groupRow.Scan__r.Object_Label__c;
    detail.summary = groupRow.Summary__c;
    detail.fieldNames = allFieldNames;
    detail.records = new List<GroupDetailRecord>();

    for (Heuristic_Duplicate_Member__c member : members) {
      Id parsed = parseRecordId(member.Record_Id__c);
      if (parsed != null && softMergedIds.contains(parsed)) {
        continue;
      }
      SObject row = parsed == null ? null : queryContext.recordsById.get(parsed);
      Map<String, String> flatFields = row == null ? new Map<String, String>() : flattenFields(row, allFieldNames);

      GroupDetailRecord detailRow = new GroupDetailRecord();
      detailRow.recordId = member.Record_Id__c;
      detailRow.displayValue = !String.isBlank(member.Display_Value__c)
        ? member.Display_Value__c
        : deriveDisplayValue(row, queriedFieldSet, member.Record_Id__c);
      detailRow.score = toInteger(member.Score__c);
      detailRow.reason = member.Reason__c;
      detailRow.fields = flatFields;
      detail.records.add(detailRow);
    }

    return detail;
  }

  public static ActionResult mergeRecords(String objectApiName, Id parentRecordId, List<Id> childRecordIds) {
    ActionResult result = new ActionResult();
    result.success = false;
    result.processedCount = 0;
    result.errors = new List<String>();

    if (String.isBlank(objectApiName) || parentRecordId == null || childRecordIds == null || childRecordIds.isEmpty()) {
      result.message = 'Object, parent record, and at least one child record are required.';
      result.errors.add(result.message);
      return result;
    }

    List<String> recordIds = new List<String>{ String.valueOf(parentRecordId) };
    List<String> loserRecordIds = new List<String>();
    for (Id childRecordId : childRecordIds) {
      if (childRecordId == null || childRecordId == parentRecordId) {
        continue;
      }
      String child = String.valueOf(childRecordId);
      recordIds.add(child);
      loserRecordIds.add(child);
    }

    if (loserRecordIds.isEmpty()) {
      result.message = 'At least one child record different from the parent is required.';
      result.errors.add(result.message);
      return result;
    }

    DuplicateMergeService.MergeProposal proposal = DuplicateMergeService.getMergeProposal(
      objectApiName,
      recordIds,
      String.valueOf(parentRecordId)
    );

    DuplicateMergeService.MergeExecutionRequest request = new DuplicateMergeService.MergeExecutionRequest();
    request.objectApiName = objectApiName;
    request.survivorRecordId = String.valueOf(parentRecordId);
    request.loserRecordIds = loserRecordIds;
    request.fieldSelections = new List<DuplicateMergeService.FieldSelectionInput>();
    for (DuplicateMergeService.FieldProposal fieldProposal : proposal.fields) {
      DuplicateMergeService.FieldSelectionInput selection = new DuplicateMergeService.FieldSelectionInput();
      selection.fieldApiName = fieldProposal.fieldApiName;
      selection.sourceRecordId = fieldProposal.recommendedSourceRecordId;
      request.fieldSelections.add(selection);
    }

    DuplicateMergeService.MergeExecutionResult execution = DuplicateMergeService.executeMerge(request);
    result.success = execution.success;
    result.message = execution.message;
    result.processedCount = execution.softMergedCount;
    result.errors = execution.errors;
    return result;
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
      Database.executeBatch(new HeuristicDuplicateCandidateCleanupBatch(scan.Id), 2000);

      result.success = true;
      result.message = 'Scan cancelled. Temporary candidate cleanup queued.';
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
      dto.asyncClassName = job.ApexClass == null ? null : job.ApexClass.Name;
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
        SELECT Id, Status, JobItemsProcessed, TotalJobItems, ApexClass.Name
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

    String apiName = d.getName();
    if (apiName != null && (apiName.startsWith('Heuristic_Duplicate_') || apiName.startsWith('Duplicate_Merge_'))) {
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

  private static QueryResultContext queryAllFieldsForRecords(String objectApiName, Set<Id> ids) {
    QueryResultContext result = new QueryResultContext();
    if (ids == null || ids.isEmpty()) {
      return result;
    }

    Map<String, Schema.SObjectField> fieldMap = Schema.getGlobalDescribe().get(objectApiName).getDescribe().fields.getMap();
    List<String> allQueryableFields = buildAllQueryableFieldList(fieldMap);
    allQueryableFields = dedupeFieldNamesCaseInsensitive(allQueryableFields);

    try {
      result.recordsById =
        new Map<Id, SObject>(Database.query('SELECT FIELDS(ALL) FROM ' + objectApiName + ' WHERE Id IN :ids'));
      result.queriedFieldNames = allQueryableFields;
      return result;
    } catch (Exception ignored) {
      try {
        String allFieldSoql = 'SELECT ' + String.join(allQueryableFields, ',') + ' FROM ' + objectApiName + ' WHERE Id IN :ids';
        result.recordsById = new Map<Id, SObject>(Database.query(allFieldSoql));
        result.queriedFieldNames = allQueryableFields;
        return result;
      } catch (Exception secondFailure) {
        List<String> fields = buildFallbackFieldList(fieldMap);
        fields = dedupeFieldNamesCaseInsensitive(fields);
        try {
          String fallbackSoql = 'SELECT ' + String.join(fields, ',') + ' FROM ' + objectApiName + ' WHERE Id IN :ids';
          result.recordsById = new Map<Id, SObject>(Database.query(fallbackSoql));
          result.queriedFieldNames = fields;
          return result;
        } catch (Exception thirdFailure) {
          result.recordsById = new Map<Id, SObject>(Database.query('SELECT Id FROM ' + objectApiName + ' WHERE Id IN :ids'));
          result.queriedFieldNames = new List<String>{ 'Id' };
          return result;
        }
      }
    }
  }

  private static List<String> buildAllQueryableFieldList(Map<String, Schema.SObjectField> fieldMap) {
    List<String> fields = new List<String>();
    Set<String> selectedCanonical = new Set<String>();

    addFieldIfQueryable('Id', fieldMap, selectedCanonical, fields);

    List<String> sortedAllFields = new List<String>(fieldMap.keySet());
    sortedAllFields.sort();
    for (String fieldName : sortedAllFields) {
      addFieldIfQueryable(fieldName, fieldMap, selectedCanonical, fields);
    }

    return fields;
  }

  private static List<String> buildFallbackFieldList(Map<String, Schema.SObjectField> fieldMap) {
    List<String> fields = new List<String>();
    Set<String> selectedCanonical = new Set<String>();

    for (String preferred : new List<String>{ 'Id', 'Name', 'Subject', 'CreatedDate', 'LastModifiedDate' }) {
      addFieldIfQueryable(preferred, fieldMap, selectedCanonical, fields);
    }

    List<String> sortedAllFields = new List<String>(fieldMap.keySet());
    sortedAllFields.sort();
    for (String fieldName : sortedAllFields) {
      if (fields.size() >= 120) {
        break;
      }
      addFieldIfQueryable(fieldName, fieldMap, selectedCanonical, fields);
    }

    if (!selectedCanonical.contains('id') && fieldMap.containsKey('Id')) {
      fields.add('Id');
    }
    return fields;
  }

  private static void addFieldIfQueryable(
    String fieldName,
    Map<String, Schema.SObjectField> fieldMap,
    Set<String> selectedCanonical,
    List<String> output
  ) {
    if (String.isBlank(fieldName) || !fieldMap.containsKey(fieldName)) {
      return;
    }
    String canonical = fieldName.toLowerCase();
    if (selectedCanonical.contains(canonical)) {
      return;
    }

    Schema.DescribeFieldResult d = fieldMap.get(fieldName).getDescribe();
    if (!d.isAccessible() || d.getType() == Schema.DisplayType.Base64) {
      return;
    }

    selectedCanonical.add(canonical);
    output.add(fieldName);
  }

  private static List<String> dedupeFieldNamesCaseInsensitive(List<String> fieldNames) {
    List<String> out = new List<String>();
    Set<String> canonical = new Set<String>();
    for (String fieldName : fieldNames) {
      if (String.isBlank(fieldName)) {
        continue;
      }
      String key = fieldName.toLowerCase();
      if (canonical.contains(key)) {
        continue;
      }
      canonical.add(key);
      out.add(fieldName);
    }
    if (!canonical.contains('id')) {
      out.add(0, 'Id');
    }
    return out;
  }

  private static Map<String, String> flattenFields(SObject row, List<String> allFieldNames) {
    Map<String, String> out = new Map<String, String>();
    for (String fieldName : allFieldNames) {
      Object value = safeGetField(row, fieldName);
      out.put(fieldName, formatValue(value));
    }
    return out;
  }

  private static String deriveDisplayValue(SObject row, Set<String> queriedFieldSet, String fallbackId) {
    if (row == null) {
      return fallbackId;
    }
    Object nameValue = queriedFieldSet.contains('name') ? safeGetField(row, 'Name') : null;
    if (nameValue != null) {
      return String.valueOf(nameValue);
    }
    Object subjectValue = queriedFieldSet.contains('subject') ? safeGetField(row, 'Subject') : null;
    if (subjectValue != null) {
      return String.valueOf(subjectValue);
    }
    return String.isBlank(fallbackId) ? String.valueOf(row.get('Id')) : fallbackId;
  }

  private static Object safeGetField(SObject row, String fieldName) {
    if (row == null) {
      return null;
    }
    try {
      return row.get(fieldName);
    } catch (Exception ignored) {
      return null;
    }
  }

  private static String formatValue(Object value) {
    if (value == null) {
      return '';
    }
    if (value instanceof Date) {
      return ((Date) value).format();
    }
    if (value instanceof Datetime) {
      return ((Datetime) value).format('yyyy-MM-dd HH:mm');
    }
    return String.valueOf(value);
  }

  private static Id parseRecordId(String value) {
    if (String.isBlank(value)) {
      return null;
    }
    try {
      return (Id) value;
    } catch (Exception ignored) {
      return null;
    }
  }

  private class ObjectOptionSorter implements Comparator<ObjectOption> {
    public Integer compare(ObjectOption a, ObjectOption b) {
      String left = a == null || a.objectLabel == null ? '' : a.objectLabel.toLowerCase();
      String right = b == null || b.objectLabel == null ? '' : b.objectLabel.toLowerCase();
      return left.compareTo(right);
    }
  }
}
