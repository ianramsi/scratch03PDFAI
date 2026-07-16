/**
 * errorUtils
 * ----------------------------------------------------------------------------
 * Shared helper to normalize the many shapes a Salesforce/Apex error can take
 * (AuraHandledException, DML page/field errors, plain JS errors) into a flat
 * list of human-readable strings. Import this everywhere instead of duplicating
 * the reducer in each component.
 */
export function reduceErrors(errors) {
    if (!Array.isArray(errors)) {
        errors = [errors];
    }
    return errors
        .filter((e) => !!e)
        .map((e) => {
            // DML/page-level error arrays.
            if (Array.isArray(e.body)) {
                return e.body.map((b) => b.message);
            }
            // AuraHandledException / Apex exception.
            if (e.body && typeof e.body.message === 'string') {
                return e.body.message;
            }
            // Plain JS Error.
            if (typeof e.message === 'string') {
                return e.message;
            }
            // Fallback.
            return JSON.stringify(e);
        })
        .flat()
        .filter((m) => !!m);
}