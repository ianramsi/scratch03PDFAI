import { LightningElement, api } from 'lwc';

/**
 * formField
 * ----------------------------------------------------------------------------
 * Renders ONE schema field according to its `type` and emits a `valuechange`
 * event whenever the user edits it. This is a controlled component: it never
 * owns the data -- the parent (formRenderer) holds all values and passes the
 * current value in via @api.
 *
 * SUPPORTED TYPES (whitelist mirrors the Apex validator):
 *   text, textarea, number, date, time, checkbox, picklist, table, signature
 *
 * The `signature` type renders nothing here -- signatures are handled by the
 * dedicated signaturePad component in the parent, because they need canvas +
 * upload behavior that doesn't fit a generic field. formField for a signature
 * just exposes its presence so the parent can place a pad.
 */
export default class FormField extends LightningElement {
    @api field;       // the schema field object
    @api value;       // current value (string | number | boolean | array for table)
    @api disabled = false;

    // ---- type predicates for the template (computed once per render) ----
    get isText() { return this.field.type === 'text'; }
    get isTextarea() { return this.field.type === 'textarea'; }
    get isNumber() { return this.field.type === 'number'; }
    get isDate() { return this.field.type === 'date'; }
    get isTime() { return this.field.type === 'time'; }
    get isCheckbox() { return this.field.type === 'checkbox'; }
    get isPicklist() { return this.field.type === 'picklist'; }
    get isTable() { return this.field.type === 'table'; }
    get isSignature() { return this.field.type === 'signature'; }

    get required() {
        return this.field.required === true;
    }

    // Picklist options -> combobox shape.
    get picklistOptions() {
        return (this.field.options || []).map((o) => ({ label: o, value: o }));
    }

    // ---- table support -----------------------------------------------------
    // Table value is an array of row objects keyed by column id.
    get tableRows() {
        const rows = Array.isArray(this.value) ? this.value : [];
        // Provide a stable key + the column cells for each row.
        return rows.map((row, idx) => ({
            key: `row_${idx}`,
            index: idx,
            cells: (this.field.columns || []).map((col) => ({
                key: `${idx}_${col.id}`,
                colId: col.id,
                label: col.label,
                type: col.type,
                value: row[col.id],
                isText: col.type === 'text',
                isNumber: col.type === 'number',
                isDate: col.type === 'date',
                isTime: col.type === 'time',
                isCheckbox: col.type === 'checkbox',
                isPicklist: col.type === 'picklist',
                options: (col.options || []).map((o) => ({ label: o, value: o }))
            }))
        }));
    }

    get canAddRow() {
        if (this.disabled) return false;
        const max = this.field.maxRows || 9999;
        return (Array.isArray(this.value) ? this.value.length : 0) < max;
    }

    // ---- change emitters ---------------------------------------------------

    handleScalarChange(evt) {
        // checkbox uses .checked, everything else uses .value
        const newVal = this.isCheckbox ? evt.target.checked : evt.target.value;
        this.emit(newVal);
    }

    handleTableCellChange(evt) {
        const rowIndex = parseInt(evt.target.dataset.row, 10);
        const colId = evt.target.dataset.col;
        const colType = evt.target.dataset.type;
        const cellVal = colType === 'checkbox' ? evt.target.checked : evt.target.value;

        const rows = Array.isArray(this.value) ? JSON.parse(JSON.stringify(this.value)) : [];
        if (!rows[rowIndex]) rows[rowIndex] = {};
        rows[rowIndex][colId] = cellVal;
        this.emit(rows);
    }

    handleAddRow() {
        const rows = Array.isArray(this.value) ? JSON.parse(JSON.stringify(this.value)) : [];
        const blank = {};
        (this.field.columns || []).forEach((c) => {
            blank[c.id] = c.type === 'checkbox' ? false : '';
        });
        rows.push(blank);
        this.emit(rows);
    }

    handleRemoveRow(evt) {
        const idx = parseInt(evt.target.dataset.row, 10);
        const rows = Array.isArray(this.value) ? JSON.parse(JSON.stringify(this.value)) : [];
        rows.splice(idx, 1);
        this.emit(rows);
    }

    emit(newValue) {
        this.dispatchEvent(
            new CustomEvent('valuechange', {
                detail: { fieldId: this.field.id, value: newValue }
            })
        );
    }
}
