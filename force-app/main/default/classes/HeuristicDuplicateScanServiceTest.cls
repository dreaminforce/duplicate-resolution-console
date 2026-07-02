@IsTest
private class HeuristicDuplicateScanServiceTest {
  @IsTest
  static void startScan_forAccount_persistsGroupsAndMembers() {
    insert new List<Account>{
      new Account(Name = 'Blue Sky Consulting', Phone = '+1 (212) 555-0144', BillingCity = 'New York', Website = 'https://www.bluesky.example'),
      new Account(Name = 'BlueSky Consulting', Phone = '6465550199', BillingCity = 'New York', Website = 'bluesky.example'),
      new Account(Name = 'Red Valley Manufacturing', Phone = '4159991111', BillingCity = 'San Francisco', Website = 'redvalley.example')
    };

    Id scanId;
    Test.startTest();
    scanId = HeuristicDuplicateScanController.startScan('Account', 500, 75, true);
    Test.stopTest();

    Heuristic_Duplicate_Scan__c scan = [
      SELECT
        Status__c,
        Object_Api_Name__c,
        Object_Label__c,
        Flagged_Accounts__c,
        Flagged_Groups__c,
        Total_Accounts__c,
        Threshold__c,
        Max_Accounts__c,
        Completed_At__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scanId
      LIMIT 1
    ];

    System.assertEquals('Completed', scan.Status__c);
    System.assertEquals('Account', scan.Object_Api_Name__c);
    System.assertEquals(2, scan.Flagged_Accounts__c.intValue());
    System.assertEquals(1, scan.Flagged_Groups__c.intValue());
    System.assertEquals(3, scan.Total_Accounts__c.intValue());
    System.assertEquals(75, scan.Threshold__c.intValue());
    System.assertEquals(500, scan.Max_Accounts__c.intValue());
    System.assertNotEquals(null, scan.Completed_At__c);

    List<Heuristic_Duplicate_Group__c> groups = [
      SELECT Id, Group_Key__c, Record_Count__c, Top_Score__c, Scan__c, Object_Api_Name__c
      FROM Heuristic_Duplicate_Group__c
      WHERE Scan__c = :scanId
      ORDER BY Group_Key__c ASC
    ];

    System.assertEquals(1, groups.size());
    System.assertEquals(2, groups[0].Record_Count__c.intValue());
    System.assertEquals('Account', groups[0].Object_Api_Name__c);

    List<Heuristic_Duplicate_Member__c> members = [
      SELECT Id, Scan__c, Group__c, Record_Id__c, Display_Value__c, Score__c, Object_Api_Name__c
      FROM Heuristic_Duplicate_Member__c
      WHERE Scan__c = :scanId
      ORDER BY Display_Value__c ASC
    ];

    System.assertEquals(2, members.size());
    System.assertEquals('Account', members[0].Object_Api_Name__c);
    System.assertNotEquals(null, members[0].Record_Id__c);
    System.assertNotEquals(null, members[0].Score__c);
    System.assertEquals(0, [SELECT COUNT() FROM Heuristic_Duplicate_Candidate__c WHERE Scan__c = :scanId]);

    HeuristicDuplicateScanService.ScanStatus status = HeuristicDuplicateScanController.getScanStatus(scanId);
    System.assertEquals(scanId, status.scanId);
    System.assertEquals('Completed', status.status);
    System.assertEquals('Account', status.objectApiName);
    System.assertEquals(2, status.flaggedRecords);
    System.assertEquals(1, status.flaggedGroups);

    List<HeuristicDuplicateScanService.DuplicateGroup> viewGroups = HeuristicDuplicateScanController.getGroupsForScan(scanId, 10);
    System.assertEquals(1, viewGroups.size());
    System.assertEquals(2, viewGroups[0].recordCount);
    System.assert(viewGroups[0].topScore >= 75);

    HeuristicDuplicateScanService.GroupDetail detail = HeuristicDuplicateScanController.getGroupDetail(viewGroups[0].groupId);
    System.assertEquals(viewGroups[0].groupKey, detail.groupKey);
    System.assertEquals('Account', detail.objectApiName);
    System.assertEquals(2, detail.records.size());
    System.assert(!detail.fieldNames.isEmpty());
  }

