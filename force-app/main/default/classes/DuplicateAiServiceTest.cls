@IsTest
private class DuplicateAiServiceTest {
  private class OpenAiMock implements HttpCalloutMock {
    private Integer statusCode;
    private String body;

    OpenAiMock(Integer statusCode, String body) {
      this.statusCode = statusCode;
      this.body = body;
    }

    public HttpResponse respond(HttpRequest req) {
      System.assertEquals('POST', req.getMethod());
      System.assertEquals('application/json', req.getHeader('Content-Type'));
      System.assertEquals('Bearer test-key', req.getHeader('Authorization'));
      System.assert(req.getBody().contains('duplicateSetName'));

      HttpResponse res = new HttpResponse();
      res.setStatusCode(statusCode);
      res.setBody(body);
      return res;
    }
  }

  @IsTest
  static void analyzeObject_loadsDuplicateSetsAndBuildsMergeProposal() {
    Account parent = new Account(Name = 'AI Parent Account', Phone = null, BillingCity = 'New York');
    Account child = new Account(Name = 'AI Child Account', Phone = '2125550101', BillingCity = 'New York');
    insert new List<Account>{ parent, child };

    DuplicateRecordSet setRow = createDuplicateRecordSet(new List<Id>{ parent.Id, child.Id });

    List<DuplicateAiService.ObjectOption> options = DuplicateAiController.getObjectOptions();
    Boolean foundAccount = false;
    for (DuplicateAiService.ObjectOption option : options) {
      if (option.objectApiName == 'Account') {
        foundAccount = true;
        System.assertEquals(2, option.duplicateItemCount);
        System.assertEquals(1, option.duplicateSetCount);
      }
    }
    System.assertEquals(true, foundAccount);

    DuplicateAiService.AnalysisResponse response = DuplicateAiController.analyzeObject('Account', 10, false);
    System.assertEquals('Account', response.objectApiName);
    System.assertEquals(2, response.totalItems);
    System.assertEquals(1, response.totalSets);
    System.assertEquals(1, response.sets.size());
    System.assertEquals(setRow.Id, response.sets[0].duplicateRecordSetId);
    System.assertEquals(2, response.sets[0].records.size());
    System.assert(response.sets[0].canMerge);
    System.assert(!response.sets[0].fieldNames.isEmpty());

    DuplicateAiService.DuplicateSetAnalysis singleSet = DuplicateAiController.analyzeSingleSet('Account', setRow.Id, false);
    System.assertEquals(2, singleSet.records.size());
    System.assertEquals(true, singleSet.canMerge);

    DuplicateMergeService.MergeProposal proposal = DuplicateAiController.getMergeProposal(
      'Account',
      new List<String>{ String.valueOf(parent.Id), String.valueOf(child.Id) },
      String.valueOf(parent.Id)
    );
    System.assertEquals(String.valueOf(parent.Id), proposal.survivorRecordId);
    System.assertEquals(2, proposal.records.size());
  }

  @IsTest
  static void executeSoftMerge_wrapperBuildsAndRunsMergeRequest() {
    Account parent = new Account(Name = 'Soft AI Parent', Phone = null);
    Account child = new Account(Name = 'Soft AI Child', Phone = '2125550101');
    insert new List<Account>{ parent, child };

    DuplicateMergeService.MergeProposal proposal = DuplicateAiController.getMergeProposal(
      'Account',
      new List<String>{ String.valueOf(parent.Id), String.valueOf(child.Id) },
      String.valueOf(parent.Id)
    );

    DuplicateMergeService.MergeExecutionResult result = DuplicateAiController.executeSoftMerge(
      'Account',
      String.valueOf(parent.Id),
      new List<String>{ String.valueOf(child.Id) },
      selectionsFromProposal(proposal)
    );
    System.assertEquals(true, result.success, result.message);
    System.assertEquals(1, result.softMergedCount);
  }

  @IsTest
  static void executeMerge_wrapperRunsRequest() {
    Account mergeParent = new Account(Name = 'Direct Execute Parent', Phone = null);
    Account mergeChild = new Account(Name = 'Direct Execute Child', Phone = '3035550202');
    insert new List<Account>{ mergeParent, mergeChild };
    DuplicateMergeService.MergeProposal directProposal = DuplicateAiController.getMergeProposal(
      'Account',
      new List<String>{ String.valueOf(mergeParent.Id), String.valueOf(mergeChild.Id) },
      String.valueOf(mergeParent.Id)
    );
    DuplicateMergeService.MergeExecutionRequest request = new DuplicateMergeService.MergeExecutionRequest();
    request.objectApiName = 'Account';
    request.survivorRecordId = String.valueOf(mergeParent.Id);
    request.loserRecordIds = new List<String>{ String.valueOf(mergeChild.Id) };
    request.fieldSelections = selectionsFromProposal(directProposal);
    DuplicateMergeService.MergeExecutionResult directResult = DuplicateAiController.executeMerge(request);
    System.assertEquals(true, directResult.success, directResult.message);
    System.assertEquals(1, directResult.softMergedCount);
  }

