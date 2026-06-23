/**
 * FormSchemaValidator
 * ----------------------------------------------------------------------------
 * Validates a form JSON schema against the Step-1 contract invariants BEFORE it
 * is persisted to Form_Template__c.Schema_JSON__c.
 *
 * WHY THIS EXISTS:
 *  LLM output (Vision scan and AI prompt-edit) is non-deterministic. n8n is the
 *  first line of validation, but Salesforce must NEVER trust an external system
 *  blindly. This class is the second, authoritative gate. If n8n is bypassed,
 *  misconfigured, or compromised, this still protects the org's data integrity.
 *
 * CONTRACT INVARIANTS ENFORCED (see Step-1 design):
 *   1. type must be in the whitelist (also the primary XSS defense -- no `html`).
 *   2. Sum of colSpan within a row must be <= 12 (grid overflow guard).
 *   3. Every field.id and section.id must be present and unique within its scope
 *      (field.id is unique form-wide because Data_JSON maps fieldId -> value).
 *   4. signature fields require a signerRole of engineer|supervisor and may not
 *      appear as table columns.
 *   5. picklist fields require a non-empty options array.
 *   6. table fields require a non-empty columns array; column types restricted.
 *   7. (Edit only) field ids that already existed may not be renamed/removed in
 *      a way that breaks Data_JSON mapping -- enforced by validateEdit().
 *
 * DESIGN:
 *  - Pure, side-effect-free (no SOQL/DML/callouts) -> cheap, no governor impact,
 *    safe to call anywhere including inside a callback transaction.
 *  - `inherited sharing`: it touches no records, so it adopts the caller's
 *    sharing context rather than silently defaulting to without sharing.
 *  - Throws FormCalloutException(VALIDATION_FAILED, <reason>) on the first hard
 *    violation. Callers decide whether to retry (n8n callback) or abort (publish).
 */
