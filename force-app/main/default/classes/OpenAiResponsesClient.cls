public with sharing class OpenAiResponsesClient {
  // Transport mode: true = Named Credential, false = endpoint and API key from Custom Labels.
  private static final Boolean USE_NAMED_CREDENTIAL = false;

  private static final String NAMED_CREDENTIAL = 'OpenAI';
  private static final String NAMED_CREDENTIAL_ENDPOINT = 'callout:' + NAMED_CREDENTIAL + '/v1/responses';
  private static final String MODEL = 'gpt-4.1-mini';
  private static final Integer MAX_ERROR_BODY_LEN = 450;

  @TestVisible private static String endpointOverrideForTest;
  @TestVisible private static String apiKeyOverrideForTest;

  public class OpenAiClientException extends Exception {}

  public class SetDecision {
    public String parentRecordId;
    public String summary;
    public List<RecordDecision> records = new List<RecordDecision>();
  }

  public class RecordDecision {
    public String recordId;
    public Integer matchScore;
    public Integer qualityScore;
    public String reason;
    public String recommendedAction;
  }

  public static SetDecision analyzeSet(String objectApiName, String setName, List<Map<String, String>> records) {
    if (records == null || records.isEmpty()) {
      throw new OpenAiClientException('No records provided for AI analysis.');
    }

    HttpRequest req = new HttpRequest();
    configureTransport(req);
    req.setMethod('POST');
    req.setHeader('Content-Type', 'application/json');
    req.setTimeout(120000);

    Map<String, Object> payload = new Map<String, Object>();
    payload.put('model', MODEL);
    payload.put('temperature', 0);

    String instruction =
      'You are a deterministic Salesforce duplicate resolution assistant. ' +
      'Decide one canonical parent record for merge, rank all records by closeness to parent, ' +
      'and return strict JSON only. Criteria for parent priority: highest data completeness, ' +
      'most trustworthy contact/business fields, then most recently modified/active profile, ' +
      'then stable tie-breaker by lexicographically smallest Salesforce Id.';
    payload.put('instructions', instruction);

    Map<String, Object> requestInput = new Map<String, Object>();
    requestInput.put('objectApiName', objectApiName);
    requestInput.put('duplicateSetName', setName);
    requestInput.put('records', records);
    String schemaInstruction =
      'Return JSON with shape: {"parentRecordId":"<Id>","summary":"<string>",' +
      '"records":[{"recordId":"<Id>","matchScore":0-100,"qualityScore":0-100,' +
      '"reason":"<short>","recommendedAction":"KEEP|MERGE|DELETE|REVIEW"}]}';
    payload.put('input', schemaInstruction + '\\n\\n' + JSON.serialize(requestInput));
    req.setBody(JSON.serialize(payload));

    HttpResponse res = new Http().send(req);

    if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
      throw new OpenAiClientException(
        'OpenAI callout failed: ' + res.getStatusCode() + ' ' + truncateForError(res.getBody())
      );
    }

    Map<String, Object> response;
    try {
      response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    } catch (Exception ex) {
      throw new OpenAiClientException(
        'OpenAI response was not valid JSON. Body sample: ' + truncateForError(res.getBody())
      );
    }

    String outputText = extractOutputText(response);
    if (String.isBlank(outputText)) {
      throw new OpenAiClientException('OpenAI response did not contain output_text.');
    }

    Map<String, Object> decisionRaw;
    try {
      decisionRaw = (Map<String, Object>) JSON.deserializeUntyped(outputText);
    } catch (Exception ex) {
      throw new OpenAiClientException(
        'OpenAI output_text was not valid decision JSON. output_text sample: ' + truncateForError(outputText)
      );
    }
    return mapDecision(decisionRaw);
  }

  private static void configureTransport(HttpRequest req) {
    if (USE_NAMED_CREDENTIAL) {
      req.setEndpoint(NAMED_CREDENTIAL_ENDPOINT);
      return;
    }

    String hardcodedEndpoint = String.isBlank(endpointOverrideForTest)
      ? Label.OpenAI_Hardcoded_Endpoint
      : endpointOverrideForTest;
    String hardcodedApiKey = String.isBlank(apiKeyOverrideForTest)
      ? Label.OpenAI_Hardcoded_API_Key
      : apiKeyOverrideForTest;

    if (String.isBlank(hardcodedEndpoint) || String.isBlank(hardcodedApiKey) || hardcodedApiKey == 'REPLACE_ME') {
      throw new OpenAiClientException(
        'Hardcoded OpenAI mode is enabled but endpoint/key is missing. ' +
        'Set Custom Labels OpenAI_Hardcoded_Endpoint and OpenAI_Hardcoded_API_Key.'
      );
    }

    req.setEndpoint(hardcodedEndpoint);
    req.setHeader('Authorization', 'Bearer ' + hardcodedApiKey);
  }

  private static SetDecision mapDecision(Map<String, Object> raw) {
    SetDecision out = new SetDecision();
    out.parentRecordId = (String) raw.get('parentRecordId');
    out.summary = (String) raw.get('summary');

    List<Object> rows = (List<Object>) raw.get('records');
    if (rows != null) {
      for (Object item : rows) {
        Map<String, Object> row = (Map<String, Object>) item;
        RecordDecision rec = new RecordDecision();
        rec.recordId = (String) row.get('recordId');
        rec.matchScore = toInteger(row.get('matchScore'));
        rec.qualityScore = toInteger(row.get('qualityScore'));
        rec.reason = (String) row.get('reason');
        rec.recommendedAction = (String) row.get('recommendedAction');
        out.records.add(rec);
      }
    }

    return out;
  }

  private static Integer toInteger(Object v) {
    if (v == null) {
      return 0;
    }
    if (v instanceof Integer) {
      return (Integer) v;
    }
    if (v instanceof Decimal) {
      return ((Decimal) v).intValue();
    }
    return Integer.valueOf(String.valueOf(v));
  }

  private static String extractOutputText(Map<String, Object> response) {
    if (response.containsKey('output_text') && response.get('output_text') != null) {
      return String.valueOf(response.get('output_text'));
    }

    if (!response.containsKey('output')) {
      return null;
    }

    List<Object> output = (List<Object>) response.get('output');
    for (Object chunkObj : output) {
      Map<String, Object> chunk = (Map<String, Object>) chunkObj;
      if (!chunk.containsKey('content')) {
        continue;
      }
      List<Object> contents = (List<Object>) chunk.get('content');
      for (Object contentObj : contents) {
        Map<String, Object> content = (Map<String, Object>) contentObj;
        if ('output_text' == String.valueOf(content.get('type')) && content.get('text') != null) {
          return String.valueOf(content.get('text'));
        }
      }
    }

    return null;
  }

  private static String truncateForError(String input) {
    if (String.isBlank(input)) {
      return '';
    }
    return input.length() > MAX_ERROR_BODY_LEN ? input.substring(0, MAX_ERROR_BODY_LEN) + '...' : input;
  }
}