  @IsTest
  static void bucketAnalysisBatch_persistsGroupsAndCleansStagedCandidates() {
    Account first = new Account(Name = 'Enterprise Scale Partners', Phone = '2125550101', BillingCity = 'New York', Website = 'enterprise-scale.example');
    Account second = new Account(Name = 'Enterprise Scale Partner', Phone = '6465550199', BillingCity = 'New York', Website = 'https://enterprise-scale.example');
    Account third = new Account(Name = 'Enterprise Freight Scale Partners', Phone = '7185550123', BillingCity = 'New York', Website = 'enterprise-scale.example');
    insert new List<Account>{ first, second, third };

    Heuristic_Duplicate_Scan__c scan = new Heuristic_Duplicate_Scan__c(
      Status__c = 'Running',
      Object_Api_Name__c = 'Account',
      Object_Label__c = 'Account',
      Max_Accounts__c = 400000,
      Threshold__c = 75,
      Clear_Previous_Flags__c = true
    );
    insert scan;

    insert new List<Heuristic_Duplicate_Candidate__c>{
      new Heuristic_Duplicate_Candidate__c(
        Scan__c = scan.Id,
        Object_Api_Name__c = 'Account',
        Bucket_Key__c = 'D|enterprise-scale.example',
        Record_Id__c = String.valueOf(first.Id),
        Display_Value__c = first.Name,
        Name_Normalized__c = 'enterprise scale partners',
        Name_Compact__c = 'enterprisescalepartners',
        Phone__c = '2125550101',
        Phone_Normalized__c = '2125550101',
        Website__c = 'enterprise-scale.example',
        Domain_Normalized__c = 'enterprise-scale.example',
        City__c = 'New York',
        City_Normalized__c = 'newyork'
      ),
      new Heuristic_Duplicate_Candidate__c(
        Scan__c = scan.Id,
        Object_Api_Name__c = 'Account',
        Bucket_Key__c = 'D|enterprise-scale.example',
        Record_Id__c = String.valueOf(second.Id),
        Display_Value__c = second.Name,
        Name_Normalized__c = 'enterprise scale partner',
        Name_Compact__c = 'enterprisescalepartner',
        Phone__c = '6465550199',
        Phone_Normalized__c = '6465550199',
        Website__c = 'https://enterprise-scale.example',
        Domain_Normalized__c = 'enterprise-scale.example',
        City__c = 'New York',
        City_Normalized__c = 'newyork'
      ),
      new Heuristic_Duplicate_Candidate__c(
        Scan__c = scan.Id,
        Object_Api_Name__c = 'Account',
        Bucket_Key__c = 'D|enterprise-scale.example',
        Record_Id__c = String.valueOf(third.Id),
        Display_Value__c = third.Name,
        Name_Normalized__c = 'enterprise freight scale partners',
        Name_Compact__c = 'enterprisefreightscalepartners',
        Phone__c = '7185550123',
        Phone_Normalized__c = '7185550123',
        Website__c = 'enterprise-scale.example',
        Domain_Normalized__c = 'enterprise-scale.example',
        City__c = 'New York',
        City_Normalized__c = 'newyork'
      )
    };

    Test.startTest();
    Database.executeBatch(new HeuristicDuplicateBucketAnalysisBatch(scan.Id, 'Account', 'Account', 75, 3), 1000);
    Test.stopTest();

    Heuristic_Duplicate_Scan__c refreshed = [
      SELECT Status__c, Total_Accounts__c, Processed_Accounts__c, Flagged_Accounts__c, Flagged_Groups__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scan.Id
      LIMIT 1
    ];

    System.assertEquals('Completed', refreshed.Status__c);
    System.assertEquals(3, refreshed.Total_Accounts__c.intValue());
    System.assertEquals(3, refreshed.Processed_Accounts__c.intValue());
    System.assertEquals(3, refreshed.Flagged_Accounts__c.intValue());
    System.assertEquals(1, refreshed.Flagged_Groups__c.intValue());
    System.assertEquals(0, [SELECT COUNT() FROM Heuristic_Duplicate_Candidate__c WHERE Scan__c = :scan.Id]);
  }

  @IsTest
  static void startScan_matchesSharedDomainWhenNameHasInsertedToken() {
    insert new List<Account>{
      new Account(Name = 'Acme Logistics', Phone = '3035550101', BillingCity = 'Denver', Website = 'acme-token-subset.example'),
      new Account(Name = 'Acme Freight Logistics', Phone = '7205550199', BillingCity = 'Denver', Website = 'https://acme-token-subset.example'),
      new Account(Name = 'Summit Outdoor Supply', Phone = '7205550144', BillingCity = 'Boulder', Website = 'summit-token-subset.example')
    };

    Id scanId;
    Test.startTest();
    scanId = HeuristicDuplicateScanController.startScan('Account', 500, 75, true);
    Test.stopTest();

    Heuristic_Duplicate_Scan__c scan = [
      SELECT Status__c, Flagged_Accounts__c, Flagged_Groups__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scanId
      LIMIT 1
    ];

    System.assertEquals('Completed', scan.Status__c);
    System.assertEquals(2, scan.Flagged_Accounts__c.intValue());
    System.assertEquals(1, scan.Flagged_Groups__c.intValue());
  }

