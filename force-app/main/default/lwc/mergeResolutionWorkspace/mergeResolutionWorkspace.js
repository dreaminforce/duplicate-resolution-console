import { LightningElement, api } from 'lwc';

export default class MergeResolutionWorkspace extends LightningElement {
  @api proposal;
  @api loading = false;
  @api executing = false;

  get hasProposal() {
    return !!this.proposal;
  }

  get showWorkspace() {
    return this.loading || this.hasProposal;
  }

  get hasWarnings() {
    return !!(this.proposal && this.proposal.warnings && this.proposal.warnings.length);
  }

  get hasHighRiskFields() {
    return !!(this.proposal && this.proposal.highRiskFields && this.proposal.highRiskFields.length);
  }

  get hasLowRiskFields() {
    return !!(this.proposal && this.proposal.lowRiskFields && this.proposal.lowRiskFields.length);
  }

  get hasRelatedSummaries() {
    return !!(this.proposal && this.proposal.relatedSummaries && this.proposal.relatedSummaries.length);
  }

  get executeDisabled() {
    return this.loading || this.executing || !this.hasProposal;
  }

  handleSelectionChange(event) {
    this.dispatchEvent(
      new CustomEvent('selectionchange', {
        detail: {
          fieldApiName: event.target.dataset.fieldApiName,
          sourceRecordId: event.detail.value
        }
      })
    );
  }

  handleExecute() {
    this.dispatchEvent(new CustomEvent('execute'));
  }

  handleClose() {
    this.dispatchEvent(new CustomEvent('close'));
  }

  handleSelectSurvivor() {
    this.dispatchEvent(new CustomEvent('selectsurvivor'));
  }
}