public inherited sharing class FormSchemaValidator {

    // Allowed field types. Kept as a static Set for O(1) membership checks.
    // NOTE: intentionally NO 'html' or any free-markup type -> prevents injecting
    // arbitrary markup that an LWC renderer might later output unsafely.
    private static final Set<String> ALLOWED_FIELD_TYPES = new Set<String>{
        'text', 'textarea', 'number', 'date', 'time',
        'checkbox', 'picklist', 'table', 'signature'
    };

    // Allowed column types inside a table. Signatures are NOT allowed in tables
    // (invariant 4) and nested tables are disallowed to keep rendering bounded.
    private static final Set<String> ALLOWED_COLUMN_TYPES = new Set<String>{
        'text', 'number', 'date', 'time', 'checkbox', 'picklist'
    };

    private static final Set<String> ALLOWED_SIGNER_ROLES = new Set<String>{
        'engineer', 'supervisor'
    };

    private static final Integer GRID_MAX = 12;

    /**
     * Validate a freshly produced schema (Vision scan or first creation).
     * @param schemaJson raw JSON string of the form schema
     * @throws FormCalloutException if any invariant is violated
     */
    public static void validateNew(String schemaJson) {
        Map<String, Object> schema = parseOrThrow(schemaJson);
        validateStructure(schema);
    }

    /**
     * Validate an AI-edited schema against the prior version. In addition to all
     * structural rules, enforces invariant 7: existing field ids must not be
     * renamed or dropped (which would orphan Data_JSON values). Adding new fields,
     * reordering, and editing non-id properties are allowed.
     *
     * @param newSchemaJson edited schema
     * @param oldSchemaJson schema before the edit
     */
    public static void validateEdit(String newSchemaJson, String oldSchemaJson) {
        Map<String, Object> newSchema = parseOrThrow(newSchemaJson);
        validateStructure(newSchema);

        // Collect ids from both versions. Any id present before but absent now is
        // a breaking change. (We allow ADDING ids -- new fields are fine.)
        Set<String> oldIds = collectFieldIds(parseOrThrow(oldSchemaJson));
        Set<String> newIds = collectFieldIds(newSchema);

        Set<String> missing = new Set<String>(oldIds);
        missing.removeAll(newIds);
        if (!missing.isEmpty()) {
            throw new FormCalloutException(
                'VALIDATION_FAILED',
                'AI edit removed or renamed existing field id(s), which would orphan saved data: '
                    + String.join(new List<String>(missing), ', ')
            );
        }
    }

    // ---------------------------------------------------------------------
    // Internal structural validation shared by validateNew / validateEdit.
    // ---------------------------------------------------------------------
    private static void validateStructure(Map<String, Object> schema) {
        // Top-level sanity.
        Object sectionsObj = schema.get('sections');
        if (!(sectionsObj instanceof List<Object>)) {
            throw new FormCalloutException('VALIDATION_FAILED', 'Schema missing "sections" array.');
        }

        // Track uniqueness across the whole form.
        Set<String> seenSectionIds = new Set<String>();
        Set<String> seenFieldIds = new Set<String>();

        for (Object secObj : (List<Object>) sectionsObj) {
            Map<String, Object> section = asMap(secObj, 'section');
            String sectionId = asNonBlankString(section.get('id'), 'section.id');
            if (!seenSectionIds.add(sectionId)) {
                throw new FormCalloutException('VALIDATION_FAILED', 'Duplicate section id: ' + sectionId);
            }

            Object rowsObj = section.get('rows');
            if (!(rowsObj instanceof List<Object>)) {
                throw new FormCalloutException('VALIDATION_FAILED',
                    'Section "' + sectionId + '" missing "rows" array.');
            }

            for (Object rowObj : (List<Object>) rowsObj) {
                Map<String, Object> row = asMap(rowObj, 'row');
                String rowId = asNonBlankString(row.get('id'), 'row.id');

                Object fieldsObj = row.get('fields');
                if (!(fieldsObj instanceof List<Object>)) {
                    throw new FormCalloutException('VALIDATION_FAILED',
                        'Row "' + rowId + '" missing "fields" array.');
                }

                Integer colSpanSum = 0;
                for (Object fieldObj : (List<Object>) fieldsObj) {
                    Map<String, Object> field = asMap(fieldObj, 'field');
                    colSpanSum += validateField(field, seenFieldIds);
                }

                // Invariant 2: grid overflow guard.
                if (colSpanSum > GRID_MAX) {
                    throw new FormCalloutException('VALIDATION_FAILED',
                        'Row "' + rowId + '" colSpan sum is ' + colSpanSum + ', exceeds ' + GRID_MAX + '.');
                }
            }
        }

        if (seenFieldIds.isEmpty()) {
            throw new FormCalloutException('VALIDATION_FAILED', 'Schema contains no fields.');
        }
    }

    /**
     * Validate a single field map. Returns its colSpan so the row can sum.
     */
    private static Integer validateField(Map<String, Object> field, Set<String> seenFieldIds) {
        String fieldId = asNonBlankString(field.get('id'), 'field.id');

        // Invariant 3: form-wide field id uniqueness.
        if (!seenFieldIds.add(fieldId)) {
            throw new FormCalloutException('VALIDATION_FAILED', 'Duplicate field id: ' + fieldId);
        }

        String type = asNonBlankString(field.get('type'), 'field.type for ' + fieldId);
        // Invariant 1: type whitelist.
        if (!ALLOWED_FIELD_TYPES.contains(type)) {
            throw new FormCalloutException('VALIDATION_FAILED',
                'Field "' + fieldId + '" has disallowed type "' + type + '".');
        }

        // colSpan: default to full width (12) if absent; must be 1..12.
        Integer colSpan = field.containsKey('colSpan') ? asInt(field.get('colSpan'), 'colSpan of ' + fieldId) : GRID_MAX;
        if (colSpan < 1 || colSpan > GRID_MAX) {
            throw new FormCalloutException('VALIDATION_FAILED',
                'Field "' + fieldId + '" colSpan ' + colSpan + ' out of range 1..' + GRID_MAX + '.');
        }

        // Type-specific rules.
        if (type == 'picklist') {
            // Invariant 5: non-empty options.
            Object opts = field.get('options');
            if (!(opts instanceof List<Object>) || ((List<Object>) opts).isEmpty()) {
                throw new FormCalloutException('VALIDATION_FAILED',
                    'Picklist field "' + fieldId + '" requires a non-empty options array.');
            }
        } else if (type == 'signature') {
            // Invariant 4: signerRole required and valid.
            String role = asNonBlankString(field.get('signerRole'), 'signerRole of ' + fieldId);
            if (!ALLOWED_SIGNER_ROLES.contains(role)) {
                throw new FormCalloutException('VALIDATION_FAILED',
                    'Signature field "' + fieldId + '" has invalid signerRole "' + role + '".');
            }
        } else if (type == 'table') {
            validateTableColumns(field, fieldId);
        }

        return colSpan;
    }

    /**
     * Invariant 6: table requires non-empty columns; each column has a valid
     * type and id; signature columns are forbidden (handled by ALLOWED_COLUMN_TYPES).
     */
    private static void validateTableColumns(Map<String, Object> field, String fieldId) {
        Object colsObj = field.get('columns');
        if (!(colsObj instanceof List<Object>) || ((List<Object>) colsObj).isEmpty()) {
            throw new FormCalloutException('VALIDATION_FAILED',
                'Table field "' + fieldId + '" requires a non-empty columns array.');
        }
        Set<String> seenColIds = new Set<String>();
        for (Object colObj : (List<Object>) colsObj) {
            Map<String, Object> col = asMap(colObj, 'table column');
            String colId = asNonBlankString(col.get('id'), 'column id in table ' + fieldId);
            if (!seenColIds.add(colId)) {
                throw new FormCalloutException('VALIDATION_FAILED',
                    'Duplicate column id "' + colId + '" in table "' + fieldId + '".');
            }
            String colType = asNonBlankString(col.get('type'), 'type of column ' + colId);
            if (!ALLOWED_COLUMN_TYPES.contains(colType)) {
                throw new FormCalloutException('VALIDATION_FAILED',
                    'Column "' + colId + '" in table "' + fieldId + '" has disallowed type "' + colType + '".');
            }
        }
    }

    // ---------------------------------------------------------------------
    // Helpers: collect ids and safe type coercion with clear error messages.
    // ---------------------------------------------------------------------

    /** Walk the schema and return every field.id (including none from tables -- table
     *  columns are not top-level fields and are addressed by table+column id). */
    private static Set<String> collectFieldIds(Map<String, Object> schema) {
        Set<String> ids = new Set<String>();
        Object sectionsObj = schema.get('sections');
        if (!(sectionsObj instanceof List<Object>)) return ids;
        for (Object secObj : (List<Object>) sectionsObj) {
            Map<String, Object> section = asMap(secObj, 'section');
            Object rowsObj = section.get('rows');
            if (!(rowsObj instanceof List<Object>)) continue;
            for (Object rowObj : (List<Object>) rowsObj) {
                Map<String, Object> row = asMap(rowObj, 'row');
                Object fieldsObj = row.get('fields');
                if (!(fieldsObj instanceof List<Object>)) continue;
                for (Object fieldObj : (List<Object>) fieldsObj) {
                    Map<String, Object> field = asMap(fieldObj, 'field');
                    Object idVal = field.get('id');
                    if (idVal instanceof String && String.isNotBlank((String) idVal)) {
                        ids.add((String) idVal);
                    }
                }
            }
        }
        return ids;
    }

    private static Map<String, Object> parseOrThrow(String json) {
        if (String.isBlank(json)) {
            throw new FormCalloutException('VALIDATION_FAILED', 'Schema JSON is blank.');
        }
        try {
            Object parsed = System.JSON.deserializeUntyped(json);
            if (!(parsed instanceof Map<String, Object>)) {
                throw new FormCalloutException('VALIDATION_FAILED', 'Schema root must be a JSON object.');
            }
            return (Map<String, Object>) parsed;
        } catch (JSONException e) {
            // Translate low-level parse error into the contract error code.
            throw new FormCalloutException('VALIDATION_FAILED', 'Schema JSON is not parseable: ' + e.getMessage());
        }
    }

    private static Map<String, Object> asMap(Object o, String label) {
        if (!(o instanceof Map<String, Object>)) {
            throw new FormCalloutException('VALIDATION_FAILED', 'Expected object for ' + label + '.');
        }
        return (Map<String, Object>) o;
    }

    private static String asNonBlankString(Object o, String label) {
        if (!(o instanceof String) || String.isBlank((String) o)) {
            throw new FormCalloutException('VALIDATION_FAILED', 'Missing or blank ' + label + '.');
        }
        return (String) o;
    }

    private static Integer asInt(Object o, String label) {
        // JSON.deserializeUntyped yields Integer or Decimal for numbers.
        if (o instanceof Integer) return (Integer) o;
        if (o instanceof Decimal) return ((Decimal) o).intValue();
        if (o instanceof Long) return ((Long) o).intValue();
        throw new FormCalloutException('VALIDATION_FAILED', 'Expected integer for ' + label + '.');
    }
}
