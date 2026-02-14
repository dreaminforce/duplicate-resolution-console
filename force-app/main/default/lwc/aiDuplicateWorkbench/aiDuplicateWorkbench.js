import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getObjectOptions from '@salesforce/apex/DuplicateAiController.getObjectOptions';
import analyzeObject from '@salesforce/apex/DuplicateAiController.analyzeObject';
import analyzeSingleSet from '@salesforce/apex/DuplicateAiController.analyzeSingleSet';
import mergeRecords from '@salesforce/apex/DuplicateAiController.mergeRecords';
import deleteRecords from '@salesforce/apex/DuplicateAiController.deleteRecords';

export default class AiDuplicateWorkbench extends LightningElement {
  static MERGEABLE_OBJECTS = ['Account', 'Contact', 'Lead', 'Case'];

  @track objectOptions = [];
  @track selectedObject;
  @track sets = [];
  @track warnings = [];
  @track summary;
  @track detailSet;
  @track modeLabel = 'View Duplicates';
  @track parentPickerOpen = false;
  @track parentOptions = [];
  @track selectedParentCandidate;

  loading = false;
  currentRunAi = false;
  selectionBySet = {};
  manualParentBySet = {};
  parentPickerSetId;

  columns = [
    {
      label: 'Rank',
      fieldName: 'rank',
      type: 'number',
      fixedWidth: 74,
      cellAttributes: { alignment: 'left' }
    },
    { label: 'Record', fieldName: 'recordUrl', type: 'url', typeAttributes: { label: { fieldName: 'displayValue' } } },
    { label: 'Parent', fieldName: 'parentBadge', type: 'text', fixedWidth: 88 },
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
      this.notifyError('Failed to load duplicate objects', error);
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

    try {
      const result = await analyzeObject({ objectApiName: this.selectedObject, maxSets: 10, runAi });
      this.summary = {
        objectLabel: result.objectLabel,
        totalItems: result.totalItems,
        totalSets: result.totalSets,
        totalFields: result.sets && result.sets.length ? (result.sets[0].fieldNames || []).length : 0
      };
      this.modeLabel = runAi ? 'AI Analyze All Sets' : 'View Duplicates';
      this.warnings = result.warnings || [];

      this.sets = (result.sets || []).map((setItem) => this.mapSet(setItem));
    } catch (error) {
      this.notifyError(runAi ? 'Failed to run AI analysis' : 'Failed to load duplicate sets', error);
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
      this.notify('AI set analysis complete', `${mapped.duplicateRecordSetName} updated.`, 'success');
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
        value: record.fields?.[fieldName] || ''
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
  }

  handleOpenDetail(event) {
    const setId = event.target.dataset.setId;
    const targetSet = this.sets.find((s) => String(s.duplicateRecordSetId) === String(setId));
    if (!targetSet) {
      return;
    }
    this.detailSet = targetSet;
  }

  handleSelectParentClick(event) {
    const setId = event.target.dataset.setId;
    const targetSet = this.sets.find((s) => String(s.duplicateRecordSetId) === String(setId));
    if (!targetSet || !targetSet.records || !targetSet.records.length) {
      this.notify('No records', 'No records available in this set to select as parent.', 'info');
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
      const refreshed = this.sets.find(
        (setItem) => String(setItem.duplicateRecordSetId) === this.parentPickerSetId
      );
      this.detailSet = refreshed;
    }

    this.notify('Parent selected', 'Parent record selected for this set.', 'success');
    this.handleParentPickerCancel();
  }

  handleBackToSummary() {
    this.detailSet = null;
  }

  async handleMergeClick(event) {
    const setId = event.target.dataset.setId;
    const targetSet = this.sets.find((s) => String(s.duplicateRecordSetId) === String(setId));
    if (!targetSet) {
      return;
    }

    const selected = this.selectionBySet[setId] || [];
    const parentId = this.getEffectiveParentId(targetSet);
    if (!parentId) {
      this.notify('Select parent', 'Select a parent record before merge.', 'warning');
      return;
    }
    const children = selected.length
      ? selected.filter((id) => id !== parentId)
      : targetSet.records.filter((record) => !record.isEffectiveParent).map((record) => record.recordId);

    if (!children.length) {
      this.notify('Nothing to merge', 'Select at least one child record.', 'info');
      return;
    }

    this.loading = true;
    try {
      const result = await mergeRecords({
        objectApiName: this.selectedObject,
        parentRecordId: parentId,
        childRecordIds: children
      });
      this.notify(result.success ? 'Merge completed' : 'Merge completed with errors', result.message, result.success ? 'success' : 'warning');
      await this.runAnalysis(this.currentRunAi);
    } catch (error) {
      this.notifyError('Merge failed', error);
    } finally {
      this.loading = false;
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
      this.notify(result.success ? 'Delete completed' : 'Delete completed with errors', result.message, result.success ? 'success' : 'warning');
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
    const message = error?.body?.message || error?.message || 'Unknown error';
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
      canMergeUi: AiDuplicateWorkbench.MERGEABLE_OBJECTS.includes(this.selectedObject),
      effectiveParentId,
      effectiveParentDisplay,
      mergeDisabled: !effectiveParentId,
      summaryShort: this.truncate(setItem.summary, 150),
      sectionLabel: `${setItem.duplicateRecordSetName} | ${records.length} records`,
      selectedRows: [],
      detailFieldRows: this.buildFieldRows(setItem.fieldNames || [], records)
    };
  }

  getEffectiveParentId(setItem) {
    if (!setItem) {
      return null;
    }
    const setId = String(setItem.duplicateRecordSetId);
    return this.manualParentBySet[setId] || setItem.parentRecordId || null;
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