  @IsTest
  static void mergeRecords_wrapperUsesSoftMergeService() {
    Account parent = new Account(Name = 'Merge Records Parent', Phone = null);
    Account child = new Account(Name = 'Merge Records Child', Phone = '4155550101');
    insert new List<Account>{ parent, child };

    DuplicateAiService.ActionResult result = DuplicateAiController.mergeRecords('Account', parent.Id, new List<Id>{ child.Id });
    System.assertEquals(true, result.success, result.message);
    System.assertEquals(1, result.processedCount);
  }

  @IsTest
  static void mergeAndDeleteActions_validateUserInputAndDeleteRows() {
    Account parent = new Account(Name = 'Missing Merge Parent');
    insert parent;

    DuplicateAiService.ActionResult missingMergeInput = DuplicateAiController.mergeRecords(
      'Account',
      parent.Id,
      new List<Id>()
    );
    System.assertEquals(false, missingMergeInput.success);

    Account deleteMe = new Account(Name = 'Delete From AI Controller');
    insert deleteMe;
    DuplicateAiService.ActionResult deleteResult = DuplicateAiController.deleteRecords(new List<Id>{ deleteMe.Id });
    System.assertEquals(true, deleteResult.success, deleteResult.message);
    System.assertEquals(1, deleteResult.processedCount);
    System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Id = :deleteMe.Id]);
  }

  @IsTest
  static void analyzeObject_runAiUsesDeterministicFallbackWhenClientIsUnconfigured() {
    OpenAiResponsesClient.endpointOverrideForTest = null;
    OpenAiResponsesClient.apiKeyOverrideForTest = null;

    Account first = new Account(Name = 'Fallback Parent', Phone = '4155550101', Website = 'fallback.example');
    Account second = new Account(Name = 'Fallback Parent Inc', Phone = '4155550101', Website = 'https://fallback.example');
    insert new List<Account>{ first, second };
    createDuplicateRecordSet(new List<Id>{ first.Id, second.Id });

    DuplicateAiService.AnalysisResponse response = DuplicateAiController.analyzeObject('Account', 10, true);
    System.assertEquals(1, response.totalSets);
    System.assertEquals(1, response.warnings.size());
    System.assert(response.warnings[0].contains('AI analysis fallback used'));
    System.assert(response.sets[0].summary.contains('Fallback mode'));
    System.assertNotEquals(null, response.sets[0].parentRecordId);
    System.assertEquals(1, response.sets[0].records[0].rank);
    System.assertEquals(true, response.sets[0].records[0].isParent);
  }

  @IsTest
  static void analyzeObject_runAiAppliesSuccessfulClientDecision() {
    Account parent = new Account(Name = 'Mocked AI Parent', Phone = '6465550101');
    Account child = new Account(Name = 'Mocked AI Child', Phone = '6465550101');
    insert new List<Account>{ parent, child };
    createDuplicateRecordSet(new List<Id>{ parent.Id, child.Id });

    OpenAiResponsesClient.endpointOverrideForTest = 'https://example.invalid/v1/responses';
    OpenAiResponsesClient.apiKeyOverrideForTest = 'test-key';
    Test.setMock(
      HttpCalloutMock.class,
      new OpenAiMock(
        200,
        JSON.serialize(
          new Map<String, Object>{
            'output_text' => decisionJson(
              String.valueOf(parent.Id),
              String.valueOf(child.Id),
              'Mock AI selected the parent.'
            )
          }
        )
      )
    );

    Test.startTest();
    DuplicateAiService.AnalysisResponse response = DuplicateAiController.analyzeObject('Account', 10, true);
    Test.stopTest();

    System.assertEquals(0, response.warnings.size());
    System.assertEquals(String.valueOf(parent.Id), response.sets[0].parentRecordId);
    System.assertEquals('Mock AI selected the parent.', response.sets[0].summary);
    System.assertEquals('KEEP', response.sets[0].records[0].recommendedAction);
    System.assertEquals(String.valueOf(parent.Id), response.sets[0].records[0].recordId);
  }

  @IsTest
  static void openAiClient_parsesNestedOutputText() {
    OpenAiResponsesClient.endpointOverrideForTest = 'https://example.invalid/v1/responses';
    OpenAiResponsesClient.apiKeyOverrideForTest = 'test-key';
    String parentId = '001000000000001AAA';
    String childId = '001000000000002AAA';
    String outputText = decisionJson(parentId, childId, 'Nested output parsed.');
    String responseBody = JSON.serialize(
      new Map<String, Object>{
        'output' => new List<Object>{
          new Map<String, Object>{
            'content' => new List<Object>{
              new Map<String, Object>{ 'type' => 'output_text', 'text' => outputText }
            }
          }
        }
      }
    );
    Test.setMock(HttpCalloutMock.class, new OpenAiMock(200, responseBody));

    OpenAiResponsesClient.SetDecision decision = OpenAiResponsesClient.analyzeSet(
      'Account',
      'Nested Set',
      new List<Map<String, String>>{
        new Map<String, String>{ 'Id' => parentId, 'Name' => 'Nested Parent' },
        new Map<String, String>{ 'Id' => childId, 'Name' => 'Nested Child' }
      }
    );

    System.assertEquals(parentId, decision.parentRecordId);
    System.assertEquals('Nested output parsed.', decision.summary);
    System.assertEquals(2, decision.records.size());
    System.assertEquals(98, decision.records[0].matchScore);
    System.assertEquals(91, decision.records[0].qualityScore);
  }

  @IsTest
  static void openAiClient_reportsTransportAndParsingErrors() {
    OpenAiResponsesClient.endpointOverrideForTest = 'https://example.invalid/v1/responses';
    OpenAiResponsesClient.apiKeyOverrideForTest = 'test-key';

    assertOpenAiFailure(500, 'model unavailable', 'OpenAI callout failed');
    assertOpenAiFailure(200, 'not-json', 'OpenAI response was not valid JSON');
    assertOpenAiFailure(200, '{"output":[{"content":[]}]}', 'OpenAI response did not contain output_text');
    assertOpenAiFailure(200, '{"output_text":"not-json"}', 'OpenAI output_text was not valid decision JSON');

    try {
      OpenAiResponsesClient.analyzeSet('Account', 'Empty Set', new List<Map<String, String>>());
      System.assert(false, 'Expected empty record input to fail.');
    } catch (OpenAiResponsesClient.OpenAiClientException ex) {
      System.assert(ex.getMessage().contains('No records provided'), ex.getMessage());
    }
  }

  private static DuplicateRecordSet createDuplicateRecordSet(List<Id> recordIds) {
    DuplicateRecordSet setRow = new DuplicateRecordSet(DuplicateRuleId = accountDuplicateRuleId());
    insert setRow;

    List<DuplicateRecordItem> items = new List<DuplicateRecordItem>();
    for (Id recordId : recordIds) {
      items.add(new DuplicateRecordItem(DuplicateRecordSetId = setRow.Id, RecordId = recordId));
    }
    insert items;
    return setRow;
  }

  private static Id accountDuplicateRuleId() {
    List<DuplicateRule> rules = [
      SELECT Id
      FROM DuplicateRule
      WHERE SobjectType = 'Account'
      ORDER BY IsActive DESC, DeveloperName ASC
      LIMIT 1
    ];
    System.assert(!rules.isEmpty(), 'Expected an Account duplicate rule to be available for DuplicateRecordSet test data.');
    return rules[0].Id;
  }

  private static List<DuplicateMergeService.FieldSelectionInput> selectionsFromProposal(
    DuplicateMergeService.MergeProposal proposal
  ) {
    List<DuplicateMergeService.FieldSelectionInput> selections = new List<DuplicateMergeService.FieldSelectionInput>();
    for (DuplicateMergeService.FieldProposal fieldProposal : proposal.fields) {
      DuplicateMergeService.FieldSelectionInput selection = new DuplicateMergeService.FieldSelectionInput();
      selection.fieldApiName = fieldProposal.fieldApiName;
      selection.sourceRecordId = fieldProposal.recommendedSourceRecordId;
      selections.add(selection);
    }
    return selections;
  }

  private static String decisionJson(String parentId, String childId, String summary) {
    return JSON.serialize(
      new Map<String, Object>{
        'parentRecordId' => parentId,
        'summary' => summary,
        'records' => new List<Object>{
          new Map<String, Object>{
            'recordId' => parentId,
            'matchScore' => 98,
            'qualityScore' => '91',
            'reason' => 'Most complete record',
            'recommendedAction' => 'KEEP'
          },
          new Map<String, Object>{
            'recordId' => childId,
            'matchScore' => 88,
            'qualityScore' => 64,
            'reason' => 'Strong duplicate match',
            'recommendedAction' => 'MERGE'
          }
        }
      }
    );
  }

  private static void assertOpenAiFailure(Integer statusCode, String responseBody, String expectedMessage) {
    Test.setMock(HttpCalloutMock.class, new OpenAiMock(statusCode, responseBody));
    try {
      OpenAiResponsesClient.analyzeSet(
        'Account',
        'Error Set',
        new List<Map<String, String>>{ new Map<String, String>{ 'Id' => '001000000000003AAA', 'Name' => 'Error' } }
      );
      System.assert(false, 'Expected OpenAI client failure containing: ' + expectedMessage);
    } catch (OpenAiResponsesClient.OpenAiClientException ex) {
      System.assert(ex.getMessage().contains(expectedMessage), ex.getMessage());
    }
  }
}