  @IsTest
  static void bucketAnalysisBatch_updatesExistingPairEvidenceBeforeConsolidation() {
    Account first = new Account(Name = 'Acme Logistics', Phone = '3035550101');
    Account second = new Account(Name = 'Acme Logistics', Phone = '(303) 555-0101');
    insert new List<Account>{ first, second };

    Heuristic_Duplicate_Scan__c scan = new Heuristic_Duplicate_Scan__c(
      Status__c = 'Running',
      Object_Api_Name__c = 'Account',
      Object_Label__c = 'Account',
      Max_Accounts__c = 400000,
      Threshold__c = 75,
      Clear_Previous_Flags__c = true
    );
    insert scan;

    insert new Heuristic_Duplicate_Pair__c(
      Scan__c = scan.Id,
      Object_Api_Name__c = 'Account',
      Pair_Key__c = testPairKey(scan.Id, first.Id, second.Id),
      Left_Record_Id__c = String.valueOf(first.Id),
      Right_Record_Id__c = String.valueOf(second.Id),
      Score__c = 50,
      Reason__c = 'Older lower score'
    );

    insert new List<Heuristic_Duplicate_Candidate__c>{
      new Heuristic_Duplicate_Candidate__c(
        Scan__c = scan.Id,
        Object_Api_Name__c = 'Account',
        Bucket_Key__c = 'P|3035550101',
        Record_Id__c = String.valueOf(first.Id),
        Display_Value__c = first.Name,
        Name_Normalized__c = 'acme logistics',
        Name_Compact__c = 'acmelogistics',
        Phone__c = '3035550101',
        Phone_Normalized__c = '3035550101'
      ),
      new Heuristic_Duplicate_Candidate__c(
        Scan__c = scan.Id,
        Object_Api_Name__c = 'Account',
        Bucket_Key__c = 'P|3035550101',
        Record_Id__c = String.valueOf(second.Id),
        Display_Value__c = second.Name,
        Name_Normalized__c = 'acme logistics',
        Name_Compact__c = 'acmelogistics',
        Phone__c = '(303) 555-0101',
        Phone_Normalized__c = '3035550101'
      )
    };

    Test.startTest();
    Database.executeBatch(new HeuristicDuplicateBucketAnalysisBatch(scan.Id, 'Account', 'Account', 75, 2), 1000);
    Test.stopTest();

    List<Heuristic_Duplicate_Group__c> groups = [
      SELECT Record_Count__c, Top_Score__c
      FROM Heuristic_Duplicate_Group__c
      WHERE Scan__c = :scan.Id
    ];
    System.assertEquals(1, groups.size());
    System.assertEquals(2, groups[0].Record_Count__c.intValue());
    System.assertEquals(80, groups[0].Top_Score__c.intValue());
    System.assertEquals(0, [SELECT COUNT() FROM Heuristic_Duplicate_Pair__c WHERE Scan__c = :scan.Id]);
  }

  @IsTest
  static void candidateCleanupBatch_removesTemporaryRows() {
    Account account = new Account(Name = 'Cleanup Candidate', Phone = '2125550999');
    insert account;

    Heuristic_Duplicate_Scan__c scan = new Heuristic_Duplicate_Scan__c(
      Status__c = 'Cancelled',
      Object_Api_Name__c = 'Account',
      Object_Label__c = 'Account',
      Max_Accounts__c = 400000,
      Threshold__c = 75,
      Clear_Previous_Flags__c = true
    );
    insert scan;

    insert new Heuristic_Duplicate_Candidate__c(
      Scan__c = scan.Id,
      Object_Api_Name__c = 'Account',
      Bucket_Key__c = 'P|2125550999',
      Record_Id__c = String.valueOf(account.Id),
      Display_Value__c = account.Name,
      Name_Normalized__c = 'cleanup candidate',
      Name_Compact__c = 'cleanupcandidate',
      Phone__c = '2125550999',
      Phone_Normalized__c = '2125550999'
    );

    Test.startTest();
    Database.executeBatch(new HeuristicDuplicateCandidateCleanupBatch(scan.Id), 2000);
    Test.stopTest();

    System.assertEquals(0, [SELECT COUNT() FROM Heuristic_Duplicate_Candidate__c WHERE Scan__c = :scan.Id]);
  }

  @IsTest
  static void pairCleanupBatch_removesTemporaryRows() {
    Account first = new Account(Name = 'Pair Cleanup One', Phone = '2125550301');
    Account second = new Account(Name = 'Pair Cleanup Two', Phone = '2125550301');
    insert new List<Account>{ first, second };

    Heuristic_Duplicate_Scan__c scan = new Heuristic_Duplicate_Scan__c(
      Status__c = 'Running',
      Object_Api_Name__c = 'Account',
      Object_Label__c = 'Account',
      Max_Accounts__c = 400000,
      Threshold__c = 75,
      Clear_Previous_Flags__c = true
    );
    insert scan;

    insert new Heuristic_Duplicate_Pair__c(
      Scan__c = scan.Id,
      Object_Api_Name__c = 'Account',
      Pair_Key__c = testPairKey(scan.Id, first.Id, second.Id),
      Left_Record_Id__c = String.valueOf(first.Id),
      Right_Record_Id__c = String.valueOf(second.Id),
      Score__c = 90,
      Reason__c = 'Phone exact'
    );

    Test.startTest();
    Database.executeBatch(new HeuristicDuplicatePairCleanupBatch(scan.Id), 2000);
    Test.stopTest();

    System.assertEquals(0, [SELECT COUNT() FROM Heuristic_Duplicate_Pair__c WHERE Scan__c = :scan.Id]);
  }

