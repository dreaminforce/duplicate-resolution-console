public with sharing class DuplicateAiService {
  private static final Integer DEFAULT_SET_LIMIT = 10;

  public class ObjectOption {
    @AuraEnabled public String objectApiName;
    @AuraEnabled public String objectLabel;
    @AuraEnabled public Integer duplicateItemCount;
    @AuraEnabled public Integer duplicateSetCount;
  }

  public class AnalysisResponse {
    @AuraEnabled public String objectApiName;
    @AuraEnabled public String objectLabel;
    @AuraEnabled public Integer totalItems;
    @AuraEnabled public Integer totalSets;
    @AuraEnabled public List<DuplicateSetAnalysis> sets;
    @AuraEnabled public List<String> warnings;
  }

  public class DuplicateSetAnalysis {
    @AuraEnabled public Id duplicateRecordSetId;
    @AuraEnabled public String duplicateRecordSetName;
    @AuraEnabled public Datetime createdDate;
    @AuraEnabled public String summary;
    @AuraEnabled public String parentRecordId;
    @AuraEnabled public String parentDisplay;
    @AuraEnabled public Boolean canMerge;
    @AuraEnabled public List<String> fieldNames;
    @AuraEnabled public List<RecordAnalysis> records;
  }

  public class RecordAnalysis {
    @AuraEnabled public String recordId;
    @AuraEnabled public String displayValue;
    @AuraEnabled public Boolean isParent;
    @AuraEnabled public Integer rank;
    @AuraEnabled public Integer matchScore;
    @AuraEnabled public Integer qualityScore;
    @AuraEnabled public String reason;
    @AuraEnabled public String recommendedAction;
    @AuraEnabled public Map<String, String> fields;
  }

  public class ActionResult {
    @AuraEnabled public Boolean success;
    @AuraEnabled public String message;
    @AuraEnabled public Integer processedCount;
    @AuraEnabled public List<String> errors;
  }

  private class SetContext {
    public Id setId;
    public String setName;
    public Datetime createdDate;
    public List<Id> recordIds = new List<Id>();
  }

  private class QueryResultContext {
    public Map<Id, SObject> recordsById = new Map<Id, SObject>();
    public List<String> queriedFieldNames = new List<String>();
  }

  public static List<ObjectOption> getObjectOptions() {
    Map<String, ObjectOption> byObject = new Map<String, ObjectOption>();
    Map<String, Set<Id>> setsByObject = new Map<String, Set<Id>>();

    for (DuplicateRecordItem item : [
      SELECT RecordId, DuplicateRecordSetId
      FROM DuplicateRecordItem
      WHERE RecordId != null
      ORDER BY CreatedDate DESC
      LIMIT 5000
    ]) {
      String objectApiName = item.RecordId.getSObjectType().getDescribe().getName();
      if (!byObject.containsKey(objectApiName)) {
        ObjectOption opt = new ObjectOption();
        opt.objectApiName = objectApiName;
        opt.objectLabel = item.RecordId.getSObjectType().getDescribe().getLabel();
        opt.duplicateItemCount = 0;
        opt.duplicateSetCount = 0;
        byObject.put(objectApiName, opt);
        setsByObject.put(objectApiName, new Set<Id>());
      }

      byObject.get(objectApiName).duplicateItemCount++;
      setsByObject.get(objectApiName).add(item.DuplicateRecordSetId);
    }

    List<ObjectOption> options = byObject.values();
    for (ObjectOption opt : options) {
      opt.duplicateSetCount = setsByObject.get(opt.objectApiName).size();
    }

    options.sort(new ObjectOptionSorter());
    return options;
  }

  public static AnalysisResponse analyzeObject(String objectApiName, Integer maxSets, Boolean runAi) {
    validateObjectApiName(objectApiName);
    Boolean shouldRunAi = runAi == true;

    Integer targetSetLimit = maxSets == null || maxSets <= 0 ? DEFAULT_SET_LIMIT : Math.min(maxSets, 25);
    List<DuplicateRecordItem> duplicateItems = [
      SELECT DuplicateRecordSetId, RecordId
      FROM DuplicateRecordItem
      ORDER BY CreatedDate DESC
      LIMIT 5000
    ];

    Set<Id> candidateRecordIds = new Set<Id>();
    for (DuplicateRecordItem item : duplicateItems) {
      if (item.RecordId != null && item.RecordId.getSObjectType().getDescribe().getName() == objectApiName) {
        candidateRecordIds.add(item.RecordId);
      }
    }
    Set<Id> softMergedIds = DuplicateMergeService.getSoftMergedRecordIds(objectApiName, candidateRecordIds);

    Map<Id, SetContext> setContextsById = new Map<Id, SetContext>();
    Integer selectedItemCount = 0;
    for (DuplicateRecordItem item : duplicateItems) {
      if (
        item.RecordId == null ||
        item.RecordId.getSObjectType().getDescribe().getName() != objectApiName ||
        softMergedIds.contains(item.RecordId)
      ) {
        continue;
      }

      selectedItemCount++;
      if (!setContextsById.containsKey(item.DuplicateRecordSetId)) {
        if (setContextsById.size() >= targetSetLimit) {
          continue;
        }
        SetContext ctx = new SetContext();
        ctx.setId = item.DuplicateRecordSetId;
        setContextsById.put(item.DuplicateRecordSetId, ctx);
      }
      setContextsById.get(item.DuplicateRecordSetId).recordIds.add(item.RecordId);
    }

    pruneSmallSets(setContextsById);
    selectedItemCount = countSetItems(setContextsById.values());

    if (setContextsById.isEmpty()) {
      AnalysisResponse emptyResponse = new AnalysisResponse();
      emptyResponse.objectApiName = objectApiName;
      emptyResponse.objectLabel = Schema.getGlobalDescribe().get(objectApiName).getDescribe().getLabel();
      emptyResponse.totalItems = 0;
      emptyResponse.totalSets = 0;
      emptyResponse.sets = new List<DuplicateSetAnalysis>();
      emptyResponse.warnings = new List<String>();
      return emptyResponse;
    }

    for (DuplicateRecordSet ds : [
      SELECT Id, Name, CreatedDate
      FROM DuplicateRecordSet
      WHERE Id IN :setContextsById.keySet()
    ]) {
      SetContext ctx = setContextsById.get(ds.Id);
      ctx.setName = ds.Name;
      ctx.createdDate = ds.CreatedDate;
    }

    Set<Id> allRecordIds = new Set<Id>();
    for (SetContext ctx : setContextsById.values()) {
      allRecordIds.addAll(ctx.recordIds);
    }

    QueryResultContext queryContext = queryAllFieldsForRecords(objectApiName, allRecordIds);
    Map<Id, SObject> recordsById = queryContext.recordsById;
    List<String> allFieldNames = queryContext.queriedFieldNames;
    Set<String> queriedFieldSet = new Set<String>();
    for (String f : allFieldNames) {
      queriedFieldSet.add(f.toLowerCase());
    }

    AnalysisResponse response = new AnalysisResponse();
    response.objectApiName = objectApiName;
    response.objectLabel = Schema.getGlobalDescribe().get(objectApiName).getDescribe().getLabel();
    response.totalItems = selectedItemCount;
    response.totalSets = setContextsById.size();
    response.sets = new List<DuplicateSetAnalysis>();
    response.warnings = new List<String>();

    for (SetContext ctx : setContextsById.values()) {
      DuplicateSetAnalysis setResult = buildSetAnalysis(
        ctx,
        objectApiName,
        recordsById,
        allFieldNames,
        queriedFieldSet,
        shouldRunAi,
        response.warnings
      );
      response.sets.add(setResult);
    }

    response.sets.sort(new SetSorter());
    return response;
  }

  public static DuplicateSetAnalysis analyzeSingleSet(String objectApiName, Id duplicateRecordSetId, Boolean runAi) {
    validateObjectApiName(objectApiName);
    if (duplicateRecordSetId == null) {
      throw new AuraHandledException('duplicateRecordSetId is required.');
    }

    List<DuplicateRecordSet> setRows = [
      SELECT Id, Name, CreatedDate
      FROM DuplicateRecordSet
      WHERE Id = :duplicateRecordSetId
      LIMIT 1
    ];
    if (setRows.isEmpty()) {
      throw new AuraHandledException('Duplicate set not found: ' + String.valueOf(duplicateRecordSetId));
    }

    SetContext ctx = new SetContext();
    ctx.setId = setRows[0].Id;
    ctx.setName = setRows[0].Name;
    ctx.createdDate = setRows[0].CreatedDate;

    for (DuplicateRecordItem item : [
      SELECT RecordId
      FROM DuplicateRecordItem
      WHERE DuplicateRecordSetId = :duplicateRecordSetId AND RecordId != null
      LIMIT 5000
    ]) {
      if (item.RecordId.getSObjectType().getDescribe().getName() == objectApiName) {
        ctx.recordIds.add(item.RecordId);
      }
    }

    Set<Id> softMergedIds = DuplicateMergeService.getSoftMergedRecordIds(objectApiName, new Set<Id>(ctx.recordIds));
    List<Id> filteredRecordIds = new List<Id>();
    for (Id recordId : ctx.recordIds) {
      if (!softMergedIds.contains(recordId)) {
        filteredRecordIds.add(recordId);
      }
    }
    ctx.recordIds = filteredRecordIds;

    if (ctx.recordIds.isEmpty()) {
      throw new AuraHandledException(
        'No records in set ' + String.valueOf(duplicateRecordSetId) + ' for object ' + objectApiName + '.'
      );
    }
    if (ctx.recordIds.size() < 2) {
      throw new AuraHandledException(
        'Only one active record remains in set ' + String.valueOf(duplicateRecordSetId) + ' after excluding soft merges.'
      );
    }

    Set<Id> recordIds = new Set<Id>();
    recordIds.addAll(ctx.recordIds);

    QueryResultContext queryContext = queryAllFieldsForRecords(objectApiName, recordIds);
    Map<Id, SObject> recordsById = queryContext.recordsById;
    List<String> allFieldNames = queryContext.queriedFieldNames;
    Set<String> queriedFieldSet = new Set<String>();
    for (String f : allFieldNames) {
      queriedFieldSet.add(f.toLowerCase());
    }

    List<String> warnings = new List<String>();
    return buildSetAnalysis(
      ctx,
      objectApiName,
      recordsById,
      allFieldNames,
      queriedFieldSet,
      runAi == true,
      warnings
    );
  }

  public static ActionResult mergeRecords(String objectApiName, Id parentRecordId, List<Id> childRecordIds) {
    validateObjectApiName(objectApiName);

    ActionResult result = new ActionResult();
    result.success = true;
    result.errors = new List<String>();
    result.processedCount = 0;

    if (parentRecordId == null || childRecordIds == null || childRecordIds.isEmpty()) {
      result.success = false;
      result.message = 'Parent and at least one child record are required.';
      return result;
    }

    DuplicateMergeService.MergeProposal proposal = DuplicateMergeService.getMergeProposal(
      objectApiName,
      mergeCandidateIds(parentRecordId, childRecordIds),
      String.valueOf(parentRecordId)
    );
    DuplicateMergeService.MergeExecutionRequest request = new DuplicateMergeService.MergeExecutionRequest();
    request.objectApiName = objectApiName;
    request.survivorRecordId = String.valueOf(parentRecordId);
    request.loserRecordIds = stringifyIds(childRecordIds);
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
    result.errors.addAll(execution.errors);
    return result;
  }

  public static ActionResult deleteRecords(List<Id> recordIds) {
    ActionResult result = new ActionResult();
    result.success = true;
    result.errors = new List<String>();
    result.processedCount = 0;

    if (recordIds == null || recordIds.isEmpty()) {
      result.success = false;
      result.message = 'Select at least one record to delete.';
      return result;
    }

    List<SObject> rows = new List<SObject>();
    for (Id idValue : recordIds) {
      if (idValue == null) {
        continue;
      }
      rows.add(idValue.getSObjectType().newSObject(idValue));
    }

    Database.DeleteResult[] deleteResults = Database.delete(rows, false);
    for (Database.DeleteResult dr : deleteResults) {
      if (dr.isSuccess()) {
        result.processedCount++;
      } else {
        result.success = false;
        for (Database.Error err : dr.getErrors()) {
          result.errors.add(err.getMessage());
        }
      }
    }

    result.message =
      result.success
        ? 'Deleted ' + result.processedCount + ' record(s).'
        : 'Delete finished with errors. Deleted: ' + result.processedCount;
    return result;
  }

  private static void applyAiDecision(DuplicateSetAnalysis setResult, OpenAiResponsesClient.SetDecision aiDecision) {
    if (aiDecision == null || String.isBlank(aiDecision.parentRecordId)) {
      applyDeterministicFallback(setResult);
      return;
    }

    Map<String, RecordAnalysis> byId = new Map<String, RecordAnalysis>();
    for (RecordAnalysis row : setResult.records) {
      byId.put(row.recordId, row);
    }

    for (OpenAiResponsesClient.RecordDecision decision : aiDecision.records) {
      if (!byId.containsKey(decision.recordId)) {
        continue;
      }
      RecordAnalysis row = byId.get(decision.recordId);
      row.matchScore = clampScore(decision.matchScore);
      row.qualityScore = clampScore(decision.qualityScore);
      row.reason = String.isBlank(decision.reason) ? 'AI ranked this record.' : decision.reason;
      row.recommendedAction = String.isBlank(decision.recommendedAction) ? 'REVIEW' : decision.recommendedAction;
    }

    setResult.parentRecordId = aiDecision.parentRecordId;
    setResult.summary = String.isBlank(aiDecision.summary)
      ? 'AI selected a canonical parent and ranked duplicates.'
      : aiDecision.summary;

    rankAndFinalize(setResult);
  }

  private static void applyDeterministicFallback(DuplicateSetAnalysis setResult) {
    if (setResult.records.isEmpty()) {
      return;
    }

    RecordAnalysis parent = null;
    Integer bestScore = -1;
    for (RecordAnalysis rec : setResult.records) {
      Integer quality = rec.qualityScore;
      if (quality > bestScore || (quality == bestScore && (parent == null || rec.recordId < parent.recordId))) {
        bestScore = quality;
        parent = rec;
      }
    }

    setResult.parentRecordId = parent.recordId;
    setResult.summary =
      'Fallback mode: parent chosen by completeness and deterministic tie-breakers. AI review is recommended.';

    for (RecordAnalysis rec : setResult.records) {
      if (rec.recordId == parent.recordId) {
        rec.matchScore = 100;
        rec.recommendedAction = 'KEEP';
        rec.reason = 'Best completeness score in set.';
      } else {
        rec.matchScore = similarityScore(parent.fields, rec.fields);
        rec.recommendedAction = rec.matchScore >= 70 ? 'MERGE' : 'REVIEW';
        rec.reason = 'Deterministic similarity score against selected parent.';
      }
    }

    rankAndFinalize(setResult);
  }

  private static DuplicateSetAnalysis buildSetAnalysis(
    SetContext ctx,
    String objectApiName,
    Map<Id, SObject> recordsById,
    List<String> allFieldNames,
    Set<String> queriedFieldSet,
    Boolean shouldRunAi,
    List<String> warnings
  ) {
    List<Map<String, String>> recordPayload = new List<Map<String, String>>();
    List<RecordAnalysis> uiRecords = new List<RecordAnalysis>();

    for (Id recordId : ctx.recordIds) {
      if (!recordsById.containsKey(recordId)) {
        continue;
      }

      SObject rec = recordsById.get(recordId);
      Map<String, String> flatFields = flattenFields(rec, allFieldNames);

      Map<String, String> aiRecord = new Map<String, String>();
      aiRecord.putAll(flatFields);
      aiRecord.put('Id', String.valueOf(recordId));
      recordPayload.add(aiRecord);

      RecordAnalysis row = new RecordAnalysis();
      row.recordId = String.valueOf(recordId);
      row.displayValue = deriveDisplayValue(rec, queriedFieldSet);
      row.fields = flatFields;
      row.matchScore = shouldRunAi ? 0 : null;
      row.qualityScore = shouldRunAi ? scoreRecordQuality(flatFields) : null;
      row.reason = shouldRunAi ? 'Pending AI analysis' : '';
      row.recommendedAction = shouldRunAi ? 'REVIEW' : '';
      uiRecords.add(row);
    }

    DuplicateSetAnalysis setResult = new DuplicateSetAnalysis();
    setResult.duplicateRecordSetId = ctx.setId;
    setResult.duplicateRecordSetName = String.isBlank(ctx.setName) ? String.valueOf(ctx.setId) : ctx.setName;
    setResult.createdDate = ctx.createdDate;
    setResult.canMerge = uiRecords.size() > 1;
    setResult.fieldNames = allFieldNames;
    setResult.records = uiRecords;
    setResult.summary = shouldRunAi
      ? 'AI processing in progress for this set.'
      : 'Raw duplicate rule set view. Use Analyze All Sets (AI) for ranking and merge recommendations.';

    if (shouldRunAi) {
      try {
        OpenAiResponsesClient.SetDecision aiDecision = OpenAiResponsesClient.analyzeSet(
          objectApiName,
          setResult.duplicateRecordSetName,
          recordPayload
        );
        applyAiDecision(setResult, aiDecision);
      } catch (Exception ex) {
        applyDeterministicFallback(setResult);
        if (warnings != null) {
          warnings.add('AI analysis fallback used for set ' + setResult.duplicateRecordSetName + ': ' + describeException(ex));
        }
      }
    }

    return setResult;
  }

  private static void rankAndFinalize(DuplicateSetAnalysis setResult) {
    for (RecordAnalysis row : setResult.records) {
      row.isParent = row.recordId == setResult.parentRecordId;
      if (row.isParent) {
        setResult.parentDisplay = row.displayValue;
        row.matchScore = 100;
        row.recommendedAction = 'KEEP';
      }
    }

    setResult.records.sort(new RecordSorter(setResult.parentRecordId));
    Integer rankCounter = 1;
    for (RecordAnalysis row : setResult.records) {
      row.rank = rankCounter;
      rankCounter++;
    }
  }

  private static QueryResultContext queryAllFieldsForRecords(String objectApiName, Set<Id> ids) {
    QueryResultContext result = new QueryResultContext();
    if (ids.isEmpty()) {
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

  private static String deriveDisplayValue(SObject row, Set<String> queriedFieldSet) {
    Object nameValue = queriedFieldSet.contains('name') ? safeGetField(row, 'Name') : null;
    if (nameValue != null) {
      return String.valueOf(nameValue);
    }
    Object subjectValue = queriedFieldSet.contains('subject') ? safeGetField(row, 'Subject') : null;
    if (subjectValue != null) {
      return String.valueOf(subjectValue);
    }
    return String.valueOf(row.get('Id'));
  }

  private static Object safeGetField(SObject row, String fieldName) {
    try {
      return row.get(fieldName);
    } catch (Exception ignored) {
      return null;
    }
  }

  private static Integer scoreRecordQuality(Map<String, String> fields) {
    Integer score = 0;
    Integer nonBlank = 0;
    for (String fieldName : fields.keySet()) {
      String value = fields.get(fieldName);
      if (!String.isBlank(value)) {
        nonBlank++;
      }
    }

    score += Math.min(nonBlank, 60);

    for (String prioritized : new List<String>{
      'Name',
      'FirstName',
      'LastName',
      'Email',
      'Phone',
      'MobilePhone',
      'Company',
      'Website',
      'BillingStreet',
      'ShippingStreet'
    }) {
      if (!String.isBlank(fields.get(prioritized))) {
        score += 4;
      }
    }

    return clampScore(score);
  }

  private static Integer similarityScore(Map<String, String> parentFields, Map<String, String> childFields) {
    List<String> keys = new List<String>{
      'Name',
      'FirstName',
      'LastName',
      'Email',
      'Phone',
      'MobilePhone',
      'Company',
      'Website',
      'BillingStreet',
      'ShippingStreet',
      'City',
      'PostalCode'
    };

    Integer matched = 0;
    Integer compared = 0;
    for (String key : keys) {
      String p = normalize(parentFields.get(key));
      String c = normalize(childFields.get(key));
      if (String.isBlank(p) || String.isBlank(c)) {
        continue;
      }
      compared++;
      if (p == c) {
        matched++;
      }
    }

    if (compared == 0) {
      return 50;
    }
    return clampScore((Integer) Math.round(((Decimal) matched / compared) * 100));
  }

  private static Integer clampScore(Integer raw) {
    if (raw == null) {
      return 0;
    }
    if (raw < 0) {
      return 0;
    }
    if (raw > 100) {
      return 100;
    }
    return raw;
  }

  private static String normalize(String v) {
    if (v == null) {
      return '';
    }
    return v.replaceAll('[^a-zA-Z0-9]', '').toLowerCase();
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

  private static String describeException(Exception ex) {
    if (ex == null) {
      return 'Unknown error.';
    }

    String msg = ex.getMessage();
    if (String.isBlank(msg) || msg == 'Script-thrown exception') {
      msg = ex.getTypeName();
    }

    if (ex.getCause() != null && !String.isBlank(ex.getCause().getMessage())) {
      msg += ' | Cause: ' + ex.getCause().getMessage();
    }
    return msg;
  }

  private static void validateObjectApiName(String objectApiName) {
    if (String.isBlank(objectApiName) || !Schema.getGlobalDescribe().containsKey(objectApiName)) {
      throw new AuraHandledException('Unknown object: ' + objectApiName);
    }
  }

  private static void pruneSmallSets(Map<Id, SetContext> setContextsById) {
    List<Id> toRemove = new List<Id>();
    for (Id setId : setContextsById.keySet()) {
      if (setContextsById.get(setId).recordIds.size() < 2) {
        toRemove.add(setId);
      }
    }
    for (Id setId : toRemove) {
      setContextsById.remove(setId);
    }
  }

  private static Integer countSetItems(List<SetContext> contexts) {
    Integer total = 0;
    for (SetContext ctx : contexts) {
      total += ctx.recordIds.size();
    }
    return total;
  }

  private static List<String> mergeCandidateIds(Id parentRecordId, List<Id> childRecordIds) {
    List<String> ids = new List<String>();
    if (parentRecordId != null) {
      ids.add(String.valueOf(parentRecordId));
    }
    ids.addAll(stringifyIds(childRecordIds));
    return ids;
  }

  private static List<String> stringifyIds(List<Id> ids) {
    List<String> out = new List<String>();
    if (ids == null) {
      return out;
    }
    for (Id idValue : ids) {
      if (idValue != null) {
        out.add(String.valueOf(idValue));
      }
    }
    return out;
  }

  private class ObjectOptionSorter implements Comparator<ObjectOption> {
    public Integer compare(ObjectOption a, ObjectOption b) {
      return a.objectLabel.toLowerCase().compareTo(b.objectLabel.toLowerCase());
    }
  }

  private class SetSorter implements Comparator<DuplicateSetAnalysis> {
    public Integer compare(DuplicateSetAnalysis a, DuplicateSetAnalysis b) {
      if (a.createdDate == b.createdDate) {
        return String.valueOf(a.duplicateRecordSetId).compareTo(String.valueOf(b.duplicateRecordSetId));
      }
      return a.createdDate > b.createdDate ? -1 : 1;
    }
  }

  private class RecordSorter implements Comparator<RecordAnalysis> {
    private String parentId;

    public RecordSorter(String parentId) {
      this.parentId = parentId;
    }

    public Integer compare(RecordAnalysis a, RecordAnalysis b) {
      if (a.recordId == parentId) {
        return -1;
      }
      if (b.recordId == parentId) {
        return 1;
      }
      if (a.matchScore != b.matchScore) {
        return a.matchScore > b.matchScore ? -1 : 1;
      }
      if (a.qualityScore != b.qualityScore) {
        return a.qualityScore > b.qualityScore ? -1 : 1;
      }
      return a.recordId.compareTo(b.recordId);
    }
  }
}
