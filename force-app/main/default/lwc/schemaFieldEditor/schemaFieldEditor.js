import { LightningElement, api } from 'lwc';

/**
 * schemaFieldEditor
 * ----------------------------------------------------------------------------
 * Edits the PROPERTIES of a single schema field in the manual editor (label,
 * type, required, colSpan, picklist options). It does NOT render the field as it
 * will appear on the form -- that is the preview's job. This is a metadata editor.
 *
 * Controlled component: the parent owns the schema. On any change we emit
 * `fieldchange` with the full updated field object; the parent splices it back
 * into the schema. We also emit `moveup`/`movedown`/`remove` for ordering.
 *
 * NOTE: `id` is intentionally NOT editable. Field ids are immutable by contract
 * (Data_JSON maps fieldId -> value). The input is shown read-only so the user
 * understands the id exists but cannot break data mapping by changing it.
 */
const FIELD_TYPES = [
    { label: 'Text', value: 'text' },
    { label: 'Text Area', value: 'textarea' },
    { label: 'Number', value: 'number' },
    { label: 'Date', value: 'date' },
    { label: 'Time', value: 'time' },
    { label: 'Checkbox', value: 'checkbox' },
    { label: 'Picklist', value: 'picklist' },
    { label: 'Table', value: 'table' },
    { label: 'Signature', value: 'signature' }
];

const SIGNER_ROLES = [
    { label: 'Engineer', value: 'engineer' },
    { label: 'Supervisor', value: 'supervisor' }
];

const COLSPANS = Array.from({ length: 12 }, (_, i) => ({
    label: String(i + 1),
    value: String(i + 1)
}));

export default class SchemaFieldEditor extends LightningElement {
    @api field;
    @api isFirst = false;
    @api isLast = false;

    get typeOptions() { return FIELD_TYPES; }
    get signerRoleOptions() { return SIGNER_ROLES; }
    get colSpanOptions() { return COLSPANS; }

    get isPicklist() { return this.field.type === 'picklist'; }
    get isSignature() { return this.field.type === 'signature'; }
    get isTable() { return this.field.type === 'table'; }

    // Picklist options stored as array; edited as newline-delimited text.
    get optionsText() {
        return (this.field.options || []).join('\n');
    }

    get colSpanValue() {
        return String(this.field.colSpan || 12);
    }

    // ---- change handlers: clone field, mutate, emit ----------------------
    handleLabelChange(e) { this.emitChange({ label: e.target.value }); }
    handleRequiredChange(e) { this.emitChange({ required: e.target.checked }); }
    handleColSpanChange(e) { this.emitChange({ colSpan: parseInt(e.target.value, 10) }); }
    handleSignerRoleChange(e) { this.emitChange({ signerRole: e.target.value }); }

    handleTypeChange(e) {
        const newType = e.target.value;
        const patch = { type: newType };
        // Keep the schema valid as type changes: ensure type-specific props exist.
        if (newType === 'picklist' && !this.field.options) {
            patch.options = ['Option 1'];
        }
        if (newType === 'signature' && !this.field.signerRole) {
            patch.signerRole = 'engineer';
        }
        if (newType === 'table' && !this.field.columns) {
            patch.columns = [{ id: 'c_1', label: 'Column 1', type: 'text', width: 12 }];
        }
        this.emitChange(patch);
    }

    handleOptionsChange(e) {
        const opts = e.target.value
            .split('\n')
            .map((s) => s.trim())
            .filter((s) => s.length > 0);
        this.emitChange({ options: opts });
    }

    emitChange(patch) {
        const updated = { ...this.field, ...patch };
        this.dispatchEvent(new CustomEvent('fieldchange', { detail: updated }));
    }

    handleMoveUp() { this.dispatchEvent(new CustomEvent('moveup', { detail: this.field.id })); }
    handleMoveDown() { this.dispatchEvent(new CustomEvent('movedown', { detail: this.field.id })); }
    handleRemove() { this.dispatchEvent(new CustomEvent('remove', { detail: this.field.id })); }
}