  @IsTest
  static void pairConsolidationBatch_mergesOverlappingPairsIntoOneGroup() {
    Account first = new Account(Name = 'Blue Sky Consulting', Phone = '2125550144', Website = 'bluesky.example');
    Account second = new Account(Name = 'Blue Sky Ltd', Phone = '2125550144', Website = 'bluesky.example');
    Account third = new Account(Name = 'BlueSky Consulting', Phone = '6465550199', Website = 'bluesky.example');
    insert new List<Account>{ first, second, third };

    Heuristic_Duplicate_Scan__c scan = new Heuristic_Duplicate_Scan__c(
      Status__c = 'Running',
      Object_Api_Name__c = 'Account',
      Object_Label__c = 'Account',
      Max_Accounts__c = 400000,
      Threshold__c = 75,
      Clear_Previous_Flags__c = true
    );
    insert scan;

    insert new List<Heuristic_Duplicate_Pair__c>{
      new Heuristic_Duplicate_Pair__c(
        Scan__c = scan.Id,
        Object_Api_Name__c = 'Account',
        Pair_Key__c = testPairKey(scan.Id, first.Id, second.Id),
        Left_Record_Id__c = String.valueOf(first.Id),
        Right_Record_Id__c = String.valueOf(second.Id),
        Score__c = 88,
        Reason__c = 'Phone exact',
        Left_Display_Value__c = first.Name,
        Left_Phone__c = first.Phone,
        Left_Website__c = first.Website,
        Right_Display_Value__c = second.Name,
        Right_Phone__c = second.Phone,
        Right_Website__c = second.Website
      ),
      new Heuristic_Duplicate_Pair__c(
        Scan__c = scan.Id,
        Object_Api_Name__c = 'Account',
        Pair_Key__c = testPairKey(scan.Id, second.Id, third.Id),
        Left_Record_Id__c = String.valueOf(second.Id),
        Right_Record_Id__c = String.valueOf(third.Id),
        Score__c = 84,
        Reason__c = 'Domain exact',
        Left_Display_Value__c = second.Name,
        Left_Phone__c = second.Phone,
        Left_Website__c = second.Website,
        Right_Display_Value__c = third.Name,
        Right_Phone__c = third.Phone,
        Right_Website__c = third.Website
      )
    };

    Test.startTest();
    Database.executeBatch(new HeuristicDuplicatePairConsolidationBatch(scan.Id, 'Account', 'Account', 3, 2), 1000);
    Test.stopTest();

    Heuristic_Duplicate_Scan__c refreshed = [
      SELECT Status__c, Flagged_Accounts__c, Flagged_Groups__c, Candidate_Pairs__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scan.Id
      LIMIT 1
    ];

    System.assertEquals('Completed', refreshed.Status__c);
    System.assertEquals(3, refreshed.Flagged_Accounts__c.intValue());
    System.assertEquals(1, refreshed.Flagged_Groups__c.intValue());
    System.assertEquals(2, refreshed.Candidate_Pairs__c.intValue());

    List<Heuristic_Duplicate_Group__c> groups = [
      SELECT Id, Record_Count__c
      FROM Heuristic_Duplicate_Group__c
      WHERE Scan__c = :scan.Id
    ];
    System.assertEquals(1, groups.size());
    System.assertEquals(3, groups[0].Record_Count__c.intValue());

    Set<String> memberIds = new Set<String>();
    for (Heuristic_Duplicate_Member__c member : [
      SELECT Record_Id__c
      FROM Heuristic_Duplicate_Member__c
      WHERE Scan__c = :scan.Id
    ]) {
      memberIds.add(member.Record_Id__c);
    }

    System.assertEquals(new Set<String>{ String.valueOf(first.Id), String.valueOf(second.Id), String.valueOf(third.Id) }, memberIds);
    System.assertEquals(0, [SELECT COUNT() FROM Heuristic_Duplicate_Pair__c WHERE Scan__c = :scan.Id]);
  }

  @IsTest
  static void pairConsolidationBatch_canHandOffToPersistBatch() {
    Account first = new Account(Name = 'Async Persist One', Phone = '5125550101');
    Account second = new Account(Name = 'Async Persist Two', Phone = '5125550101');
    insert new List<Account>{ first, second };

    Heuristic_Duplicate_Scan__c scan = new Heuristic_Duplicate_Scan__c(
      Status__c = 'Running',
      Object_Api_Name__c = 'Account',
      Object_Label__c = 'Account',
      Max_Accounts__c = 400000,
      Threshold__c = 75,
      Clear_Previous_Flags__c = true
    );
    insert scan;

    insert new Heuristic_Duplicate_Pair__c(
      Scan__c = scan.Id,
      Object_Api_Name__c = 'Account',
      Pair_Key__c = testPairKey(scan.Id, first.Id, second.Id),
      Left_Record_Id__c = String.valueOf(first.Id),
      Right_Record_Id__c = String.valueOf(second.Id),
      Score__c = 86,
      Reason__c = 'Phone exact',
      Left_Display_Value__c = first.Name,
      Left_Phone__c = first.Phone,
      Right_Display_Value__c = second.Name,
      Right_Phone__c = second.Phone
    );

    List<SObject> pairRows = new List<SObject>();
    pairRows.addAll([
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
      WHERE Scan__c = :scan.Id
    ]);

    HeuristicDuplicatePairConsolidationBatch worker = new HeuristicDuplicatePairConsolidationBatch(
      scan.Id,
      'Account',
      'Account',
      2,
      1
    );

    Test.startTest();
    HeuristicDuplicatePairConsolidationBatch.forceAsyncPersistForTest = true;
    worker.execute(null, pairRows);
    worker.finish(null);
    Test.stopTest();
    HeuristicDuplicatePairConsolidationBatch.forceAsyncPersistForTest = false;

    Heuristic_Duplicate_Scan__c refreshed = [
      SELECT Status__c, Flagged_Accounts__c, Flagged_Groups__c, Candidate_Pairs__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scan.Id
      LIMIT 1
    ];
    System.assertEquals('Completed', refreshed.Status__c);
    System.assertEquals(2, refreshed.Flagged_Accounts__c.intValue());
    System.assertEquals(1, refreshed.Flagged_Groups__c.intValue());
    System.assertEquals(1, refreshed.Candidate_Pairs__c.intValue());
    System.assertEquals(0, [SELECT COUNT() FROM Heuristic_Duplicate_Pair__c WHERE Scan__c = :scan.Id]);
  }

