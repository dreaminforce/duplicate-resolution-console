import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getObjectOptions from '@salesforce/apex/DuplicateAiController.getObjectOptions';
import analyzeObject from '@salesforce/apex/DuplicateAiController.analyzeObject';
import analyzeSingleSet from '@salesforce/apex/DuplicateAiController.analyzeSingleSet';
import getMergeProposal from '@salesforce/apex/DuplicateAiController.getMergeProposal';
import executeMerge from '@salesforce/apex/DuplicateAiController.executeMerge';
import deleteRecords from '@salesforce/apex/DuplicateAiController.deleteRecords';

export default class AiDuplicateWorkbench extends LightningElement {
  @track objectOptions = [];
  @track selectedObject;
  @track sets = [];
  @track warnings = [];
  @track summary;
  @track detailSet;
  @track modeLabel = 'View Duplicate Rule Sets';
  @track parentPickerOpen = false;
  @track parentOptions = [];
  @track selectedParentCandidate;
  @track mergeReview;

  loading = false;
  currentRunAi = false;
  selectionBySet = {};
  manualParentBySet = {};
  parentPickerSetId;
  mergeLoading = false;
  mergeExecuting = false;

  columns = [
    {
      label: 'Rank',
      fieldName: 'rank',
      type: 'number',
      fixedWidth: 74,
      cellAttributes: { alignment: 'left' }
    },
    { label: 'Record', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'displayValue' } } },
    { label: 'Survivor', fieldName: 'parentBadge', type: 'text', fixedWidth: 88 },
    { label: 'Match', fieldName: 'matchScore', type: 'number', fixedWidth: 90 },
    { label: 'Quality', fieldName: 'qualityScore', type: 'number', fixedWidth: 90 },
    { label: 'Action', fieldName: 'recommendedAction', type: 'text', fixedWidth: 98 },
    { label: 'Reason', fieldName: 'reason', type: 'text' }
  ];

  connectedCallback() {
    this.loadObjects();
  }

  async loadObjects() {
    this.loading = true;
    try {
      const options = await getObjectOptions();
      this.objectOptions = (options || []).map((opt) => ({
        label: `${opt.objectLabel} (${opt.duplicateSetCount} sets)`,
        value: opt.objectApiName,
        meta: opt
      }));

      if (!this.selectedObject && this.objectOptions.length) {
        this.selectedObject = this.objectOptions[0].value;
      }
    } catch (error) {
      this.notifyError('Failed to load matching/duplicate rule objects', error);
    } finally {
      this.loading = false;
    }
  }

  handleObjectChange(event) {
    this.selectedObject = event.detail.value;
    this.summary = null;
    this.sets = [];
    this.warnings = [];
    this.detailSet = null;
    this.mergeReview = null;
  }

  async runAnalysis(runAi) {
    if (!this.selectedObject) {
      return;
    }

    this.loading = true;
    this.currentRunAi = runAi;
    this.selectionBySet = {};
    this.manualParentBySet = {};
    this.detailSet = null;
    this.mergeReview = null;

    try {
      const result = await analyzeObject({ objectApiName: this.selectedObject, maxSets: 10, runAi });
      this.summary = {
        objectLabel: result.objectLabel,
        totalItems: result.totalItems,
        totalSets: result.totalSets,
        totalFields: result.sets && result.sets.length ? (result.sets[0].fieldNames || []).length : 0
      };
      this.modeLabel = runAi ? 'Analyze All Sets (AI)' : 'View Duplicate Rule Sets';
      this.warnings = result.warnings || [];
      this.sets = (result.sets || []).map((setItem) => this.mapSet(setItem));
    } catch (error) {
      this.notifyError(runAi ? 'Failed to run AI analysis' : 'Failed to load duplicate rule sets', error);
    } finally {
      this.loading = false;
    }
  }

  handleViewDuplicates() {
    this.runAnalysis(false);
  }

  handleAnalyzeAi() {
    this.runAnalysis(true);
  }

  async handleAnalyzeSingleSetAi(event) {
    const setId = event.target.dataset.setId;
    if (!setId || !this.selectedObject) {
      return;
    }

    this.loading = true;
    try {
      const updatedManual = { ...this.manualParentBySet };
      delete updatedManual[setId];
      this.manualParentBySet = updatedManual;
      this.clearMergeReviewForSet(setId);

      const analyzed = await analyzeSingleSet({
        objectApiName: this.selectedObject,
        duplicateRecordSetId: setId,
        runAi: true
      });
      const mapped = this.mapSet(analyzed);
      this.sets = this.sets.map((setItem) =>
        String(setItem.duplicateRecordSetId) === String(setId) ? mapped : setItem
      );
      if (this.detailSet && String(this.detailSet.duplicateRecordSetId) === String(setId)) {
        this.detailSet = mapped;
      }
      this.notify('Set analysis complete', `${mapped.duplicateRecordSetName} updated.`, 'success');
    } catch (error) {
      this.notifyError('Failed to analyze set with AI', error);
    } finally {
      this.loading = false;
    }
  }

  buildFieldRows(fieldNames, records, limit) {
    const rows = [];

    fieldNames.forEach((fieldName) => {
      const values = records.map((record) => ({
        recordId: record.recordId,
        isParent: record.isEffectiveParent,
        cellClass: record.isEffectiveParent ? 'is-parent' : '',
        value: (record.fields && record.fields[fieldName]) || ''
      }));

      rows.push({
        name: fieldName,
        values
      });
    });

    return limit ? rows.slice(0, limit) : rows;
  }

  handleRowSelection(event) {
    const setId = event.target.dataset.setId;
    const selectedIds = (event.detail.selectedRows || []).map((row) => row.recordId);
    this.selectionBySet = {
      ...this.selectionBySet,
      [setId]: selectedIds
    };
    this.clearMergeReviewForSet(setId);
  }

  handleOpenDetail(event) {
    const setId = event.target.dataset.setId;
    const targetSet = this.sets.find((setItem) => String(setItem.duplicateRecordSetId) === String(setId));
    if (!targetSet) {
      return;
    }
    this.detailSet = targetSet;
    if (this.mergeReview && this.mergeReview.setId !== String(setId)) {
      this.mergeReview = null;
    }
  }

  handleSelectParentClick(event) {
    const setId = event.target.dataset.setId;
    const targetSet = this.sets.find((setItem) => String(setItem.duplicateRecordSetId) === String(setId));
    if (!targetSet || !targetSet.records || !targetSet.records.length) {
      this.notify('No records', 'No records available in this set to select as survivor.', 'info');
      return;
    }

    this.parentPickerSetId = String(setId);
    this.parentOptions = targetSet.records.map((row) => ({
      label: `${row.displayValue} (${row.recordId})`,
      value: row.recordId
    }));
    this.selectedParentCandidate = this.getEffectiveParentId(targetSet) || targetSet.records[0].recordId;
    this.parentPickerOpen = true;
  }

  handleParentCandidateChange(event) {
    this.selectedParentCandidate = event.detail.value;
  }

  handleParentPickerCancel() {
    this.parentPickerOpen = false;
    this.parentOptions = [];
    this.selectedParentCandidate = null;
    this.parentPickerSetId = null;
  }

  handleParentPickerConfirm() {
    if (!this.parentPickerSetId || !this.selectedParentCandidate) {
      return;
    }

    this.manualParentBySet = {
      ...this.manualParentBySet,
      [this.parentPickerSetId]: this.selectedParentCandidate
    };

    this.sets = this.sets.map((setItem) =>
      String(setItem.duplicateRecordSetId) === this.parentPickerSetId ? this.mapSet(setItem) : setItem
    );

    if (this.detailSet && String(this.detailSet.duplicateRecordSetId) === this.parentPickerSetId) {
      this.detailSet = this.sets.find(
        (setItem) => String(setItem.duplicateRecordSetId) === this.parentPickerSetId
      );
    }

    this.clearMergeReviewForSet(this.parentPickerSetId);
    this.notify('Survivor selected', 'Survivor record selected for this set.', 'success');
    this.handleParentPickerCancel();
  }

  handleBackToSummary() {
    this.detailSet = null;
    this.mergeReview = null;
  }

  handleSelectSurvivorFromReview() {
    if (!this.detailSet) {
      return;
    }

    this.handleSelectParentClick({
      target: {
        dataset: {
          setId: this.detailSet.duplicateRecordSetId
        }
      }
    });
  }

  async handleReviewMerge(event) {
    const setId = event.target.dataset.setId;
    const targetSet = this.sets.find((setItem) => String(setItem.duplicateRecordSetId) === String(setId));
    if (!targetSet) {
      return;
    }

    this.detailSet = targetSet;
    await this.loadMergeReview(targetSet);
  }

  async loadMergeReview(targetSet) {
    const recordIds = this.getMergeCandidateIds(targetSet);
    if (recordIds.length < 2) {
      this.notify('Select records', 'Choose at least two records before starting the merge review.', 'warning');
      return;
    }

    this.mergeLoading = true;
    try {
      const proposal = await getMergeProposal({
        objectApiName: this.selectedObject,
        recordIds,
        preferredSurvivorId: this.getEffectiveParentId(targetSet)
      });

      const setId = String(targetSet.duplicateRecordSetId);
      this.manualParentBySet = {
        ...this.manualParentBySet,
        [setId]: proposal.survivorRecordId
      };

      this.sets = this.sets.map((setItem) =>
        String(setItem.duplicateRecordSetId) === setId ? this.mapSet(setItem) : setItem
      );
      this.detailSet = this.sets.find((setItem) => String(setItem.duplicateRecordSetId) === setId);
      this.mergeReview = this.mapMergeReview(proposal, setId, targetSet.duplicateRecordSetName);
    } catch (error) {
      this.notifyError('Failed to build merge review', error);
    } finally {
      this.mergeLoading = false;
    }
  }

  handleMergeSelectionChange(event) {
    if (!this.mergeReview) {
      return;
    }

    const { fieldApiName, sourceRecordId } = event.detail;
    const updateRows = (rows) =>
      rows.map((row) => {
        if (row.fieldApiName !== fieldApiName) {
          return row;
        }
        const selectedCandidate = row.values.find((value) => value.recordId === sourceRecordId);
        return {
          ...row,
          selectedSourceRecordId: sourceRecordId,
          selectedValue: selectedCandidate ? selectedCandidate.value : ''
        };
      });

    const highRiskFields = updateRows(this.mergeReview.highRiskFields);
    const lowRiskFields = updateRows(this.mergeReview.lowRiskFields);

    this.mergeReview = {
      ...this.mergeReview,
      highRiskFields,
      lowRiskFields,
      previewFields: this.buildPreviewFields(highRiskFields, lowRiskFields)
    };
  }

  handleMergeReviewClose() {
    this.mergeReview = null;
  }

  async handleExecuteMerge() {
    if (!this.mergeReview) {
      return;
    }

    this.mergeExecuting = true;
    try {
      const fieldSelections = [...this.mergeReview.highRiskFields, ...this.mergeReview.lowRiskFields].map((row) => ({
        fieldApiName: row.fieldApiName,
        sourceRecordId: row.selectedSourceRecordId
      }));

      const result = await executeMerge({
        request: {
          objectApiName: this.selectedObject,
          survivorRecordId: this.mergeReview.survivorRecordId,
          loserRecordIds: this.mergeReview.recordIds.filter((recordId) => recordId !== this.mergeReview.survivorRecordId),
          fieldSelections
        }
      });

      this.notify(
        result.success ? 'Soft merge completed' : 'Soft merge completed with errors',
        result.message,
        result.success ? 'success' : 'warning'
      );

      this.mergeReview = null;
      this.detailSet = null;
      await this.runAnalysis(this.currentRunAi);
    } catch (error) {
      this.notifyError('Soft merge failed', error);
    } finally {
      this.mergeExecuting = false;
    }
  }

  async handleDeleteClick(event) {
    const setId = event.target.dataset.setId;
    const selected = this.selectionBySet[setId] || [];

    if (!selected.length) {
      this.notify('No records selected', 'Select one or more records to delete.', 'info');
      return;
    }

    this.loading = true;
    try {
      const result = await deleteRecords({ recordIds: selected });
      this.notify(
        result.success ? 'Delete completed' : 'Delete completed with errors',
        result.message,
        result.success ? 'success' : 'warning'
      );
      await this.runAnalysis(this.currentRunAi);
    } catch (error) {
      this.notifyError('Delete failed', error);
    } finally {
      this.loading = false;
    }
  }

  notify(title, message, variant) {
    this.dispatchEvent(
      new ShowToastEvent({
        title,
        message,
        variant
      })
    );
  }

  notifyError(title, error) {
    const message = (error && error.body && error.body.message) || (error && error.message) || 'Unknown error';
    this.notify(title, message, 'error');
  }

  truncate(value, maxLen) {
    if (!value || value.length <= maxLen) {
      return value;
    }
    return `${value.substring(0, maxLen).trim()}...`;
  }

  mapSet(setItem) {
    const effectiveParentId = this.getEffectiveParentId(setItem);
    const records = (setItem.records || []).map((row) => ({
      ...row,
      recordUrl: `/${row.recordId}`,
      isEffectiveParent: effectiveParentId ? row.recordId === effectiveParentId : false,
      parentBadge: effectiveParentId && row.recordId === effectiveParentId ? 'Yes' : ''
    }));

    const effectiveParentDisplay = effectiveParentId
      ? (records.find((row) => row.recordId === effectiveParentId) || {}).displayValue || ''
      : '';

    return {
      ...setItem,
      records,
      canMergeUi: records.length > 1,
      effectiveParentId,
      effectiveParentDisplay,
      mergeDisabled: !effectiveParentId || records.length < 2,
      summaryShort: this.truncate(setItem.summary, 150),
      sectionLabel: `${setItem.duplicateRecordSetName} | ${records.length} records`,
      selectedRows: [],
      detailFieldRows: this.buildFieldRows(setItem.fieldNames || [], records)
    };
  }

  mapMergeReview(proposal, setId, title) {
    const records = (proposal.records || []).map((record) => ({
      ...record,
      scoreSummary: `S:${record.survivorScore} | C:${record.completenessScore} | R:${record.relatedRecordCount}`
    }));

    const highRiskFields = [];
    const lowRiskFields = [];

    (proposal.fields || []).forEach((field) => {
      const row = this.mapMergeFieldRow(field, records, proposal.survivorRecordId);
      if (field.requiresReview) {
        highRiskFields.push(row);
      } else {
        lowRiskFields.push(row);
      }
    });

    return {
      setId,
      title: `${title} Resolution Review`,
      objectLabel: proposal.objectLabel,
      summary: proposal.summary,
      survivorRecordId: proposal.survivorRecordId,
      survivorDisplayValue: proposal.survivorDisplayValue,
      reviewRequiredCount: proposal.reviewRequiredCount,
      lowRiskFieldCount: proposal.lowRiskFieldCount,
      relatedRecordCount: proposal.relatedRecordCount,
      warnings: proposal.warnings || [],
      records,
      highRiskFields,
      lowRiskFields,
      previewFields: this.buildPreviewFields(highRiskFields, lowRiskFields),
      relatedSummaries: (proposal.relatedSummaries || []).map((item) => ({
        ...item,
        key: `${item.childObjectApiName}-${item.fieldApiName}`
      })),
      recordIds: records.map((record) => record.recordId)
    };
  }

  mapMergeFieldRow(field, records, survivorRecordId) {
    const recommendedRecord = records.find((record) => record.recordId === field.recommendedSourceRecordId);
    const selectorOptions = records.map((record) => ({
      label: `${record.displayValue}${record.recordId === survivorRecordId ? ' (Survivor)' : ''}${
        record.recordId === field.recommendedSourceRecordId ? ' (Recommended)' : ''
      }`,
      value: record.recordId
    }));

    const values = records.map((record) => {
      const matchingCandidate = (field.candidates || []).find((candidate) => candidate.recordId === record.recordId);
      const value = matchingCandidate ? matchingCandidate.value : '';
      let cellClass = '';
      const meta = [];
      if (record.recordId === survivorRecordId) {
        cellClass = 'cell-survivor';
        meta.push('Survivor');
      }
      if (record.recordId === field.recommendedSourceRecordId) {
        cellClass = record.recordId === survivorRecordId ? 'cell-survivor cell-recommended' : 'cell-recommended';
        meta.push('Recommended');
      }
      return {
        recordId: record.recordId,
        value,
        cellClass,
        metaLabel: meta.join(' | ')
      };
    });

    const selectedCandidate = values.find((value) => value.recordId === field.selectedSourceRecordId);
    const selectedValue = selectedCandidate ? selectedCandidate.value : '';
    return {
      fieldApiName: field.fieldApiName,
      fieldLabel: field.fieldLabel,
      recommendationReason: field.recommendationReason,
      recommendedSourceRecordId: field.recommendedSourceRecordId,
      recommendedSourceLabel: recommendedRecord ? recommendedRecord.displayValue : field.recommendedSourceRecordId,
      selectedSourceRecordId: field.selectedSourceRecordId,
      selectedValue,
      selectorOptions,
      values
    };
  }

  buildPreviewFields(highRiskFields, lowRiskFields) {
    return [...highRiskFields, ...lowRiskFields]
      .map((field) => ({
        fieldApiName: field.fieldApiName,
        fieldLabel: field.fieldLabel,
        selectedValue: field.selectedValue || '(blank)'
      }))
      .sort((left, right) => left.fieldLabel.localeCompare(right.fieldLabel));
  }

  getEffectiveParentId(setItem) {
    if (!setItem) {
      return null;
    }
    const setId = String(setItem.duplicateRecordSetId);
    const firstRecordId = setItem.records && setItem.records.length ? setItem.records[0].recordId : null;
    return this.manualParentBySet[setId] || setItem.parentRecordId || firstRecordId || null;
  }

  getMergeCandidateIds(setItem) {
    const setId = String(setItem.duplicateRecordSetId);
    const selected = this.selectionBySet[setId] || [];
    const survivorId = this.getEffectiveParentId(setItem);
    const allRecordIds = (setItem.records || []).map((record) => record.recordId);
    const candidateIds = selected.length ? Array.from(new Set([survivorId, ...selected].filter(Boolean))) : allRecordIds;
    return candidateIds.length >= 2 ? candidateIds : allRecordIds;
  }

  clearMergeReviewForSet(setId) {
    if (this.mergeReview && this.mergeReview.setId === String(setId)) {
      this.mergeReview = null;
    }
  }

  get hasData() {
    return this.sets.length > 0;
  }

  get showSummaryView() {
    return !this.detailSet;
  }

  get showDetailView() {
    return !!this.detailSet;
  }
}