  @IsTest
  static void pairConsolidationBatch_completesWhenNoPairsExist() {
    Heuristic_Duplicate_Scan__c scan = new Heuristic_Duplicate_Scan__c(
      Status__c = 'Running',
      Object_Api_Name__c = 'Account',
      Object_Label__c = 'Account',
      Max_Accounts__c = 400000,
      Threshold__c = 75,
      Clear_Previous_Flags__c = true
    );
    insert scan;

    Test.startTest();
    HeuristicDuplicatePairConsolidationBatch.forceAsyncPersistForTest = true;
    new HeuristicDuplicatePairConsolidationBatch(scan.Id, 'Account', 'Account', 0, 0).finish(null);
    Test.stopTest();
    HeuristicDuplicatePairConsolidationBatch.forceAsyncPersistForTest = false;

    Heuristic_Duplicate_Scan__c refreshed = [
      SELECT Status__c, Flagged_Accounts__c, Flagged_Groups__c, Candidate_Pairs__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scan.Id
      LIMIT 1
    ];
    System.assertEquals('Completed', refreshed.Status__c);
    System.assertEquals(0, refreshed.Flagged_Accounts__c.intValue());
    System.assertEquals(0, refreshed.Flagged_Groups__c.intValue());
    System.assertEquals(0, refreshed.Candidate_Pairs__c.intValue());
  }

  @IsTest
  static void groupPersistBatch_writesFinalGroupsAndCleansPairs() {
    Account first = new Account(Name = 'Persist Batch One', Phone = '7205550101');
    Account second = new Account(Name = 'Persist Batch Two', Phone = '7205550101');
    insert new List<Account>{ first, second };

    Heuristic_Duplicate_Scan__c scan = new Heuristic_Duplicate_Scan__c(
      Status__c = 'Running',
      Object_Api_Name__c = 'Account',
      Object_Label__c = 'Account',
      Max_Accounts__c = 400000,
      Threshold__c = 75,
      Clear_Previous_Flags__c = true
    );
    insert scan;

    insert new Heuristic_Duplicate_Pair__c(
      Scan__c = scan.Id,
      Object_Api_Name__c = 'Account',
      Pair_Key__c = testPairKey(scan.Id, first.Id, second.Id),
      Left_Record_Id__c = String.valueOf(first.Id),
      Right_Record_Id__c = String.valueOf(second.Id),
      Score__c = 91,
      Reason__c = 'Phone exact'
    );

    String groupKey = 'HDS-TEST-PERSIST';
    String firstId = String.valueOf(first.Id);
    String secondId = String.valueOf(second.Id);
    List<String> groupKeys = new List<String>{ groupKey };
    Map<String, List<String>> memberIdsByGroup = new Map<String, List<String>>{
      groupKey => new List<String>{ firstId, secondId }
    };

    Test.startTest();
    Database.executeBatch(
      new HeuristicDuplicateGroupPersistBatch(
        scan.Id,
        'Account',
        'Account',
        2,
        1,
        groupKeys,
        memberIdsByGroup,
        new Map<String, Integer>{ groupKey => 91 },
        new Map<String, String>{ groupKey => 'Phone exact' },
        new Map<String, Integer>{ firstId => 91, secondId => 91 },
        new Map<String, String>{ firstId => 'Phone exact', secondId => 'Phone exact' },
        new Map<String, String>{ firstId => first.Name, secondId => second.Name },
        new Map<String, String>{ firstId => first.Phone, secondId => second.Phone },
        new Map<String, String>(),
        new Map<String, String>()
      ),
      1
    );
    Test.stopTest();

    Heuristic_Duplicate_Scan__c refreshed = [
      SELECT Status__c, Flagged_Accounts__c, Flagged_Groups__c, Candidate_Pairs__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scan.Id
      LIMIT 1
    ];
    System.assertEquals('Completed', refreshed.Status__c);
    System.assertEquals(2, refreshed.Flagged_Accounts__c.intValue());
    System.assertEquals(1, refreshed.Flagged_Groups__c.intValue());
    System.assertEquals(1, refreshed.Candidate_Pairs__c.intValue());

    System.assertEquals(1, [SELECT COUNT() FROM Heuristic_Duplicate_Group__c WHERE Scan__c = :scan.Id]);
    System.assertEquals(2, [SELECT COUNT() FROM Heuristic_Duplicate_Member__c WHERE Scan__c = :scan.Id]);
    System.assertEquals(0, [SELECT COUNT() FROM Heuristic_Duplicate_Pair__c WHERE Scan__c = :scan.Id]);
  }

  @IsTest
  static void bucketAnalysisBatch_skipsOversizedBucketsAndCleansRows() {
    List<Account> accounts = new List<Account>();
    for (Integer i = 0; i < 71; i++) {
      accounts.add(new Account(Name = 'Shared Phone ' + i, Phone = '0000000000'));
    }
    insert accounts;

    Heuristic_Duplicate_Scan__c scan = new Heuristic_Duplicate_Scan__c(
      Status__c = 'Running',
      Object_Api_Name__c = 'Account',
      Object_Label__c = 'Account',
      Max_Accounts__c = 400000,
      Threshold__c = 75,
      Clear_Previous_Flags__c = true
    );
    insert scan;

    List<Heuristic_Duplicate_Candidate__c> candidates = new List<Heuristic_Duplicate_Candidate__c>();
    for (Account account : accounts) {
      candidates.add(new Heuristic_Duplicate_Candidate__c(
        Scan__c = scan.Id,
        Object_Api_Name__c = 'Account',
        Bucket_Key__c = 'P|0000000000',
        Record_Id__c = String.valueOf(account.Id),
        Display_Value__c = account.Name,
        Name_Normalized__c = account.Name.toLowerCase(),
        Name_Compact__c = account.Name.toLowerCase().replace(' ', ''),
        Phone__c = '0000000000',
        Phone_Normalized__c = '0000000000'
      ));
    }
    insert candidates;

    Test.startTest();
    Database.executeBatch(new HeuristicDuplicateBucketAnalysisBatch(scan.Id, 'Account', 'Account', 75, accounts.size()), 1000);
    Test.stopTest();

    Heuristic_Duplicate_Scan__c refreshed = [
      SELECT Status__c, Flagged_Accounts__c, Flagged_Groups__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scan.Id
      LIMIT 1
    ];

    System.assertEquals('Completed', refreshed.Status__c);
    System.assertEquals(0, refreshed.Flagged_Accounts__c.intValue());
    System.assertEquals(0, refreshed.Flagged_Groups__c.intValue());
    System.assertEquals(0, [SELECT COUNT() FROM Heuristic_Duplicate_Candidate__c WHERE Scan__c = :scan.Id]);
  }

  @IsTest
  static void startScan_forContact_onlyMatchesWithinContactObject() {
    insert new List<Account>{
      new Account(Name = 'Northwind Global'),
      new Account(Name = 'North Wind Global')
    };

    Contact c1 = new Contact(FirstName = 'John', LastName = 'Smith', Email = 'john.smith@example.com', Phone = '2125550100', MailingCity = 'New York');
    Contact c2 = new Contact(FirstName = 'Jon', LastName = 'Smith', Email = 'john.smith@example.com', Phone = '(212) 555-0100', MailingCity = 'New York');
    Contact c3 = new Contact(FirstName = 'Elena', LastName = 'Stone', Email = 'elena.stone@example.com', Phone = '4153330000', MailingCity = 'San Jose');
    insert new List<Contact>{ c1, c2, c3 };

    Id scanId;
    Test.startTest();
    scanId = HeuristicDuplicateScanController.startScan('Contact', 1000, 70, true);
    Test.stopTest();

    Heuristic_Duplicate_Scan__c scan = [
      SELECT Status__c, Object_Api_Name__c, Flagged_Accounts__c, Flagged_Groups__c
      FROM Heuristic_Duplicate_Scan__c
      WHERE Id = :scanId
      LIMIT 1
    ];

    System.assertEquals('Completed', scan.Status__c);
    System.assertEquals('Contact', scan.Object_Api_Name__c);
    System.assertEquals(2, scan.Flagged_Accounts__c.intValue());
    System.assertEquals(1, scan.Flagged_Groups__c.intValue());

    List<Heuristic_Duplicate_Member__c> members = [
      SELECT Record_Id__c, Object_Api_Name__c
      FROM Heuristic_Duplicate_Member__c
      WHERE Scan__c = :scanId
    ];

    System.assertEquals(2, members.size());
    for (Heuristic_Duplicate_Member__c row : members) {
      System.assertEquals('Contact', row.Object_Api_Name__c);
      System.assert(row.Record_Id__c.startsWith('003'));
    }
  }

  @IsTest
  static void objectOptions_recentAndCancel_areAvailable() {
    List<HeuristicDuplicateScanService.ObjectOption> options = HeuristicDuplicateScanController.getObjectOptions();
    System.assert(!options.isEmpty());

    Boolean hasAccount = false;
    for (HeuristicDuplicateScanService.ObjectOption option : options) {
      if (option.objectApiName == 'Account') {
        hasAccount = true;
        break;
      }
    }
    System.assertEquals(true, hasAccount);

    Heuristic_Duplicate_Scan__c scan = new Heuristic_Duplicate_Scan__c(
      Status__c = 'Queued',
      Object_Api_Name__c = 'Account',
      Object_Label__c = 'Account',
      Max_Accounts__c = 100,
      Threshold__c = 80,
      Clear_Previous_Flags__c = true
    );
    insert scan;

    List<HeuristicDuplicateScanService.ScanStatus> recent = HeuristicDuplicateScanController.getRecentScans(5);
    System.assert(!recent.isEmpty());

    HeuristicDuplicateScanService.ActionResult cancelResult = HeuristicDuplicateScanController.cancelScan(scan.Id);
    System.assertEquals(false, cancelResult.success);
    System.assert(cancelResult.message.contains('No async job'));
  }

  @IsTest
  static void mergeProposal_andExecute_softMergeAccount() {
    Account survivor = new Account(Name = 'Merge Parent', Phone = null, Description = null, BillingCity = 'New York');
    Account child = new Account(
      Name = 'Merge Child',
      Phone = '2125550101',
      Description = 'Preferred description from duplicate child.',
      BillingCity = 'New York'
    );
    insert new List<Account>{ survivor, child };

    Contact relatedContact = new Contact(LastName = 'Related', AccountId = child.Id);
    insert relatedContact;

    DuplicateMergeService.MergeProposal proposal = HeuristicDuplicateScanController.getMergeProposal(
      'Account',
      new List<String>{ String.valueOf(survivor.Id), String.valueOf(child.Id) },
      String.valueOf(survivor.Id)
    );

    System.assertEquals(String.valueOf(survivor.Id), proposal.survivorRecordId);
    System.assertEquals(2, proposal.records.size());
    System.assert(proposal.relatedRecordCount > 0);

    Boolean foundPhoneRecommendation = false;
    for (DuplicateMergeService.FieldProposal fieldProposal : proposal.fields) {
      if (fieldProposal.fieldApiName == 'Phone') {
        foundPhoneRecommendation = true;
        System.assertEquals(String.valueOf(child.Id), fieldProposal.recommendedSourceRecordId);
      }
    }
    System.assertEquals(true, foundPhoneRecommendation);

    DuplicateMergeService.MergeExecutionRequest request = new DuplicateMergeService.MergeExecutionRequest();
    request.objectApiName = 'Account';
    request.survivorRecordId = String.valueOf(survivor.Id);
    request.loserRecordIds = new List<String>{ String.valueOf(child.Id) };
    request.fieldSelections = new List<DuplicateMergeService.FieldSelectionInput>();
    for (DuplicateMergeService.FieldProposal fieldProposal : proposal.fields) {
      DuplicateMergeService.FieldSelectionInput selection = new DuplicateMergeService.FieldSelectionInput();
      selection.fieldApiName = fieldProposal.fieldApiName;
      selection.sourceRecordId = fieldProposal.recommendedSourceRecordId;
      request.fieldSelections.add(selection);
    }

    DuplicateMergeService.MergeExecutionResult result;
    Test.startTest();
    result = HeuristicDuplicateScanController.executeMerge(request);
    Test.stopTest();
    System.assertEquals(true, result.success, result.message);
    System.assertEquals(1, result.softMergedCount);

    Account refreshedSurvivor = [
      SELECT Phone, Description
      FROM Account
      WHERE Id = :survivor.Id
      LIMIT 1
    ];
    System.assertEquals('2125550101', refreshedSurvivor.Phone);
    System.assertEquals('Preferred description from duplicate child.', refreshedSurvivor.Description);

    Contact refreshedContact = [
      SELECT AccountId
      FROM Contact
      WHERE Id = :relatedContact.Id
      LIMIT 1
    ];
    System.assertEquals(survivor.Id, refreshedContact.AccountId);

    System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Id = :child.Id]);

    List<Duplicate_Merge_Record__c> registryRows = [
      SELECT Source_Record_Id__c, Merged_Into_Record_Id__c, Soft_Merge_Status__c, Snapshot_JSON__c
      FROM Duplicate_Merge_Record__c
      WHERE Source_Record_Id__c = :String.valueOf(child.Id)
    ];
    System.assertEquals(1, registryRows.size());
    System.assertEquals(String.valueOf(survivor.Id), registryRows[0].Merged_Into_Record_Id__c);
    System.assertEquals('Merged', registryRows[0].Soft_Merge_Status__c);
    System.assert(registryRows[0].Snapshot_JSON__c.contains(String.valueOf(child.Id)));

    List<Duplicate_Merge_Run__c> runs = [
      SELECT Status__c, Updated_Field_Count__c, Reparented_Record_Count__c, Merged_Record_Count__c
      FROM Duplicate_Merge_Run__c
      ORDER BY CreatedDate DESC
      LIMIT 1
    ];
    System.assertEquals(1, runs.size());
    System.assertEquals('Completed', runs[0].Status__c);
    System.assert(runs[0].Updated_Field_Count__c > 0);
    System.assert(runs[0].Reparented_Record_Count__c > 0);
    System.assertEquals(1, runs[0].Merged_Record_Count__c.intValue());
  }

  @IsTest
  static void executeSoftMerge_wrapperBuildsAndRunsMergeRequest() {
    Account survivor = new Account(Name = 'Soft Wrapper Parent', Phone = null);
    Account child = new Account(Name = 'Soft Wrapper Child', Phone = '3035550202');
    insert new List<Account>{ survivor, child };

    DuplicateMergeService.MergeProposal proposal = HeuristicDuplicateScanController.getMergeProposal(
      'Account',
      new List<String>{ String.valueOf(survivor.Id), String.valueOf(child.Id) },
      String.valueOf(survivor.Id)
    );

    List<DuplicateMergeService.FieldSelectionInput> selections = new List<DuplicateMergeService.FieldSelectionInput>();
    for (DuplicateMergeService.FieldProposal fieldProposal : proposal.fields) {
      DuplicateMergeService.FieldSelectionInput selection = new DuplicateMergeService.FieldSelectionInput();
      selection.fieldApiName = fieldProposal.fieldApiName;
      selection.sourceRecordId = fieldProposal.recommendedSourceRecordId;
      selections.add(selection);
    }

    DuplicateMergeService.MergeExecutionResult result = HeuristicDuplicateScanController.executeSoftMerge(
      'Account',
      String.valueOf(survivor.Id),
      new List<String>{ String.valueOf(child.Id) },
      selections,
      null,
      null,
      null
    );

    System.assertEquals(true, result.success, result.message);
    System.assertEquals(1, result.softMergedCount);
    System.assertEquals(1, [SELECT COUNT() FROM Duplicate_Merge_Record__c WHERE Source_Record_Id__c = :String.valueOf(child.Id)]);
  }

  @IsTest
  static void mergeRecords_forAccount_usesSoftMergeWrapper() {
    Account parent = new Account(Name = 'Wrapper Parent', Phone = null);
    Account child = new Account(Name = 'Wrapper Child', Phone = '2125550202');
    insert new List<Account>{ parent, child };

    HeuristicDuplicateScanService.ActionResult result = HeuristicDuplicateScanController.mergeRecords(
      'Account',
      parent.Id,
      new List<Id>{ child.Id }
    );

    System.assertEquals(true, result.success, result.message);
    System.assertEquals(1, result.processedCount);
    System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Id = :child.Id]);
    System.assertEquals(1, [SELECT COUNT() FROM Duplicate_Merge_Record__c WHERE Source_Record_Id__c = :String.valueOf(child.Id)]);
  }

  @IsTest
  static void softMergedRecords_areExcludedFromFutureScans() {
    Account survivor = new Account(Name = 'Blue Sky Consulting', Phone = '+1 (212) 555-0144', BillingCity = 'New York');
    Account loser = new Account(Name = 'BlueSky Consulting', Phone = '2125550144', BillingCity = 'New York');
    Account unrelated = new Account(Name = 'Red Valley Manufacturing', Phone = '4159991111', BillingCity = 'San Francisco');
    insert new List<Account>{ survivor, loser, unrelated };

    HeuristicDuplicateScanController.mergeRecords('Account', survivor.Id, new List<Id>{ loser.Id });

    Id scanId;
    Test.startTest();
    scanId = HeuristicDuplicateScanController.startScan('Account', 500, 75, true);
    Test.stopTest();

    List<HeuristicDuplicateScanService.DuplicateGroup> groups = HeuristicDuplicateScanController.getGroupsForScan(scanId, 10);
    System.assertEquals(0, groups.size());
  }

  @IsTest
  static void mergedGroupsForScan_returnsMergeHistoryForSelectedScan() {
    insert new List<Account>{
      new Account(Name = 'North Wind Traders', Phone = '2065550199', BillingCity = 'Seattle', Website = 'northwind.example'),
      new Account(Name = 'Northwind Traders', Phone = '+1 206-555-0199', BillingCity = 'Seattle', Website = 'https://northwind.example'),
      new Account(Name = 'South Harbor Logistics', Phone = '3035550101', BillingCity = 'Denver', Website = 'southharbor.example')
    };

    Id scanId;
    Test.startTest();
    scanId = HeuristicDuplicateScanController.startScan('Account', 500, 75, true);
    Test.stopTest();

    List<HeuristicDuplicateScanService.DuplicateGroup> groups = HeuristicDuplicateScanController.getGroupsForScan(scanId, 10);
    System.assertEquals(1, groups.size());

    List<String> recordIds = new List<String>();
    for (HeuristicDuplicateScanService.GroupRecord row : groups[0].records) {
      recordIds.add(row.recordId);
    }

    DuplicateMergeService.MergeProposal proposal = HeuristicDuplicateScanController.getMergeProposal(
      'Account',
      recordIds,
      recordIds[0]
    );

    DuplicateMergeService.MergeExecutionRequest request = new DuplicateMergeService.MergeExecutionRequest();
    request.objectApiName = 'Account';
    request.survivorRecordId = proposal.survivorRecordId;
    request.loserRecordIds = new List<String>();
    request.scanId = String.valueOf(scanId);
    request.groupId = String.valueOf(groups[0].groupId);
    request.groupKey = groups[0].groupKey;
    request.fieldSelections = new List<DuplicateMergeService.FieldSelectionInput>();

    for (DuplicateMergeService.RecordCandidate record : proposal.records) {
      if (record.recordId != proposal.survivorRecordId) {
        request.loserRecordIds.add(record.recordId);
      }
    }

    for (DuplicateMergeService.FieldProposal fieldProposal : proposal.fields) {
      DuplicateMergeService.FieldSelectionInput selection = new DuplicateMergeService.FieldSelectionInput();
      selection.fieldApiName = fieldProposal.fieldApiName;
      selection.sourceRecordId = fieldProposal.recommendedSourceRecordId;
      request.fieldSelections.add(selection);
    }

    DuplicateMergeService.MergeExecutionResult result = HeuristicDuplicateScanController.executeMerge(request);
    System.assertEquals(true, result.success, result.message);

    List<HeuristicDuplicateScanService.MergedGroupHistory> mergedGroups = HeuristicDuplicateScanController.getMergedGroupsForScan(
      scanId,
      10
    );
    System.assertEquals(1, mergedGroups.size());
    System.assertEquals(groups[0].groupId, mergedGroups[0].groupId);
    System.assertEquals(groups[0].groupKey, mergedGroups[0].groupKey);
    System.assertEquals('Account', mergedGroups[0].objectApiName);
    System.assertEquals(1, mergedGroups[0].mergedRecordCount);
    System.assertEquals(1, mergedGroups[0].mergedRecords.size());
    System.assertEquals(proposal.survivorRecordId, mergedGroups[0].survivorRecordId);
    System.assertEquals(request.loserRecordIds[0], mergedGroups[0].mergedRecords[0].sourceRecordId);
  }

  private static String testPairKey(Id scanId, Id leftId, Id rightId) {
    String left = String.valueOf(leftId);
    String right = String.valueOf(rightId);
    return String.valueOf(scanId) + '|' + (left < right ? left + '|' + right : right + '|' + left);
  }
}
